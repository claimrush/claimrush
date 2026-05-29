// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Constants} from "../lib/Constants.sol";
import {Errors} from "../lib/Errors.sol";
import {SafeApprove} from "../lib/SafeApprove.sol";
import {SafeERC20View} from "../lib/SafeERC20View.sol";
import {Events} from "../lib/Events.sol";
import {IAerodromePool} from "../interfaces/IAerodromePool.sol";
import {IAerodromeRouter} from "../interfaces/IAerodromeRouter.sol";
import {IFurnace} from "../interfaces/IFurnace.sol";
import {IFurnaceQuoter} from "../interfaces/IFurnaceQuoter.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IVeClaimNFT} from "../interfaces/IVeClaimNFT.sol";
import {IDelegationHub} from "../interfaces/IDelegationHub.sol";
import {DelegationPermissions} from "../lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "../lib/DelegationActionTypes.sol";
import {ILpStakingVault7D} from "../interfaces/ILpStakingVault7D.sol";

/// @notice LpStakingVault7D (LP staking vault).
/// @dev Spec: docs/spec/lp-staking-vault-spec.md
/// @dev NOTE: v1.0.0 sets Constants.UNBONDING_PERIOD = 7 days.
///
/// v1.0.0 implements:
/// - reward-per-token accounting + queued rewards
/// - unbonding with bounded withdrawals
/// - owner-or-keeper-allowlisted fee harvest (Aerodrome claimFees + swap WETH->CLAIM)
/// - optional auto-compound into Furnace (off by default)
contract LpStakingVault7D is ReentrancyGuard, Ownable2Step, ILpStakingVault7D {
    using SafeERC20 for IERC20;

    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));

    // Errors (local)

    error NoFeesToHarvest();
    error DeadlineTooFar();
    error MinClaimOutRequired();
    error MinClaimFloorNotMet();
    error HarvestQuoteFailed();
    error CallerQuoteDivergence();
    error LockCooldown();

    // Fee harvest constants (v1.0.0 policy)

    uint256 public constant BPS_DENOM = Constants.BPS_DENOM;
    uint256 public constant MIN_COMPOUND_INTERVAL = 1 days;
    uint256 public constant MAX_HARVEST_DEADLINE = 10 minutes;

    // Immutable config
    IERC20 public immutable lpToken;
    IERC20 public immutable weth;
    IERC20 public immutable claim;

    IVeClaimNFT public immutable ve;

    address public immutable aerodromeRouter;
    address public immutable aerodromeFactory;
    bool public immutable wethClaimStable;

    /// @notice Furnace address used for claimRewardsAndLock.
    address public immutable furnace;

    // Staking state
    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;

    // Rewards (rewardPerToken accounting)
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /// @dev Tracks the CLAIM balance already accounted for as rewards (including queued rewards).
    uint256 public accountedRewardBalance;

    /// @dev Rewards received while totalStaked == 0. Flushed to the index on the next `stake()`.
    ///      MEV NOTE: The first staker after a zero-TVL period captures all queued rewards.
    ///      Off-chain monitoring should alert when queuedRewards is large relative to typical stakes.
    uint256 public queuedRewards;

    /// @dev Debt-accounting accumulators that maintain the disjoint-debt invariant.
    ///      `indexedClaimOwed` tracks CLAIM that has been moved into the
    ///      `rewardPerTokenStored` index (credited in `_indexRewardsWithCarry` by
    ///      `indexedAmount`, debited at user claim/lock/auto-compound disbursement).
    ///      `totalRewardsCredited` tracks `Σ rewards[user]` (credited by the per-user
    ///      delta in `_updateReward` after the per-user clamp, debited when
    ///      `rewards[user]` decreases). Disjoint-debt invariant:
    ///      `totalRewardsCredited <= indexedClaimOwed` AND
    ///      `indexedClaimOwed - totalRewardsCredited == Σ_unallocated_indexed`.
    ///      Without the per-user clamp, the combined-floor over N notify cycles
    ///      can exceed the index pool by up to (N - 1) wei (M-AccountingFloorDrift
    ///      class).
    uint256 public indexedClaimOwed;
    uint256 public totalRewardsCredited;

    // Headline counters (required for dashboards)

    uint256 public totalClaimRewardsFundedFromFurnace;
    uint256 public totalClaimRewardsFundedFromVaultFees;
    uint256 public totalClaimRewardsClaimed;
    uint256 public totalClaimRewardsLockedViaFurnace;

    // Fee harvest state

    /// @notice Timestamp of the last successful `harvestFeesToRewards` call.
    /// @dev Exposed for off-chain keeper status / monitoring (cadence checks).
    uint256 public lastFeeHarvestTs;

    /// @notice Owner-settable absolute minimum CLAIM out for harvest swaps (circuit-breaker).
    uint256 public minHarvestClaimFloor;

    // Auto-compound (LP rewards -> Furnace)
    struct AutoCompoundConfig {
        bool enabled;
        bool paused;
        uint256 tokenId;
        uint256 durationSeconds;
        uint32 maxSlippageBps; // 0 = use DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS
        uint256 minRewardToCompound;
    }

    mapping(address => AutoCompoundConfig) internal _autoCompound;

    /// @notice Owner-settable global floor for auto-compound reward minimum (dust guard).
    uint256 public minCompoundReward;

    // Harvest keeper allowlist
    mapping(address => bool) public isHarvestKeeper;

    // Unbonding
    struct Unbond {
        uint256 id;
        uint256 amount;
        uint256 unlockTime;
    }

    mapping(address => Unbond[]) internal _unbonds;
    mapping(address => uint256) public nextUnbondId;
    mapping(address => uint256) public lastCompoundTs;
    mapping(address => uint256) public lastUserLockTs;

    modifier onlyRewardNotifier() {
        // Notify is allowed from:
        // - Furnace (LP reward split)
        // - this contract (harvestFeesToRewards self-notify)
        if (msg.sender != furnace && msg.sender != address(this)) {
            revert Errors.NotRewardNotifier();
        }
        _;
    }

    modifier onlyHarvestKeeper() {
        if (msg.sender != owner() && !isHarvestKeeper[msg.sender]) revert Errors.NotAuthorized();
        // Runtime 7702 reject on the caller seat. A clean owner or keeper EOA at
        // seating time can install the `0xEF0100` designator afterward and expose
        // the MEV-sensitive harvest path (caller-supplied `minClaimOut`) as a
        // public-executor surface until the seat is rotated. Apply the guard on
        // the owner branch too, not only the keeper branch. Bare EOAs and ordinary
        // contracts are unaffected.
        _rejectDelegatedEOA(msg.sender);
        _;
    }

    /// @dev Reject EIP-7702 delegation designators on immutable roots. The 7702
    ///      designator is exactly 23 bytes and starts with `0xEF0100`; bare EOAs
    ///      (`code.length == 0`) and normal contracts are unaffected.
    function _rejectDelegatedEOA(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    constructor(
        address _lpToken,
        address _weth,
        address _claim,
        address _ve,
        address _furnace,
        address _aerodromeRouter,
        address _aerodromeFactory,
        bool _wethClaimStable,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            _lpToken == address(0) || _weth == address(0) || _claim == address(0) || _ve == address(0)
                || _furnace == address(0) || _aerodromeRouter == address(0) || _aerodromeFactory == address(0)
                || initialOwner == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        // The LP vault is permanently wired to protocol-critical roots and the canonical
        // Aerodrome WETH/CLAIM volatile pool. A malformed deployment can otherwise pass the
        // Furnace-side backpointer checks yet still stream protocol CLAIM to stakers of an
        // arbitrary LP token after one-way freeze.
        if (
            _weth.code.length == 0 || _claim.code.length == 0 || _ve.code.length == 0 || _furnace.code.length == 0
                || _aerodromeRouter.code.length == 0
        ) {
            revert Errors.NotAContract();
        }
        _rejectDelegatedEOA(_weth);
        _rejectDelegatedEOA(_claim);
        _rejectDelegatedEOA(_ve);
        _rejectDelegatedEOA(_furnace);
        _rejectDelegatedEOA(_aerodromeRouter);
        // The runtime `transferOwnership` surface rejects EIP-7702 delegated EOAs.
        // The constructor enforces the same rule on `initialOwner` so the genesis
        // owner cannot exercise harvest-keeper, compound-floor, and minimum-stake
        // surfaces through public executor code before the first hardened transfer.
        _rejectDelegatedEOA(initialOwner);
        if (_wethClaimStable) revert Errors.InvalidPool();

        address routerFactory = IDexAdapter(_aerodromeRouter).defaultFactory();
        if (routerFactory != _aerodromeFactory) revert Errors.FactoryMismatch();

        address routerWeth = IDexAdapter(_aerodromeRouter).weth();
        if (routerWeth != _weth) revert Errors.WrappedNativeMismatch();

        // Compare against the canonical deterministic pool address only. The pool may not be deployed
        // yet during pre-genesis wiring, so code-length checks on `_lpToken` would be too strict here.
        address canonicalPool = IDexAdapter(_aerodromeRouter).poolFor(_weth, _claim, false, _aerodromeFactory);
        if (canonicalPool == address(0) || canonicalPool != _lpToken) revert Errors.InvalidPool();

        // The vault forwards real staker reward CLAIM into Furnace on claim-and-lock and
        // auto-compound paths. If the immutable Furnace root points at a contract wired to
        // a different CLAIM token or a different ve tree, those user rewards can be
        // permanently stranded or locked against the wrong destination surface.
        if (_staticcallAddress(_furnace, _SEL_CLAIM) != _claim || _staticcallAddress(_furnace, _SEL_VE) != _ve) {
            revert Errors.WiringMismatch();
        }

        lpToken = IERC20(_lpToken);
        weth = IERC20(_weth);
        claim = IERC20(_claim);
        ve = IVeClaimNFT(_ve);
        furnace = _furnace;

        aerodromeRouter = _aerodromeRouter;
        aerodromeFactory = _aerodromeFactory;
        wethClaimStable = _wethClaimStable;

        // Initialize accountedRewardBalance to the current balance so delta-based notifications start clean.
        accountedRewardBalance = IERC20(_claim).balanceOf(address(this));
        minCompoundReward = 1e18; // 1 CLAIM dust guard; owner can adjust post-deploy
    }

    function renounceOwnership() public pure override {
        revert Errors.NotAuthorized();
    }

    /// @dev Reject EIP-7702 delegated EOAs from acquiring the owner role. A delegated
    ///      owner can let arbitrary callers exercise `setRewardKeeper`, fee-harvest
    ///      keeper rotation, and the freeze surface after acceptance.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        _rejectDelegatedEOA(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Acceptance-time re-validation. The 7702 designator can land on the
    ///      nominee between nomination and acceptance; rejecting at acceptance
    ///      keeps the owner seat off any delegated EOA.
    function acceptOwnership() public override {
        _rejectDelegatedEOA(msg.sender);
        super.acceptOwnership();
    }

    /// @dev Re-runs the EIP-7702 designator guard on `msg.sender` for every
    ///      `onlyOwner` call. A clean owner that installs `0xEF0100…` after
    ///      acceptance cannot expose owner-only surfaces (`setRewardKeeper`,
    ///      `setMinHarvestClaimFloor`, `setMinCompoundReward`, freeze) through
    ///      public-executor code. The OZ `Ownable._checkOwner` parent does not
    ///      apply this guard; the override fills that gap for `Ownable2Step`
    ///      children that are not on `UpgradeableProtocolBase`.
    function _checkOwner() internal view override {
        super._checkOwner();
        _rejectDelegatedEOA(msg.sender);
    }

    /// @notice Upper bound on `minHarvestClaimFloor` owner configuration (harvest circuit-breaker).
    /// @dev Bounds an owner-set floor so routine WETH→CLAIM harvest swaps remain reachable and
    ///      accrued fees cannot be trapped behind an unreachable minClaimOut.
    uint256 public constant MAX_MIN_HARVEST_CLAIM_FLOOR = 100_000e18; // 100,000 CLAIM

    function setMinHarvestClaimFloor(uint256 floor) external onlyOwner {
        if (floor > MAX_MIN_HARVEST_CLAIM_FLOOR) revert Errors.AmountTooLarge();
        uint256 old = minHarvestClaimFloor;
        minHarvestClaimFloor = floor;
        emit Events.MinHarvestClaimFloorSet(old, floor);
    }

    /// @notice Upper bound on `minCompoundReward` owner configuration (auto-compound dust guard).
    /// @dev Prevents an owner-set floor so large that routine rewards never exceed it, effectively disabling auto-compound.
    uint256 public constant MAX_MIN_COMPOUND_REWARD = 1000e18; // 1,000 CLAIM

    function setMinCompoundReward(uint256 floor) external onlyOwner {
        if (floor > MAX_MIN_COMPOUND_REWARD) revert Errors.AmountTooLarge();
        uint256 old = minCompoundReward;
        minCompoundReward = floor;
        emit Events.MinCompoundRewardSet(old, floor);
    }

    function setHarvestKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert Errors.ZeroAddress();
        // Reject EIP-7702 delegated EOAs as new keeper seats. The harvest path
        // routes WETH/CLAIM through `keeper` for `harvestFeesToRewards` and the
        // auto-compound batch (`compoundFor` / `compoundForMany`); a delegated
        // keeper would expose those operations to arbitrary callers.
        // Revocations (`allowed == false`) are still permitted.
        if (allowed) _rejectDelegatedEOA(keeper);
        isHarvestKeeper[keeper] = allowed;
        emit Events.HarvestKeeperSet(keeper, allowed);
    }

    // User actions

    /// @notice Stake LP tokens into the vault (bonded immediately).
    function stake(uint256 amount) external nonReentrant {
        // before _updateReward and before modifying totalStaked. This ensures any pending
        // balance-delta rewards (from a swallowed Furnace notifyRewards revert) are indexed
        // at the pre-change totalStaked denominator, preventing dilution or concentration.
        // The queued-rewards flush also uses the *new* totalStaked, which is
        // correct: the first staker should receive all queued rewards.
        if (amount == 0) revert Errors.AmountZero();
        // Reject dust stakes below Constants.MIN_UNBOND_AMOUNT so reward index math cannot overflow.
        // Symmetric with MIN_UNBOND_AMOUNT on the exit side.
        if (amount < Constants.MIN_UNBOND_AMOUNT) revert Errors.AmountTooSmall();

        _checkpointPendingRewardsBeforeStakeChange();
        _updateReward(msg.sender);

        // slither-disable-next-line reentrancy-no-eth
        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        totalStaked += amount;
        stakedBalance[msg.sender] += amount;

        // If rewards were queued while no one was staked, distribute them once staking exists again.
        // totalStaked is fresh (just updated above); no stale-denominator risk.
        // Carry any index-rounding remainder forward instead of silently dropping funded CLAIM.
        // First staker receives all queued rewards because no other stakers exist at index time.
        if (queuedRewards != 0 && totalStaked != 0) {
            uint256 queued = queuedRewards;
            queuedRewards = 0;
            _indexRewardsWithCarry(queued);
        }

        emit Events.LpStaked(msg.sender, amount);
    }

    /// @notice Begin unbonding LP tokens (must wait Constants.UNBONDING_PERIOD before withdrawal).
    function beginUnbond(uint256 amount) external nonReentrant {
        // beginUnbond sets unlockTime = block.timestamp + UNBONDING_PERIOD, and withdrawMatured
        // uses `>=` (block.timestamp >= u.unlockTime). Withdrawal is allowed at exactly the
        // boundary timestamp — no off-by-one grants early withdrawal or extra reward accrual.
        if (amount == 0) revert Errors.AmountZero();
        // Allow unbonding the full remaining balance even if below MIN_UNBOND_AMOUNT.
        if (amount < Constants.MIN_UNBOND_AMOUNT && amount != stakedBalance[msg.sender]) {
            revert Errors.AmountTooSmall();
        }
        if (stakedBalance[msg.sender] < amount) revert Errors.InsufficientStake();

        // Round up to full unbond when the residual would be below MIN_UNBOND_AMOUNT.
        uint256 residual = stakedBalance[msg.sender] - amount;
        if (residual != 0 && residual < Constants.MIN_UNBOND_AMOUNT) {
            amount = stakedBalance[msg.sender];
        }

        // Enforce Constants.MAX_UNBONDS_PER_USER active entries.
        if (_unbonds[msg.sender].length >= Constants.MAX_UNBONDS_PER_USER) revert Errors.TooManyUnbonds();

        _checkpointPendingRewardsBeforeStakeChange();
        _updateReward(msg.sender);

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        uint256 unlockTime = block.timestamp + Constants.UNBONDING_PERIOD;
        uint256 id = nextUnbondId[msg.sender]++;

        _unbonds[msg.sender].push(Unbond({id: id, amount: amount, unlockTime: unlockTime}));

        emit Events.LpUnbondStarted(msg.sender, id, amount, unlockTime);
    }

    /// @notice Withdraw all matured unbond entries (user may hold at most `MAX_UNBONDS_PER_USER` active unbonds).
    function withdrawMatured() external nonReentrant {
        // Swap-and-pop reorders the array, so off-chain UIs that index unbonds by position
        // (getUnbondByIndex) will see IDs shuffled after partial withdrawals. Use the `id` field
        // for stable identification. All matured entries are processed regardless of order.
        Unbond[] storage arr = _unbonds[msg.sender];

        uint256 totalOut = 0;
        uint256 i = 0;
        while (i < arr.length) {
            Unbond memory u = arr[i];
            if (block.timestamp >= u.unlockTime) {
                if (u.amount != 0) {
                    totalOut += u.amount;
                    emit Events.LpUnbondWithdrawn(msg.sender, u.id, u.amount);
                }
                // swap&pop (also prunes zero-amount entries to prevent slot exhaustion)
                arr[i] = arr[arr.length - 1];
                arr.pop();
            } else {
                unchecked {
                    ++i;
                }
            }
        }

        if (totalOut == 0) return;
        lpToken.safeTransfer(msg.sender, totalOut);
    }

    /// @notice Claim liquid CLAIM rewards.
    function claimRewards() external nonReentrant {
        _checkpointPendingRewardsBeforeRewardConsumption();
        _updateReward(msg.sender);

        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;

        rewards[msg.sender] = 0;
        // Maintain the disjoint-debt invariant: clearing the user's stored rewards
        // balance debits both the O(1) `Σ rewards[user]` aggregator and the indexed
        // pool that backed it.
        unchecked {
            totalRewardsCredited -= reward;
            indexedClaimOwed -= reward;
        }

        // slither-disable-next-line reentrancy-no-eth
        claim.safeTransfer(msg.sender, reward);

        totalClaimRewardsClaimed += reward;

        // Decrease by paid amount only; preserves any unaccounted CLAIM (e.g. from failed best-effort notify).
        _decreaseAccountedRewardBalance(reward);

        emit Events.LpRewardsClaimed(msg.sender, reward);
    }

    /// @notice Claim rewards then route through Furnace so the Furnace bonus applies.
    ///  Routes via Furnace.enterWithClaimFor (this vault is allowlisted by Furnace).
    function claimRewardsAndLock(uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
        external
        nonReentrant
    {
        _checkpointPendingRewardsBeforeRewardConsumption();
        _updateReward(msg.sender);

        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;

        if (minVeOut == 0) revert Errors.MinVeOutRequired();
        if (durationSeconds < Constants.MIN_LOCK_DURATION || durationSeconds > Constants.MAX_LOCK_DURATION) {
            revert Errors.InvalidDuration();
        }
        if (createAutoMax) {
            if (targetTokenId != 0) revert Errors.AutoMaxMismatch();
            if (durationSeconds != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
        }

        if (block.timestamp < lastUserLockTs[msg.sender] + MIN_COMPOUND_INTERVAL) revert LockCooldown();
        lastUserLockTs[msg.sender] = block.timestamp;

        // The quote drives the canonical principal / bonus emitted in
        // `LpRewardsLocked`. Bubbling a quoter revert keeps the event truthful:
        // a successful lock implies a successful quote with non-zero principal
        // and a known bonus split, so subgraph history never reports a
        // zero-principal / zero-bonus lock from a transient quoter outage.
        uint256 principalClaim;
        uint256 bonusClaim;
        {
            (uint256 p, uint256 b,,) = IFurnaceQuoter(IFurnace(furnace).furnaceQuoter())
                .quoteEnterWithClaim(msg.sender, reward, targetTokenId, durationSeconds, createAutoMax);
            principalClaim = p;
            bonusClaim = b;
        }

        rewards[msg.sender] = 0;
        // Debit aggregators in lockstep with the user-balance clear: the Furnace call
        // below pulls exactly `reward` CLAIM out of this vault, so the indexed bucket
        // shrinks by the same amount to preserve the disjoint-debt invariant.
        unchecked {
            totalRewardsCredited -= reward;
            indexedClaimOwed -= reward;
        }

        // Approve Furnace to pull CLAIM from this vault (exact amount; do not accumulate approvals).
        // via SafeApprove.callApprove which avoids the ERC-20 approval race condition. The pattern:
        //   1. Read current allowance (SafeERC20View.callAllowance — gas-bounded, no returndata bomb)
        //   2. If current != 0, set to 0 first
        //   3. Set to exact `reward` amount
        //   4. After use, immediately clear back to 0
        // Prevents approval front-running. SafeApprove/SafeERC20View add returndata-bomb hardening.
        _forceApprove(claim, furnace, reward);

        // Furnace applies bonus + routes into user's selected lock destination.
        // IMPORTANT: emit the actual destination token id returned by Furnace.
        // When `targetTokenId == 0`, quotes intentionally return the placeholder `0`,
        // but execution returns the newly minted lock id.
        // slither-disable-next-line reentrancy-no-eth
        uint256 tokenIdUsed = IFurnace(furnace)
            .enterWithClaimFor(msg.sender, reward, targetTokenId, durationSeconds, createAutoMax, minVeOut);

        // Clear approval to reduce external pull surface.
        _forceApprove(claim, furnace, 0);

        totalClaimRewardsLockedViaFurnace += reward;

        // Decrease by locked amount only; preserves any unaccounted CLAIM (e.g. from failed best-effort notify).
        _decreaseAccountedRewardBalance(reward);

        emit Events.LpRewardsLocked(msg.sender, reward, principalClaim, bonusClaim, tokenIdUsed);
    }

    // Auto-compound configuration

    /// @notice Configure LP reward auto-compounding into Furnace for the caller.
    function setAutoCompoundConfig(
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    ) external nonReentrant {
        _setAutoCompoundConfig(msg.sender, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound);
    }

    /// @notice Delegation-gated config setter (safe, non-custodial).
    /// @dev Requires `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR`.
    function setAutoCompoundConfigForUser(
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    ) external nonReentrant {
        if (user == address(0)) revert Errors.ZeroAddress();

        uint256 perms = DelegationPermissions.P_SET_LP_AUTOCOMPOUND_CONFIG_FOR;
        _requireDelegated(user, perms);

        uint256 refId =
            _setAutoCompoundConfig(user, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound);
        emit Events.DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR,
            perms,
            refId,
            block.timestamp
        );
    }

    function _setAutoCompoundConfig(
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    ) internal returns (uint256 refId) {
        // If disabling, clear config fields (ABI expects explicit values).
        if (!enabled) {
            tokenId = 0;
            durationSeconds = 0;
            maxSlippageBps = 0;
            minRewardToCompound = 0;
        } else {
            if (maxSlippageBps > 1000) revert Errors.SlippageTooHigh();
            // Validate duration.
            if (durationSeconds < Constants.MIN_LOCK_DURATION || durationSeconds > Constants.MAX_LOCK_DURATION) {
                revert Errors.InvalidDuration();
            }

            // Validate destination lock eligibility.
            if (tokenId == 0) revert Errors.InvalidToken();

            // ownerOf reverts if tokenId does not exist.
            if (ve.ownerOf(tokenId) != user) revert Errors.NotAuthorized();

            (, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
            if (listed) revert Errors.LockListedOrFrozen();
            if (lockEnd <= block.timestamp) revert Errors.LockExpired();
            if (autoMax && durationSeconds != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
        }

        AutoCompoundConfig storage cfg = _autoCompound[user];
        cfg.enabled = enabled;
        if (cfg.paused) {
            cfg.paused = false;
            emit Events.AutoCompoundUnpaused(user);
        }
        cfg.tokenId = tokenId;
        cfg.durationSeconds = durationSeconds;
        cfg.maxSlippageBps = maxSlippageBps;
        cfg.minRewardToCompound = minRewardToCompound;

        emit Events.AutoCompoundConfigured(user, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound);
        return tokenId;
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory.
    ///      Gas-bounded: forwards at most 30 000 gas to prevent untrusted callees from consuming
    ///      the caller's entire gas budget during wiring checks.
    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)

            let success := staticcall(30000, target, ptr, 0x04, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    out := and(mload(ptr), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    /// @dev Delegated LP auto-compound config must authorize against the same canonical
    ///      delegation hub that the live MineCore surface exposes through the same shared
    ///      Furnace root. Otherwise a stale or foreign Furnace-like contract can return an
    ///      attacker-controlled hub and bypass the intended auth model after core/furnace drift.
    function _resolveCanonicalDelegationHub() internal view returns (address hub) {
        address f = furnace;
        if (f == address(0) || f.code.length == 0) revert Errors.WiringMismatch();

        if (_staticcallAddress(f, _SEL_CLAIM) != address(claim) || _staticcallAddress(f, _SEL_VE) != address(ve)) {
            revert Errors.WiringMismatch();
        }

        address core = _staticcallAddress(f, _SEL_MINE_CORE);
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();
        if (
            _staticcallAddress(core, _SEL_CLAIM) != address(claim) || _staticcallAddress(core, _SEL_VE) != address(ve)
                || _staticcallAddress(core, _SEL_FURNACE) != f
        ) {
            revert Errors.WiringMismatch();
        }

        hub = _staticcallAddress(f, _SEL_DELEGATION_HUB);
        if (hub == address(0) || hub.code.length == 0) revert Errors.WiringMismatch();
        if (_staticcallAddress(core, _SEL_DELEGATION_HUB) != hub) revert Errors.WiringMismatch();
    }

    function _requireDelegated(address user, uint256 requiredPerms) internal view {
        address hub = _resolveCanonicalDelegationHub();

        if (!IDelegationHub(hub).isAuthorized(user, msg.sender, requiredPerms)) revert Errors.NotAuthorized();
    }

    function getAutoCompoundConfig(address user)
        external
        view
        returns (
            bool enabled,
            bool paused,
            uint256 tokenId,
            uint256 durationSeconds,
            uint32 maxSlippageBps,
            uint256 minRewardToCompound
        )
    {
        AutoCompoundConfig storage cfg = _autoCompound[user];
        return (cfg.enabled, cfg.paused, cfg.tokenId, cfg.durationSeconds, cfg.maxSlippageBps, cfg.minRewardToCompound);
    }

    // Auto-compound execution

    /// @notice Owner-or-keeper-allowlisted executor that compounds `user`'s LP rewards via Furnace.
    /// @dev minVeOut is computed from Furnace quote + user maxSlippageBps; executor cannot control it.
    function compoundFor(address user) external nonReentrant onlyHarvestKeeper {
        // Between the user's last reward accrual and this compound execution, the CLAIM/veCLAIM
        // exchange rate (Furnace bonus curve) may have moved. The minVeOut is computed from a
        // current Furnace quote (via `_quoteCompound`), so the user gets live slippage protection.
        // Mitigating factors against unfavorable timing:
        //   - Keeper is onlyOwner or allowlisted (trusted role)
        //   - maxSlippageBps is user-configurable (default 3%)
        //   - If quote fails, compound is skipped (see `_quoteCompound`)
        _compoundFor(user);
    }

    /// @notice Owner-or-keeper-allowlisted, gas-bounded batch executor for LP reward auto-compound.
    /// @dev Best-effort per user: each user is processed independently.
    function compoundForMany(address[] calldata users, uint256 maxUsers) external nonReentrant onlyHarvestKeeper {
        uint256 n = users.length;
        if (maxUsers < n) n = maxUsers;
        if (n > Constants.MAX_LP_COMPOUND_USERS_PER_CALL) n = Constants.MAX_LP_COMPOUND_USERS_PER_CALL;

        for (uint256 i = 0; i < n;) {
            _compoundFor(users[i]);
            unchecked {
                ++i;
            }
        }
    }

    // Rewards funding

    /// @notice Notify the vault that CLAIM rewards have been funded.
    /// @dev MUST use balance-delta accounting (amountClaim is not trusted).
    function notifyRewards(uint256 amountClaim) external nonReentrant onlyRewardNotifier {
        uint256 bal = claim.balanceOf(address(this));
        uint256 delta = bal > accountedRewardBalance ? bal - accountedRewardBalance : 0;
        if (delta > 0 && amountClaim > 0) {
            uint256 diff = delta > amountClaim ? delta - amountClaim : amountClaim - delta;
            if (diff > amountClaim / 100) {
                emit Events.NotifyAmountDivergence(amountClaim, delta);
            }
        } else if (delta > 0 && amountClaim == 0) {
            emit Events.NotifyAmountDivergence(amountClaim, delta);
        }
        _notifyRewardsFromBalanceDelta(msg.sender);
    }

    /// @dev Pro-rata index update. totalStaked is a state variable updated on stake/unbond (not time-decaying),
    ///      so denominator freshness is guaranteed by construction. toDistribute comes from balance-delta
    ///      (claim.balanceOf(this) - accountedRewardBalance), so no stale external amount. No over-credit from staleness.
    function _notifyRewardsFromBalanceDelta(address source) internal {
        bool countAsFurnace = source == furnace;
        bool countAsVaultFees = source == address(this);
        _checkpointRewardsFromBalanceDelta(countAsFurnace, countAsVaultFees);
    }

    /// @dev Furnace can transfer CLAIM to this vault and intentionally swallow a notifyRewards() revert so
    ///      unrelated entry/stream flows stay live. That leaves real rewards sitting in the vault but not yet
    ///      reflected in rewardPerTokenStored. If stake/unbond changes totalStaked before the balance delta is
    ///      indexed, newcomers can capture old rewards or exits can push old rewards onto remaining stakers.
    ///      Even without a denominator change, manual claim/lock surfaces would otherwise leave the pending
    ///      delta stranded until some later notify or stake change happens. Checkpoint that pending balance
    ///      delta before any reward-consuming action. Source-specific funding counters increment only on
    ///      explicit notifier paths; opportunistic balance-delta checkpointing does not carry reliable
    ///      provenance for those counters.
    function _checkpointPendingRewardsBeforeStakeChange() internal {
        _checkpointRewardsFromBalanceDelta(false, false);
    }

    function _checkpointPendingRewardsBeforeRewardConsumption() internal {
        _checkpointRewardsFromBalanceDelta(false, false);
    }

    function _checkpointRewardsFromBalanceDelta(bool countAsFurnace, bool countAsVaultFees) internal {
        uint256 bal = claim.balanceOf(address(this));
        uint256 prev = accountedRewardBalance;

        uint256 delta = 0;
        if (bal > prev) {
            delta = bal - prev;
            accountedRewardBalance = bal;

            if (countAsFurnace) {
                totalClaimRewardsFundedFromFurnace += delta;
            } else if (countAsVaultFees) {
                totalClaimRewardsFundedFromVaultFees += delta;
            }
        }

        if (delta == 0 && queuedRewards == 0) return;

        if (totalStaked == 0) {
            queuedRewards += delta;
        } else {
            uint256 toDistribute = delta;
            if (queuedRewards != 0) {
                toDistribute += queuedRewards;
                queuedRewards = 0;
            }

            _indexRewardsWithCarry(toDistribute);
        }

        if (delta > 0) emit Events.LpRewardsNotified(delta);
    }

    /// @dev Updates rewardPerTokenStored using floor rounding and keeps any undistributed remainder queued.
    ///      This prevents real funded CLAIM from becoming permanently stranded when index math rounds down.
    function _indexRewardsWithCarry(uint256 amount) internal {
        if (amount == 0) return;

        uint256 staked = totalStaked;
        if (staked == 0) {
            queuedRewards += amount;
            return;
        }

        uint256 rptIncrement = Math.mulDiv(amount, Constants.ACC, staked);
        if (rptIncrement == 0) {
            queuedRewards += amount;
            return;
        }

        // M-AccountingFloorDrift guard: skip the rpt bump when the back-computed
        // `indexedAmount` floors to zero. A non-zero `rpt` jump that credits user
        // accruals (`stakedBalance * rpt - paid` flooring) without a matching CLAIM
        // movement into the indexed pool would violate the disjoint-debt invariant.
        // Carry the full amount instead so the next non-trivial notify can index it.
        uint256 indexedAmount = Math.mulDiv(rptIncrement, staked, Constants.ACC);
        if (indexedAmount == 0) {
            queuedRewards += amount;
            return;
        }

        rewardPerTokenStored += rptIncrement;
        if (rewardPerTokenStored > type(uint128).max) revert Errors.RewardIndexOverflow();
        // Credit the indexed-debt accumulator in lockstep with the rpt bump so
        // per-user accruals can be clamped against this pool.
        indexedClaimOwed += indexedAmount;

        uint256 remainder = amount - indexedAmount;
        if (remainder != 0) {
            queuedRewards += remainder;
        }
    }

    /// @notice Preview current harvest inputs and router quote (best effort).
    function previewHarvestFeesToRewards()
        external
        view
        returns (uint256 feeWeth, uint256 feeClaim, uint256 expectedClaimOut)
    {
        // WARNING: This preview does not (and cannot) call claimFees(). It only reports
        // balances already sitting in the vault. Unclaimed fees in the Aerodrome pool are
        // NOT included. Keepers SHOULD use eth_call simulation for accurate previews.
        feeWeth = weth.balanceOf(address(this));

        // After the real harvest checkpoints pending rewards, accountedRewardBalance
        // equals claim.balanceOf(this). Any CLAIM that arrives from claimFees() after
        // that point is the only "fee" CLAIM. Since this view cannot call claimFees(),
        // feeClaim from the pool is unknown here. Report 0 and document the limitation.
        feeClaim = 0;

        expectedClaimOut = 0;
        if (feeWeth > 0) {
            IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
            routes[0] = IAerodromeRouter.Route({
                from: address(weth), to: address(claim), stable: wethClaimStable, factory: aerodromeFactory
            });

            // Best-effort quote. If router reverts, return 0.
            try IAerodromeRouter(aerodromeRouter).getAmountsOut(feeWeth, routes) returns (uint256[] memory amounts) {
                if (amounts.length > 0) expectedClaimOut = amounts[amounts.length - 1];
            } catch {
                expectedClaimOut = 0;
            }
        }
    }

    /// @notice Harvest Aerodrome LP fees (WETH + CLAIM) and credit them as additional LP rewards.
    /// @dev Owner-or-keeper-allowlisted. Swaps WETH -> CLAIM, then notifies rewards using
    ///      balance-delta accounting.
    /// @param deadline Swap deadline timestamp.
    ///
    /// SECURITY: The on-chain quote floor (HARVEST_MAX_SLIPPAGE_BPS, 100 bps i.e. 1%) does NOT protect against
    /// sandwich attacks because getAmountsOut and the swap read the same manipulable pool state.
    /// Keepers MUST compute minClaimOut off-chain from a TWAP or oracle and submit via a private
    /// relay (e.g. Flashbots Protect) to prevent MEV extraction.
    /// @param minClaimOut Caller-supplied minimum CLAIM out for the WETH swap. MUST be computed
    ///        off-chain from a TWAP or oracle price — the on-chain quote floor is only a sanity check
    ///        and does not prevent sandwich attacks. Keepers should submit via a private relay
    ///        (e.g. Flashbots Protect) for full MEV protection. Reverts if zero when WETH is swapped.
    function harvestFeesToRewards(uint256 deadline, uint256 minClaimOut) external nonReentrant onlyHarvestKeeper {
        // slither-disable-start reentrancy-balance
        // `nonReentrant` prevents callback re-entry; Slither still flags balance-derived locals across
        // Aerodrome `claimFees` and the WETH->CLAIM swap — no exploitable cross-function reentrancy.
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_HARVEST_DEADLINE) revert DeadlineTooFar();

        // getAmountsOut from the same Aerodrome pool that the swap targets. An attacker who
        // manipulates pool reserves (sandwich) shifts both the quote and the swap price in lockstep,
        // making the floor ineffective. Keepers must use off-chain TWAP + private relay for
        // real MEV protection.
        // CLAIM can already be sitting in the vault from a prior best-effort notify failure on the
        // Furnace LP rewards stream. If harvest treated that pre-existing pending balance as "feeClaim",
        // it would inflate vault-fee counters/events. Checkpoint any such pending rewards first, without
        // attributing them to the fee-harvest counters for this call.
        _checkpointPendingRewardsBeforeRewardConsumption();

        // 1) Claim fees from Aerodrome pool.
        // Make claimFees failure non-fatal to prevent permanent harvest DoS.
        // slither-disable-next-line reentrancy-no-eth
        try IAerodromePool(address(lpToken)).claimFees() returns (uint256, uint256) {}
            catch {
            // Best-effort: if claimFees() reverts, continue with any WETH/CLAIM already in the vault.
        }

        // 2) Observe balances as "fees to process" for this harvest.
        uint256 feeWeth = weth.balanceOf(address(this));
        uint256 feeClaim = _unaccountedClaimFees();

        if (feeWeth == 0 && feeClaim == 0) revert NoFeesToHarvest();

        // 3) Swap WETH -> CLAIM.
        uint256 wethToSwap = feeWeth;

        if (wethToSwap == 0 && minClaimOut > 0) emit Events.HarvestMinClaimOutIgnored(minClaimOut);

        // Early enforcement of the owner-set absolute floor. Prevents keepers from
        // submitting swaps with a minClaimOut below the circuit-breaker threshold.
        // When no WETH is swapped, `minClaimOut` is ignored rather than forced to zero so
        // claim-only fee harvests remain keeper-friendly and do not require branch-specific inputs.
        if (wethToSwap > 0 && minClaimOut == 0) revert MinClaimOutRequired();
        uint256 hardFloor = minHarvestClaimFloor;
        if (wethToSwap > 0 && hardFloor != 0 && minClaimOut < hardFloor) revert MinClaimFloorNotMet();
        uint256 effectiveMinClaimOut = _effectiveMinClaimOutForHarvest(wethToSwap, minClaimOut);
        uint256 claimBought = _swapWethToClaim(wethToSwap, effectiveMinClaimOut, deadline);

        // 4) Credit rewards.
        uint256 claimToRewards = feeClaim + claimBought;
        if (claimToRewards > 0) {
            _notifyRewardsFromBalanceDelta(address(this));
        }

        // 5) Update harvest tracking + emit.
        lastFeeHarvestTs = block.timestamp;

        emit Events.LpFeesHarvestedToRewards(msg.sender, feeWeth, feeClaim, claimToRewards);
        // slither-disable-end reentrancy-balance
    }

    // Views (UI convenience)

    /// @notice View helper for off-chain UIs.  Includes pending balance-delta rewards.
    /// @dev Mirrors `_indexRewardsWithCarry` floor-rounding so the result closely matches
    ///      what `_updateReward` would actually credit. Rounding remainders are excluded.
    function earned(address user) external view returns (uint256) {
        uint256 rpt = rewardPerTokenStored;
        uint256 staked = totalStaked;
        if (staked != 0) {
            uint256 pending = 0;
            uint256 bal = claim.balanceOf(address(this));
            uint256 prev = accountedRewardBalance;
            if (bal > prev) {
                pending = bal - prev;
                if (queuedRewards != 0) pending += queuedRewards;
            } else if (queuedRewards != 0) {
                pending = queuedRewards;
            }
            if (pending != 0) {
                uint256 rptIncrement = Math.mulDiv(pending, Constants.ACC, staked);
                // Mirror `_indexRewardsWithCarry`: only project the rpt bump when the
                // back-computed `indexedAmount` is non-zero. The preview must match
                // what `_checkpointPendingRewardsBeforeRewardConsumption` would
                // actually persist, otherwise it over-states `earned()` by O(N) wei
                // across N tiny notify cycles (M-AccountingFloorDrift class).
                if (rptIncrement != 0) {
                    uint256 indexedAmount = Math.mulDiv(rptIncrement, staked, Constants.ACC);
                    if (indexedAmount != 0) {
                        rpt += rptIncrement;
                    }
                }
            }
        }
        return _earnedWithRpt(user, rpt);
    }

    function getUnbondCount(address user) external view returns (uint256) {
        return _unbonds[user].length;
    }

    function getUnbondByIndex(address user, uint256 index)
        external
        view
        returns (uint256 unbondId, uint256 amount, uint256 unlockTime)
    {
        Unbond storage u = _unbonds[user][index];
        return (u.id, u.amount, u.unlockTime);
    }

    // Internal reward helpers

    /// @dev Decreases accountedRewardBalance by the amount paid out/locked.
    ///      Preserves any unaccounted CLAIM (e.g. from failed best-effort Furnace notifyRewards).
    function _decreaseAccountedRewardBalance(uint256 amount) internal {
        if (amount > accountedRewardBalance) {
            emit Events.AccountedRewardBalanceClamped(amount, accountedRewardBalance);
            accountedRewardBalance = 0;
        } else {
            accountedRewardBalance -= amount;
        }
    }

    function _earned(address user) internal view returns (uint256) {
        uint256 rpt = rewardPerTokenStored;
        uint256 paid = userRewardPerTokenPaid[user];
        uint256 bal = stakedBalance[user];

        uint256 accrued = 0;
        if (rpt > paid && bal != 0) {
            accrued = Math.mulDiv(bal, rpt - paid, Constants.ACC);
            // Clamp the per-user accrual to the unallocated portion of the indexed
            // pool. Combined-floor across N notify cycles can over-credit a user by
            // O(N) wei vs the indexed bucket; clamping at credit time enforces the
            // disjoint-debt invariant `Σ rewards[user] <= indexedClaimOwed`.
            uint256 unallocated;
            unchecked {
                unallocated = indexedClaimOwed - totalRewardsCredited;
            }
            if (accrued > unallocated) accrued = unallocated;
        }

        return rewards[user] + accrued;
    }

    function _earnedWithRpt(address user, uint256 rpt) internal view returns (uint256) {
        uint256 paid = userRewardPerTokenPaid[user];
        uint256 bal = stakedBalance[user];
        uint256 accrued = 0;
        if (rpt > paid && bal != 0) {
            accrued = Math.mulDiv(bal, rpt - paid, Constants.ACC);
            // When the caller has inflated `rpt` to project a pending notify (see
            // external `earned()`), project the matching `indexedClaimOwed` growth
            // so the clamp uses the post-checkpoint unallocated pool. The projected
            // delta mirrors `_indexRewardsWithCarry`'s
            // `indexedAmount = mulDiv(rptIncrement, staked, ACC)`.
            uint256 projectedIndexed = indexedClaimOwed;
            uint256 storedRpt = rewardPerTokenStored;
            if (rpt > storedRpt) {
                uint256 staked = totalStaked;
                if (staked != 0) {
                    projectedIndexed += Math.mulDiv(rpt - storedRpt, staked, Constants.ACC);
                }
            }
            uint256 unallocated;
            unchecked {
                unallocated = projectedIndexed - totalRewardsCredited;
            }
            if (accrued > unallocated) accrued = unallocated;
        }
        return rewards[user] + accrued;
    }

    function _updateReward(address user) internal {
        // `_earned()` applies the per-user clamp against
        // `indexedClaimOwed - totalRewardsCredited`, so the delta below is bounded
        // by the unallocated pool. Tracking the delta into `totalRewardsCredited`
        // maintains the O(1) `Σ rewards[user]` accumulator the disjoint-debt
        // invariant depends on (avoids iterating the per-user mapping).
        uint256 oldRewards = rewards[user];
        uint256 newRewards = _earned(user);
        if (newRewards != oldRewards) {
            unchecked {
                totalRewardsCredited += newRewards - oldRewards;
            }
            rewards[user] = newRewards;
        }
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }

    struct CompoundQuoteResult {
        uint256 minVeOut;
        bool quoteOk;
        uint256 principalClaim;
        uint256 bonusClaim;
        uint256 routeTokenId;
    }

    /// @dev Computes minVeOut from Furnace quote and user's maxSlippageBps. Ignores executor-provided values.
    function _computeMinVeOutForCompound(
        address user,
        uint256 reward,
        uint256 tokenId,
        uint256 effectiveDurationSeconds
    ) internal view returns (CompoundQuoteResult memory res) {
        try IFurnaceQuoter(IFurnace(furnace).furnaceQuoter())
            .quoteEnterWithClaim(user, reward, tokenId, effectiveDurationSeconds, false) returns (
            uint256 p, uint256 b, uint256 veOut, uint256 r
        ) {
            // `Furnace.enterWithClaimFor` requires `minVeOut > 0`, so a quote that
            // yields `veOut == 0` cannot produce a valid auto-compound order. Leave
            // `quoteOk = false` and let `_compoundFor` no-op for this round rather
            // than handing off a doomed `minVeOut = 0` and tripping a pause/skip
            // through `MinVeOutNotMet`. Mirrors the `ShareholderRoyalties` path.
            if (veOut == 0) return res;
            uint256 slippageBps = _autoCompound[user].maxSlippageBps;
            if (slippageBps == 0) slippageBps = Constants.DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS;
            if (slippageBps > Constants.BPS_DENOM) slippageBps = Constants.BPS_DENOM;
            res.minVeOut = (veOut * (Constants.BPS_DENOM - slippageBps)) / Constants.BPS_DENOM;
            // `Furnace.enter*` requires `minVeOut > 0`. Clamp rounding-to-zero cases.
            if (res.minVeOut == 0) res.minVeOut = 1;
            res.quoteOk = true;
            res.principalClaim = p;
            res.bonusClaim = b;
            res.routeTokenId = r;
        } catch {
            // res remains default (quoteOk = false)
        }
    }

    function _compoundFor(address user) internal {
        // Never revert per-user: batch executor relies on best-effort behavior.
        if (user == address(0)) return;

        AutoCompoundConfig storage cfg = _autoCompound[user];
        if (!cfg.enabled || cfg.paused) return;
        if (block.timestamp < lastCompoundTs[user] + MIN_COMPOUND_INTERVAL) return;

        uint256 tokenId = cfg.tokenId;

        // Validate destination lock eligibility at execution time (policy: skip + pause).
        if (tokenId == 0) {
            cfg.paused = true;
            emit Events.AutoCompoundPaused(user, 0, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID);
            return;
        }

        try ve.ownerOf(tokenId) returns (address owner) {
            if (owner != user) {
                cfg.paused = true;
                emit Events.AutoCompoundPaused(user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER);
                return;
            }
        } catch {
            cfg.paused = true;
            emit Events.AutoCompoundPaused(
                user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID
            );
            return;
        }

        // Wrap getLockInfo in try/catch to prevent batch revert propagation.
        uint256 lockEnd = 0;
        bool autoMax = false;
        bool listed = false;
        try ve.getLockInfo(tokenId) returns (uint256, uint256 _lockEnd, bool _autoMax, bool _listed) {
            lockEnd = _lockEnd;
            autoMax = _autoMax;
            listed = _listed;
        } catch {
            cfg.paused = true;
            emit Events.AutoCompoundPaused(
                user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID
            );
            return;
        }
        if (listed) {
            cfg.paused = true;
            emit Events.AutoCompoundPaused(user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED);
            return;
        }
        if (lockEnd <= block.timestamp) {
            cfg.paused = true;
            emit Events.AutoCompoundPaused(user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED);
            return;
        }

        _checkpointPendingRewardsBeforeRewardConsumption();
        _updateReward(user);
        uint256 reward = rewards[user];
        {
            uint256 effectiveMin = cfg.minRewardToCompound;
            uint256 globalMin = minCompoundReward;
            if (effectiveMin < globalMin) effectiveMin = globalMin;
            if (reward < effectiveMin) return;
        }

        // LP auto-compound duration is extension-only for existing locks:
        // honor the user's configured target remaining duration, but never shorten
        // a lock that already has more remaining time.
        uint256 remainingDurationSeconds = lockEnd - block.timestamp;
        uint256 effectiveDurationSeconds = cfg.durationSeconds;
        if (remainingDurationSeconds > effectiveDurationSeconds) {
            effectiveDurationSeconds = remainingDurationSeconds;
        }
        if (autoMax) effectiveDurationSeconds = Constants.MAX_LOCK_DURATION;
        if (effectiveDurationSeconds > Constants.MAX_LOCK_DURATION) {
            effectiveDurationSeconds = Constants.MAX_LOCK_DURATION;
        }
        if (effectiveDurationSeconds < Constants.MIN_LOCK_DURATION) {
            cfg.paused = true;
            emit Events.AutoCompoundPaused(user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED);
            return;
        }

        // Compute minVeOut from quote + user config; skip when quote fails (no slippage protection).
        CompoundQuoteResult memory quote = _computeMinVeOutForCompound(user, reward, tokenId, effectiveDurationSeconds);
        if (!quote.quoteOk) return;

        // CEI: zero user rewards before external call; restore on failure.
        rewards[user] = 0;
        // Provisionally debit `totalRewardsCredited` in lockstep with the user-balance
        // clear. `indexedClaimOwed` is decremented only on success because the indexed
        // pool shrinks only when CLAIM actually leaves the vault to Furnace; on
        // rollback the Furnace call did not consume CLAIM and the indexed bucket is
        // unchanged.
        unchecked {
            totalRewardsCredited -= reward;
        }
        _forceApprove(claim, furnace, reward);

        // slither-disable-next-line reentrancy-no-eth
        try IFurnace(furnace)
            .enterWithClaimFor(user, reward, tokenId, effectiveDurationSeconds, false, quote.minVeOut) returns (
            uint256 tokenIdUsed
        ) {
            _forceApprove(claim, furnace, 0);
            unchecked {
                indexedClaimOwed -= reward;
            }

            lastCompoundTs[user] = block.timestamp;
            _decreaseAccountedRewardBalance(reward);
            totalClaimRewardsLockedViaFurnace += reward;
            emit Events.LpRewardsLocked(user, reward, quote.principalClaim, quote.bonusClaim, tokenIdUsed);
        } catch {
            _forceApprove(claim, furnace, 0);
            rewards[user] = reward;
            unchecked {
                totalRewardsCredited += reward;
            }
            cfg.paused = true;
            emit Events.AutoCompoundPaused(
                user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT
            );
        }
    }

    // Internals (fee harvest)

    /// @dev CLAIM fees should exclude the already-accounted rewards reserve.
    ///      Otherwise the vault's reward float would be misinterpreted as "fees".
    function _unaccountedClaimFees() internal view returns (uint256) {
        // Combined with _checkpointPendingRewardsBeforeRewardConsumption() at the top of
        // harvestFeesToRewards, any pending balance-delta is indexed before observing
        // unaccounted fees (prevents double-counting). _indexRewardsWithCarry handles
        // rounding remainders via queuedRewards, so no funded CLAIM is permanently stranded.
        uint256 claimBal = claim.balanceOf(address(this));
        uint256 accounted = accountedRewardBalance;
        return claimBal > accounted ? (claimBal - accounted) : 0;
    }

    /// @dev Sanity-check floor from on-chain quote. Does NOT protect against sandwich attacks
    ///      (quote and swap read the same manipulable state). Real MEV protection comes from the
    ///      caller-supplied minClaimOut computed off-chain against a TWAP or oracle price.
    function _effectiveMinClaimOutForHarvest(uint256 wethToSwap, uint256 callerMinClaimOut)
        // effectiveMinClaimOut uses max(callerMinClaimOut, onChainFloor); onChainFloor is derived from
        // the same manipulable pool state as the swap, so it is not sandwich-proof.
        // A keeper who sets minClaimOut artificially low still gets at least the on-chain floor, which
        // is quotedOut * (1 - HARVEST_MAX_SLIPPAGE_BPS / BPS_DENOM) (100 bps => ~1% vs spot quote).
        internal
        view
        returns (uint256)
    {
        if (wethToSwap == 0) return 0;

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({
            from: address(weth), to: address(claim), stable: wethClaimStable, factory: aerodromeFactory
        });

        uint256 quotedOut = 0;
        try IAerodromeRouter(aerodromeRouter).getAmountsOut(wethToSwap, routes) returns (uint256[] memory amounts) {
            if (amounts.length > 0) quotedOut = amounts[amounts.length - 1];
        } catch {
            revert HarvestQuoteFailed();
        }
        if (quotedOut == 0) revert HarvestQuoteFailed();

        uint256 floor = (quotedOut * (BPS_DENOM - Constants.HARVEST_MAX_SLIPPAGE_BPS)) / BPS_DENOM;
        if (
            callerMinClaimOut > 0 && floor > 0
                && callerMinClaimOut < Math.mulDiv(floor, Constants.CALLER_QUOTE_MIN_FLOOR_PCT, 100)
        ) {
            revert CallerQuoteDivergence();
        }
        uint256 result = callerMinClaimOut > floor ? callerMinClaimOut : floor;
        uint256 hardFloor = minHarvestClaimFloor;
        if (hardFloor != 0 && result < hardFloor) revert MinClaimFloorNotMet();
        return result;
    }

    /// @dev Swap WETH -> CLAIM on Aerodrome and return the amount of CLAIM bought.
    ///      Isolated into a helper to reduce local stack pressure in harvestFeesToRewards.
    function _swapWethToClaim(uint256 wethToSwap, uint256 minClaimOut, uint256 deadline)
        internal
        returns (uint256 claimBought)
    {
        if (wethToSwap == 0) {
            // No swap executes in this branch, so caller-provided `minClaimOut` is irrelevant.
            return 0;
        }

        uint256 claimBefore = claim.balanceOf(address(this));

        _forceApprove(weth, aerodromeRouter, wethToSwap);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({
            from: address(weth), to: address(claim), stable: wethClaimStable, factory: aerodromeFactory
        });

        IAerodromeRouter(aerodromeRouter)
            .swapExactTokensForTokens(wethToSwap, minClaimOut, routes, address(this), deadline);

        // Clear approval to reduce external pull surface.
        _forceApprove(weth, aerodromeRouter, 0);

        uint256 claimAfter = claim.balanceOf(address(this));
        claimBought = claimAfter > claimBefore ? (claimAfter - claimBefore) : 0;
    }

    /// @dev Approve pattern that works across common ERC20 implementations.
    function _forceApprove(IERC20 token, address spender, uint256 value) internal {
        (uint256 current, bool ok) = SafeERC20View.callAllowance(token, address(this), spender);
        if (ok && current == value) return;

        // When decreasing or switching spenders, always clear first.
        // If allowance can't be read safely, clear anyway to preserve USDT-style compatibility
        // without exposing return-data bomb DoS on allowance().
        if (!ok || current != 0) {
            if (!SafeApprove.callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
        }

        if (value != 0) {
            if (!SafeApprove.callApprove(token, spender, value)) revert Errors.ApprovalFailed();
        }
    }
}
