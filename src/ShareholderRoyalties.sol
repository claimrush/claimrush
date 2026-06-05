// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Constants} from "./lib/Constants.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IFurnace} from "./interfaces/IFurnace.sol";
import {IFurnaceQuoter} from "./interfaces/IFurnaceQuoter.sol";
import {IDelegationHub} from "./interfaces/IDelegationHub.sol";
import {IShareholderRoyalties} from "./interfaces/IShareholderRoyalties.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "./lib/DelegationActionTypes.sol";
import {UpgradeableProtocolBase} from "./lib/UpgradeableProtocolBase.sol";

interface IFurnaceReciprocalWiringView {
    function mineCore() external view returns (address);
    function mineMarket() external view returns (address);
    function shareholderRoyalties() external view returns (address);
}

interface IMineCoreReciprocalWiringView {
    function furnace() external view returns (IFurnace);
    function claimAllHelper() external view returns (address);
}

interface IClaimAllHelperReciprocalWiringView {
    function royalties() external view returns (IShareholderRoyalties);
    function mineCore() external view returns (address);
}

/// @notice ETH-per-ve index contract for veCLAIM holders ("Barons").
/// @dev Spec-driven implementation (docs/spec/spec-v1.0.0.md §6).
contract ShareholderRoyalties is UpgradeableProtocolBase, IShareholderRoyalties {
    // Selector constants used by `_staticcallAddress`.
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_MINE_MARKET = bytes4(keccak256("mineMarket()"));
    bytes4 internal constant _SEL_SHAREHOLDER_ROYALTIES = bytes4(keccak256("shareholderRoyalties()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_CLAIM_TOKEN = bytes4(keccak256("claimToken()"));
    bytes4 internal constant _SEL_CLAIM_ALL_HELPER = bytes4(keccak256("claimAllHelper()"));
    bytes4 internal constant _SEL_ROYALTIES = bytes4(keccak256("royalties()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));

    IVeClaimNFT public immutable ve;

    // Freeze (one-way config lock for core game-rule wiring)
    bool public configFrozen;

    IFurnace public furnace;

    address public mineCore;
    address public mineMarket;
    address public claimAllHelper;

    // `ethPerVe` uses 1e18 scale and is advanced against VeClaimNFT's scaled ve-bias model.
    // This preserves delayed-claim correctness for decaying locks.
    uint256 public ethPerVe;
    // delta can reach ~1e36 (SHAREHOLDER_ACC = 1e36) and rewardTs is ~1.1e12 (year ~2040).
    // Per-flush contribution ~1.1e48. Overflow of uint256 (2^256 ~ 1.16e77) would require
    // ~1e29 flushes — unreachable under block gas limits, but Solidity 0.8 checked math
    // would revert and permanently DoS _flushPendingShareholderETH.
    uint256 public pendingShareholderETH;
    // Tracks ETH that has already been advanced into the Baron index but has not yet
    // left the contract via a successful claim / auto-compound. Owner dust sweeping
    // MUST exclude this bucket and the unindexed `pendingShareholderETH` carry.
    // Exposed via the auto-generated `indexedEthOwed()` getter so external invariant
    // tracers (Echidna properties, off-chain monitors) can verify the disjoint-
    // buckets invariant without forcing storage reads through assembly.
    uint256 public indexedEthOwed;
    // O(1) aggregator of `Σ _claimableEthStored(user)`. Maintained at every
    // `_claimableEthStored` mutation (credited in `checkpointUser`, debited in
    // `_consumeReservedEth`). Lets `sweepDust` include crystallised user claims in
    // the reserved-balance check without iterating the per-user mapping.
    // Disjoint-buckets invariant: `totalCrystallisedStored + indexedEthOwed +
    // pendingShareholderETH == address(this).balance` at every external entry boundary.
    uint256 public totalCrystallisedStored;

    /// @notice Hard cap for auto-compound slippage (bps). Limits keeper MEV exposure.
    uint32 internal constant MAX_AUTOCOMPOUND_SLIPPAGE_BPS = 2000;

    uint256 internal constant SHAREHOLDER_WEIGHT_SCALE = 1e18;
    uint256 internal constant SHAREHOLDER_ACC = Constants.ACC * SHAREHOLDER_WEIGHT_SCALE;

    /// @dev Set to true during compoundForMany to skip redundant per-user wiring
    ///      validations.  The batch entry already validates wiring once, and
    ///      nonReentrant prevents state changes mid-batch.
    bool private _batchWiringVerified;

    struct RewardCheckpoint {
        uint40 timestamp;
        uint256 cumulativeEthPerVe;
        uint256 cumulativeTimeWeightedEthPerVe;
    }

    struct AccrualCtx {
        uint256 paid;
        uint256 startRewardTs;
        uint256 startPaidTimeWeighted;
        uint256 deltaSumAll;
    }

    enum LockEthRewardAttemptResult {
        NotAttempted,
        Success,
        Failed
    }

    RewardCheckpoint[] internal rewardCheckpoints;
    uint256 internal ethPerVeTimeWeighted;
    /// @dev Holds cumulative snapshots once the main checkpoint array is full.
    ///      The main array is frozen at MAX_REWARD_CHECKPOINTS; all subsequent
    ///      flushes append to this overflow array (capped at MAX_OVERFLOW_CHECKPOINTS)
    ///      so that `_getRewardPrefixBefore` can binary-search post-cap history.
    RewardCheckpoint[] internal _overflowCheckpoints;
    /// @dev Ring-buffer write head for `_overflowCheckpoints` once it reaches
    ///      MAX_OVERFLOW_CHECKPOINTS. Points to the oldest entry (next to be evicted).
    ///      Zero while the array is still growing (pre-cap).
    uint256 internal _overflowRingHead;

    mapping(address => uint256) public userEthPerVePaid;
    /// @dev Checkpointed claimable ETH balance for a user — storage-only crystallised
    ///      rewards, excluding uncheckpointed accrual since the user's last checkpoint.
    ///      Exposed externally via the `claimableEth(user)` view shim below, which
    ///      returns the LIVE entitlement (stored + uncheckpointed pending) computed via
    ///      `_computeShareholderState`. Internal callers MUST use this mapping when they
    ///      need the storage-only value (e.g. pay-out paths that zero after a successful
    ///      transfer).
    mapping(address => uint256) internal _claimableEthStored;
    mapping(address => uint256) internal userTimeWeightedEthPerVePaid;
    mapping(address => uint40) internal userLastRewardTs;
    mapping(address => uint256) internal userRewardRemainder;

    // Per-user auto-compound configuration (SPEC v1.0.0 §6.7)

    struct ShareholderAutoCompoundConfig {
        // Packed layout — 4 slots instead of 6.
        bool enabled; // 1 byte  ─┐
        bool paused; // 1 byte   │ slot 0
        uint32 minCadenceSeconds; // 4 bytes  │
        uint32 maxSlippageBps; // 4 bytes  │ // 0 = use DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS
        uint40 lastCompoundTs; // 5 bytes ─┘
        uint256 tokenId; //           slot 1
        uint256 durationSeconds; //           slot 2
        uint256 minEthToCompound; //           slot 3
    }

    mapping(address => ShareholderAutoCompoundConfig) internal autoCompoundConfig;
    mapping(address => bool) public isAutoCompoundKeeper;

    /// @notice Owner-settable global floor for auto-compound ETH minimum (dust guard).
    uint256 public minAutoCompoundEth;

    /// @notice Forward-gas cap (in gas units) applied to every ETH push to a user wallet.
    /// @dev Sized to fit ERC-4337 / smart-wallet `receive` / `execute` callbacks while still
    ///      capping griefing. Bounded at both ends by `_MIN_ETH_PUSH_GAS_CAP` and
    ///      `_MAX_ETH_PUSH_GAS_CAP`; tuned via `setEthPushGasCap`. Seeded in `_initialize`.
    uint256 public ethPushGasCap;

    // ─── v1.0.0 storage tail ────────────────────────────────────────────────────
    //
    // ALL future state additions to `ShareholderRoyalties` MUST be appended below
    // this banner. Inserting state above any mapping declared earlier in this file
    // shifts the mapping seed (`keccak256(slot || key)`) and corrupts every
    // existing entry — paid indices, crystallised balances, remainders, auto-compound
    // configs, keeper flags, and the gas cap above. The forge storage-layout
    // regression in `test/storage/ShareholderRoyaltiesLayout.t.sol` enforces this
    // discipline in CI.

    /// @dev Smallest `lockEnd` of any non-AutoMax shareholder lock observed by this
    ///      contract via the accrual iteration in `_computePendingAccrual`. Acts as
    ///      a structural floor on overflow eviction: a checkpoint at timestamp T
    ///      cannot be evicted while `T >= _oldestObservedNonAutoMaxLockEnd`, because
    ///      a delayed claim against the observed lock would otherwise have to
    ///      reconstruct `_getRewardPrefixBefore(lockEnd)` from a pruned tail and
    ///      under-credit. Initialized in `_initialize` to `type(uint40).max` so
    ///      that pre-observation eviction is gated only by `MAX_LOCK_DURATION`.
    ///      The watermark is monotonically non-increasing through the accrual
    ///      path. Two raise paths exist: (a) the operator override
    ///      `forceSetOldestObservedNonAutoMaxLockEnd` (raise-only, reject zero),
    ///      and (b) the owner-driven `recomputeGlobalWatermark` aggregating fresh
    ///      per-user observations.
    uint40 internal _oldestObservedNonAutoMaxLockEnd;

    /// @dev Per-user observed minimum non-AutoMax lockEnd. Populated on every
    ///      `checkpointUser` invocation (including zero-delta short-circuits) and
    ///      via the permissionless `pinUserObservedMin(user)`. The owner-driven
    ///      `recomputeGlobalWatermark(candidates)` aggregates this map to widen
    ///      `_oldestObservedNonAutoMaxLockEnd` after locks expire or convert to
    ///      AutoMax. Sentinel `type(uint40).max` means the user holds no
    ///      non-AutoMax shareholder lock at last observation.
    mapping(address => uint40) private _userObservedMinNonAutoMaxLockEnd;

    uint256 private constant _MIN_ETH_PUSH_GAS_CAP = 50_000;
    uint256 private constant _MAX_ETH_PUSH_GAS_CAP = 500_000;
    uint256 private constant _DEFAULT_ETH_PUSH_GAS_CAP = 200_000;

    /// @dev Cap on the number of candidates `recomputeGlobalWatermark` accepts in a
    ///      single call. Sized so the worst-case loop (one `ve.getShareholderLockParams`
    ///      external call per candidate) stays within block gas limits with headroom.
    uint256 private constant _MAX_WATERMARK_RECOMPUTE_CANDIDATES = 256;

    modifier whenNotFrozen() {
        if (configFrozen) revert Errors.ConfigFrozen();
        _;
    }

    modifier onlyMineCore() {
        if (msg.sender != mineCore) revert Errors.OnlyMineCore();
        _;
    }

    modifier onlyMineMarket() {
        if (msg.sender != mineMarket) revert Errors.OnlyMineMarket();
        _;
    }

    modifier onlyClaimAllHelper() {
        _requireCanonicalClaimAllHelperCaller();
        _;
    }

    modifier onlyAutoCompoundKeeper() {
        if (msg.sender != owner() && !isAutoCompoundKeeper[msg.sender]) revert Errors.NotAuthorized();
        // Runtime 7702 reject on the caller seat. A clean owner or keeper EOA at
        // seating time can install the `0xEF0100` designator afterward and route
        // `compoundFor` / `compoundForMany` through public executor code. Apply
        // the guard on the owner branch too, not only the keeper branch. Bare
        // EOAs and ordinary contracts are unaffected.
        _rejectDelegatedEOA(msg.sender);
        _;
    }

    /// @dev Reject EIP-7702 delegation designators on immutable roots and other
    ///      privileged-address sites. The 7702 designator is exactly 23 bytes
    ///      and starts with `0xEF0100`; bare EOAs (`code.length == 0`) and
    ///      normal contracts are unaffected by this check.
    function _rejectDelegatedEOA(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    constructor(address _ve, address initialOwner) {
        if (_ve == address(0)) revert Errors.ZeroAddress();

        // Core root: royalties settlement depends on this ve contract for every payout
        // checkpoint. If `_ve` is an EOA or malformed address, MineCore can still route ETH here
        // pre-freeze, but shareholder indexing/retry flows will fail forever and strand value.
        if (_ve.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_ve);

        ve = IVeClaimNFT(_ve);

        if (initialOwner != address(0)) {
            _initialize(initialOwner);
        }
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        _initialize(initialOwner);
    }

    function _initialize(address initialOwner) internal {
        if (initialOwner == address(0)) revert Errors.ZeroAddress();
        // The runtime owner-transfer surface rejects EIP-7702 delegated EOAs via
        // `_validateNewOwner`. The initializer applies the same rule so a
        // delegated `initialOwner` cannot ship as the genesis owner of the
        // royalty wiring, keeper-allowlist, gas-cap, and watermark surfaces.
        _rejectDelegatedEOA(initialOwner);
        __UpgradeableProtocolBase_init(initialOwner);
        minAutoCompoundEth = 0.0001 ether;
        ethPushGasCap = _DEFAULT_ETH_PUSH_GAS_CAP;
        // Seed the eviction-floor watermark wide-open so the structural gate is a
        // no-op until a non-AutoMax shareholder lock is observed for the first time.
        _oldestObservedNonAutoMaxLockEnd = type(uint40).max;
    }

    /// @dev Prevent accidental permanent lockout of setWiring and sweepDust.
    function renounceOwnership() public pure {
        revert Errors.NotAuthorized();
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory (prevents "return data bomb" griefing).
    ///      Gas-bounded: forwards at most 100 000 gas to prevent untrusted callees from consuming
    ///      the caller's entire gas budget during wiring checks.
    ///      This 100k gas cap is baked into immutable bytecode. Upgraded contracts in the
    ///      wiring set MUST keep view functions below 100k gas.
    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)

            let success := staticcall(100000, target, ptr, 0x04, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    out := and(mload(ptr), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    /// @dev Best-effort verification that `f` is the canonically wired Furnace for this deployment.
    ///      Baron accounting depends on MarketRouter calling `checkpointTransfer(...)` on this exact
    ///      royalties contract before any lock sale into Furnace custody. A stale or split-brain
    ///      market/core bundle therefore invalidates the current-lock-set assumption used by
    ///      `checkpointUser(...)`, even if a local Furnace-like contract still points back here.
    ///      Hot Baron checkpoint/claim/config paths must fail closed unless the live Furnace,
    ///      MarketRouter, MineCore, VeClaimNFT, and ClaimToken roots still resolve to one
    ///      canonical bundle.
    function _isReciprocallyWiredFurnace(address f) internal view returns (bool) {
        address core = mineCore;
        address market = mineMarket;
        address veAddr = address(ve);
        address claimToken = _staticcallAddress(veAddr, _SEL_CLAIM_TOKEN);

        if (f == address(0) || f.code.length == 0) return false;
        if (
            core == address(0) || market == address(0) || claimToken == address(0) || core.code.length == 0
                || market.code.length == 0 || claimToken.code.length == 0
        ) {
            return false;
        }

        return _staticcallAddress(f, _SEL_MINE_CORE) == core && _staticcallAddress(f, _SEL_MINE_MARKET) == market
            && _staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES) == address(this)
            && _staticcallAddress(f, _SEL_VE) == veAddr && _staticcallAddress(f, _SEL_CLAIM) == claimToken
            && _staticcallAddress(core, _SEL_FURNACE) == f && _staticcallAddress(core, _SEL_ROYALTIES) == address(this)
            && _staticcallAddress(core, _SEL_VE) == veAddr && _staticcallAddress(core, _SEL_CLAIM) == claimToken
            && _staticcallAddress(market, _SEL_ROYALTIES) == address(this)
            && _staticcallAddress(market, _SEL_VE) == veAddr && _staticcallAddress(market, _SEL_CLAIM) == claimToken
            && _staticcallAddress(veAddr, _SEL_FURNACE) == f && _staticcallAddress(veAddr, _SEL_MINE_MARKET) == market
            && _staticcallAddress(veAddr, _SEL_CLAIM_TOKEN) == claimToken
            && _staticcallAddress(claimToken, _SEL_MINE_CORE) == core;
    }

    /// @dev Best-effort verification that the helper-only claim path is still using the
    ///      canonical ClaimAllHelper bundle for this deployment. A stale or foreign helper
    ///      must not be able to force a Baron user's claimable ETH through LOCK_FURNACE.
    function _requireCanonicalClaimAllHelperCaller() internal view {
        address helper = claimAllHelper;
        address core = mineCore;

        if (msg.sender != helper) revert Errors.OnlyClaimAllHelper();
        if (helper == address(0) || core == address(0) || helper.code.length == 0 || core.code.length == 0) {
            revert Errors.WiringMismatch();
        }

        if (
            _staticcallAddress(core, _SEL_CLAIM_ALL_HELPER) != helper
                || _staticcallAddress(helper, _SEL_MINE_CORE) != core
                || _staticcallAddress(helper, _SEL_ROYALTIES) != address(this)
        ) {
            revert Errors.WiringMismatch();
        }
    }

    /// @dev Shareholder ETH indexing must use the same live Baron bundle as checkpoint / claim /
    ///      compound paths. Otherwise MineCore can keep pushing takeover ETH into a stale
    ///      ShareholderRoyalties surface after the canonical MarketRouter / Furnace / ve / CLAIM
    ///      tree has drifted away, silently blackholing shareholder value until operators notice.
    function _requireCanonicalBaronRuntimeBundle() internal view {
        if (!_isReciprocallyWiredFurnace(address(furnace))) revert Errors.WiringMismatch();
    }

    function setWiring(address _mineCore, address _mineMarket, address _furnace) external onlyOwner whenNotFrozen {
        if (_mineCore == address(0) || _mineMarket == address(0) || _furnace == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (_mineCore.code.length == 0 || _mineMarket.code.length == 0 || _furnace.code.length == 0) {
            revert Errors.NotAContract();
        }

        // Reject EIP-7702 delegation designators on every wiring root that this
        // call commits to storage. A delegated EOA satisfies the `code.length`
        // probe AND can pass the reciprocal Furnace selector probes during the
        // wiring/freeze transaction (the delegate code can return whatever it
        // wants), then later revoke or rotate its delegation. Once
        // `freezeConfig()` makes the wiring immutable, that rotation breaks
        // `_isReciprocallyWiredFurnace(...)` permanently and locks every hot
        // shareholder path (`checkpointUser`, `claim`, `compound`,
        // `autoCompound`) — pending ETH is then stranded behind unrescuable
        // wiring. Mirror the constructor-time `_rejectDelegatedEOA(_ve)` here
        // so the same threat model applies post-freeze.
        _rejectDelegatedEOA(_mineCore);
        _rejectDelegatedEOA(_mineMarket);
        _rejectDelegatedEOA(_furnace);

        // Flush any pending ETH under the current wiring before switching.
        if (pendingShareholderETH > 0 && _isReciprocallyWiredFurnace(address(furnace))) {
            _flushPendingShareholderETH(true);
        }
        if (pendingShareholderETH > 0) revert Errors.PendingEthNotDrained();

        mineCore = _mineCore;
        mineMarket = _mineMarket;
        furnace = IFurnace(_furnace);
        emit Events.ShareholderWiringSet(_mineCore, _mineMarket, _furnace);

        // Best-effort setter-time validation — probe Furnace's shareholderRoyalties pointer.
        // shareholderRoyalties() is intentionally omitted from IFurnace; use raw selector.
        (bool ok, bytes memory ret) = _furnace.staticcall(abi.encodeWithSignature("shareholderRoyalties()"));
        if (ok && ret.length >= 32) {
            address furnaceSR = abi.decode(ret, (address));
            if (furnaceSR != address(0) && furnaceSR != address(this)) {
                revert Errors.WiringMismatch();
            }
        }
    }

    /// @notice Permanently lock core game-rule wiring (mineCore, mineMarket, furnace) and ClaimAllHelper.
    /// @dev After freeze, only operational peripherals (autoCompoundKeeper)
    ///      remain owner-configurable.
    function freezeConfig() external onlyOwner whenNotFrozen {
        if (mineCore == address(0)) revert Errors.ZeroAddress();
        if (mineMarket == address(0)) revert Errors.ZeroAddress();
        if (address(furnace) == address(0)) revert Errors.ZeroAddress();
        if (claimAllHelper == address(0)) revert Errors.ZeroAddress();
        if (claimAllHelper.code.length == 0) revert Errors.NotAContract();
        if (address(IClaimAllHelperReciprocalWiringView(claimAllHelper).royalties()) != address(this)) {
            revert Errors.WiringMismatch();
        }
        if (IClaimAllHelperReciprocalWiringView(claimAllHelper).mineCore() != mineCore) {
            revert Errors.WiringMismatch();
        }
        if (IMineCoreReciprocalWiringView(mineCore).claimAllHelper() != claimAllHelper) {
            revert Errors.WiringMismatch();
        }
        _requireCanonicalBaronRuntimeBundle();

        configFrozen = true;
        emit Events.ConfigFrozen();
    }

    function setClaimAllHelper(address _claimAllHelper) external onlyOwner whenNotFrozen {
        if (_claimAllHelper == address(0)) revert Errors.ZeroAddress();
        if (_claimAllHelper.code.length == 0) revert Errors.NotAContract();
        // Same threat model as setWiring (above): the helper is checked via
        // reciprocal staticcalls in `_requireCanonicalClaimAllHelperCaller`, so
        // a 7702-delegated EOA could satisfy the wiring probes while the
        // delegation is in place and then revoke/rotate after freeze, wedging
        // every shareholder ETH path that flows through ClaimAllHelper.
        _rejectDelegatedEOA(_claimAllHelper);
        address oldHelper = claimAllHelper;
        claimAllHelper = _claimAllHelper;
        emit Events.ClaimAllHelperChanged(oldHelper, _claimAllHelper);
    }

    function setAutoCompoundKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert Errors.ZeroAddress();
        // Reject EIP-7702 delegated EOAs as new keeper seats. The auto-compound
        // path executes Furnace lock-creation through `keeper`; a delegated
        // keeper would expose those CLAIM-spending operations to arbitrary
        // callers. Revocations (`allowed == false`) are still permitted.
        if (allowed) _rejectDelegatedEOA(keeper);
        isAutoCompoundKeeper[keeper] = allowed;
        emit Events.ShareholderAutoCompoundKeeperSet(keeper, allowed);
    }

    function setMinAutoCompoundEth(uint256 floor) external onlyOwner {
        uint256 old = minAutoCompoundEth;
        minAutoCompoundEth = floor;
        emit Events.MinAutoCompoundEthSet(old, floor);
    }

    /// @notice Read the current overflow-eviction watermark.
    /// @dev `type(uint40).max` means no non-AutoMax shareholder lock has been
    ///      observed (or every observed lock has been retired through an
    ///      operator-driven `forceSetOldestObservedNonAutoMaxLockEnd` raise).
    function oldestObservedNonAutoMaxLockEnd() external view returns (uint40) {
        return _oldestObservedNonAutoMaxLockEnd;
    }

    /// @notice Operator override for the overflow-eviction watermark.
    /// @dev Operator-only and **strictly raise-only**. The watermark narrows
    ///      automatically through the accrual path (`checkpointUser` ->
    ///      `_computePendingAccrual`) and via `pinUserObservedMin`. Widening
    ///      flows through `recomputeGlobalWatermark` for routine maintenance;
    ///      this override is the manual escape hatch when off-chain analysis
    ///      proves a higher floor is safe. Rejects `newValue == 0` (would
    ///      freeze `_canStoreRewardCheckpoint` once the ring fills) and any
    ///      `newValue` strictly below the current watermark (preserves the
    ///      monotonic raise invariant).
    function forceSetOldestObservedNonAutoMaxLockEnd(uint40 newValue) external onlyOwner {
        if (newValue == 0) revert Errors.AmountZero();
        uint40 old = _oldestObservedNonAutoMaxLockEnd;
        if (newValue < old) revert Errors.InvariantViolation();
        if (newValue == old) return;
        _oldestObservedNonAutoMaxLockEnd = newValue;
        emit Events.OldestObservedNonAutoMaxLockEndSet(old, newValue);
    }

    /// @notice One-shot reseed of the eviction-floor watermark for upgraded proxies.
    /// @dev Storage-layout upgrades that append `_oldestObservedNonAutoMaxLockEnd`
    ///      do not run `_initialize`, so the slot reads zero on the upgraded
    ///      proxy. A zero floor blocks every overflow eviction once the ring
    ///      fills (`headTs >= 0` at `_canStoreRewardCheckpoint`), wedging
    ///      reward-checkpoint writes until a manual operator step lifts it.
    ///      This helper is the canonical one-shot lift: it sets the slot to
    ///      `type(uint40).max` (the same sentinel `_initialize` writes on
    ///      greenfield deploys) only when the slot currently reads zero. A
    ///      proxy that has already observed any non-AutoMax lock — or that
    ///      had its watermark force-set or recomputed — is left alone, so
    ///      the helper is safe to call after upgrade without disturbing
    ///      live state.
    function seedWatermarkOnUpgrade() external onlyOwner {
        if (_oldestObservedNonAutoMaxLockEnd != 0) return;
        _oldestObservedNonAutoMaxLockEnd = type(uint40).max;
        emit Events.OldestObservedNonAutoMaxLockEndSet(0, type(uint40).max);
    }

    /// @notice Per-user observed minimum non-AutoMax lockEnd.
    /// @dev Sentinel `type(uint40).max` indicates the user holds no non-AutoMax
    ///      shareholder lock at last observation. Off-chain recomputers consult
    ///      this view to assemble the candidate set for `recomputeGlobalWatermark`.
    function userObservedMinNonAutoMaxLockEnd(address user) external view returns (uint40) {
        return _userObservedMinNonAutoMaxLockEnd[user];
    }

    /// @notice Refresh the per-user observed-min from current ve state.
    /// @dev Permissionless. Reads `ve.getShareholderLockParams(user)`, recomputes
    ///      the per-user min, writes it into `_userObservedMinNonAutoMaxLockEnd`,
    ///      and narrows `_oldestObservedNonAutoMaxLockEnd` if the observation
    ///      reveals a tighter floor. Never raises the global watermark — widening
    ///      requires the owner-driven `recomputeGlobalWatermark` aggregate path.
    function pinUserObservedMin(address user) external {
        if (user == address(0)) return;
        _updateUserObservedMin(user);
    }

    /// @notice Aggregate per-user observations to widen the global watermark.
    /// @dev Owner-driven: the caller is responsible for ensuring `candidates` covers
    ///      every shareholder with an active non-AutoMax lock, otherwise the raise
    ///      can prematurely admit overflow eviction. Refreshes each candidate via
    ///      `_updateUserObservedMin` before aggregating, so caller does not need
    ///      a separate pin pass. Bounded at `_MAX_WATERMARK_RECOMPUTE_CANDIDATES`
    ///      entries per call; paginate at the operator boundary for larger sets.
    ///      Strictly raise-only: emits `OldestObservedNonAutoMaxLockEndSet` only
    ///      when `minObserved > current`.
    function recomputeGlobalWatermark(address[] calldata candidates) external onlyOwner {
        _recomputeGlobalWatermark(candidates, false);
    }

    /// @notice Aggregate per-user observations with an explicit exhaustiveness
    ///         assertion so the global watermark can clear all the way to
    ///         `type(uint40).max` when no shareholder has an active non-AutoMax
    ///         lock.
    /// @dev Owner-driven. When `exhaustive == true` the caller asserts that
    ///      `candidates` covers every shareholder that could carry a non-AutoMax
    ///      lock. If every refreshed candidate resolves to the
    ///      `type(uint40).max` sentinel (no non-AutoMax lock observed), the
    ///      global watermark is raised to `type(uint40).max` and overflow
    ///      checkpoint writes resume without requiring the manual force-set
    ///      path. With `exhaustive == false` the surface matches the
    ///      single-argument overload: the all-sentinel case leaves the
    ///      watermark unchanged.
    function recomputeGlobalWatermark(address[] calldata candidates, bool exhaustive) external onlyOwner {
        _recomputeGlobalWatermark(candidates, exhaustive);
    }

    function _recomputeGlobalWatermark(address[] calldata candidates, bool exhaustive) internal {
        uint256 n = candidates.length;
        if (n == 0) {
            // Empty exhaustive sweep is the operator escape hatch when the
            // shareholder set is provably empty: raise the global floor to the
            // sentinel ceiling so overflow checkpoint writes resume without
            // requiring a candidate list. Empty non-exhaustive call is a no-op.
            if (exhaustive) {
                uint40 currentEmpty = _oldestObservedNonAutoMaxLockEnd;
                if (currentEmpty != type(uint40).max) {
                    _oldestObservedNonAutoMaxLockEnd = type(uint40).max;
                    emit Events.OldestObservedNonAutoMaxLockEndSet(currentEmpty, type(uint40).max);
                }
            }
            return;
        }
        if (n > _MAX_WATERMARK_RECOMPUTE_CANDIDATES) revert Errors.AmountTooLarge();

        uint40 minObserved = type(uint40).max;
        bool anyConcrete = false;
        for (uint256 i = 0; i < n; i++) {
            address u = candidates[i];
            if (u == address(0)) continue;
            // Refresh the per-user storage observation without narrowing the
            // global floor as a side effect: the aggregate raise / ceiling
            // decision below is the only writer to the global floor on this
            // call, so a paginated sweep cannot silently narrow between pages
            // when an in-flight per-user observation is tighter than the
            // already-converged floor. The single-user pin path keeps using
            // `_updateUserObservedMin` so per-user pins still narrow.
            _refreshUserObservedMin(u);
            uint40 v = _userObservedMinNonAutoMaxLockEnd[u];
            if (v != 0 && v != type(uint40).max) {
                anyConcrete = true;
                if (v < minObserved) {
                    minObserved = v;
                }
            }
        }

        uint40 current = _oldestObservedNonAutoMaxLockEnd;

        // Exhaustive sweep with no concrete observations: every candidate is at
        // the sentinel ceiling, so no shareholder has an active non-AutoMax
        // lock. Raise the global watermark to the same ceiling so overflow
        // checkpoint writes resume.
        if (!anyConcrete) {
            if (exhaustive && current != type(uint40).max) {
                _oldestObservedNonAutoMaxLockEnd = type(uint40).max;
                emit Events.OldestObservedNonAutoMaxLockEndSet(current, type(uint40).max);
            }
            return;
        }

        if (minObserved > current) {
            _oldestObservedNonAutoMaxLockEnd = minObserved;
            emit Events.OldestObservedNonAutoMaxLockEndSet(current, minObserved);
        }
    }

    /// @dev Refresh a user's stored per-user observation without touching the
    ///      global watermark. Used by `_recomputeGlobalWatermark` so the
    ///      aggregate raise / ceiling decision is the only writer to the
    ///      global floor on that path. The single-user pin path keeps using
    ///      `_updateUserObservedMin` because per-user pins MUST narrow the
    ///      global floor when the refreshed observation reveals a tighter end.
    function _refreshUserObservedMin(address user) internal {
        _userObservedMinNonAutoMaxLockEnd[user] = _computeUserObservedMin(user);
    }

    /// @dev Recompute and persist a user's observed-min. Narrows the global
    ///      watermark when the observation reveals a tighter floor; never raises.
    function _updateUserObservedMin(address user) internal {
        uint40 m = _computeUserObservedMin(user);
        _userObservedMinNonAutoMaxLockEnd[user] = m;
        if (m != 0 && m != type(uint40).max && m < _oldestObservedNonAutoMaxLockEnd) {
            _oldestObservedNonAutoMaxLockEnd = m;
        }
    }

    /// @dev Pure-view recompute of a user's per-user observed-min.
    function _computeUserObservedMin(address user) internal view returns (uint40) {
        (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags) =
            ve.getShareholderLockParams(user);
        uint256 len = amounts.length;
        if (len != lockEnds.length || len != autoMaxFlags.length) revert Errors.InvariantViolation();
        uint40 m = type(uint40).max;
        for (uint256 i = 0; i < len; i++) {
            if (!autoMaxFlags[i] && amounts[i] != 0) {
                uint256 le = lockEnds[i];
                if (le != 0 && le <= type(uint40).max) {
                    uint40 le40 = uint40(le);
                    if (le40 < m) m = le40;
                }
            }
        }
        return m;
    }

    /// @notice Update the forwarded-gas cap used by every ETH push (`_callWithValueNoReturndata`).
    /// @dev Owner-only. Bounded by `_MIN_ETH_PUSH_GAS_CAP` (50k) and `_MAX_ETH_PUSH_GAS_CAP` (500k).
    ///      The 50k floor guarantees a simple EOA / basic-wallet `receive()` always fits; the 500k
    ///      ceiling bounds grief exposure from a greedy callback.
    function setEthPushGasCap(uint256 newCap) external onlyOwner {
        if (newCap < _MIN_ETH_PUSH_GAS_CAP || newCap > _MAX_ETH_PUSH_GAS_CAP) {
            revert Errors.AmountTooLarge();
        }
        uint256 old = ethPushGasCap;
        ethPushGasCap = newCap;
        emit Events.EthPushGasCapSet(old, newCap);
    }

    // MineCore advances the ve clock before the shareholder allocation path; onTakeover
    // then buffers ETH and _flushPendingShareholderETH loops checkpointTotalVe(). This
    // ensures expired locks cannot capture rewards generated after expiry.
    //
    // Trust boundary: `reignId` is emitted for indexers only and is not used as a nonce.
    // MineCore is the sole caller (enforced by onlyMineCore) and is responsible for
    // sending each reignId's shareholder share at most once across the onTakeover /
    // addPendingShareholderETH pair. A double-send would over-credit pendingShareholderETH
    // without tripping the solvency invariant; defense lives in MineCore's CEI discipline.
    function onTakeover(uint256 reignId) external payable nonReentrant onlyMineCore {
        if (msg.value == 0) {
            emit Events.ShareholderTakeoverAllocation(reignId, 0);
            return;
        }

        _requireCanonicalBaronRuntimeBundle();

        pendingShareholderETH += msg.value;
        emit Events.ShareholderTakeoverAllocation(reignId, msg.value);

        // Index takeover allocations immediately against the takeover-time shareholder set whenever
        // a processed denominator exists. Delaying indexing until a later manual flush lets new ve
        // entrants dilute rewards that were generated before they became shareholders.
        _flushPendingShareholderETH(true);
    }

    /// @notice Fallback for when onTakeover fails during takeover (best-effort royalties).
    /// @dev Same semantics as onTakeover; allows MineCore to push shareholder ETH held in retry buffer.
    function addPendingShareholderETH(uint256 reignId) external payable nonReentrant onlyMineCore {
        if (msg.value == 0) {
            emit Events.ShareholderTakeoverAllocation(reignId, 0);
            return;
        }

        _requireCanonicalBaronRuntimeBundle();

        pendingShareholderETH += msg.value;
        emit Events.ShareholderTakeoverAllocation(reignId, msg.value);

        // Best-effort retry path: if royalties were transiently unavailable during takeover,
        // index immediately on retry so the allocation cannot be diluted further.
        _flushPendingShareholderETH(true);
    }

    function flushPendingShareholderETH() external nonReentrant {
        if (pendingShareholderETH == 0) return;

        _requireCanonicalBaronRuntimeBundle();

        _flushPendingShareholderETH(false);
    }

    /// @notice Sweep untracked ETH dust that is not reserved for shareholders.
    /// @dev Conservative by design: both `pendingShareholderETH` and indexed-but-unclaimed
    ///      ETH remain shareholder liabilities until paid out. Only actual balance surplus
    ///      (for example forced ETH) may be swept. Capped at 1 ETH to keep the exception bounded.
    function sweepDust(address to) external onlyOwner nonReentrant {
        _requireCanonicalBaronRuntimeBundle();
        if (to == address(0)) revert Errors.ZeroAddress();

        // Under the disjoint-buckets invariant, crystallised user stored claims live
        // outside `indexedEthOwed` (debited at `checkpointUser`). The reserved total
        // must therefore include `totalCrystallisedStored` so dust sweeping cannot
        // touch ETH that backs unclaimed user stored balances.
        uint256 reserved = pendingShareholderETH + indexedEthOwed + totalCrystallisedStored;
        uint256 balance = address(this).balance;
        if (balance < reserved) revert Errors.InvariantViolation();

        uint256 dust = balance - reserved;
        if (dust == 0) revert Errors.AmountZero();
        if (dust > 1 ether) revert Errors.AmountTooLarge();

        bool ok = _callWithValueNoReturndata(to, dust);
        if (!ok) revert Errors.EthTransferFailed();
        emit Events.DustSwept(to, dust);
    }

    // If delta == 0 (tiny pending, large totalWeight), the ETH remains queued until a later
    // takeover makes it indexable. This carry is still shareholder-owned and MUST NOT be swept.
    function _flushPendingShareholderETH(bool bypassMinVeFlush) internal {
        uint256 pending = pendingShareholderETH;
        if (pending == 0) return;

        uint256 maxLoops = 10;
        for (uint256 j = 0; j < maxLoops; j++) {
            if (ve.globalLastTs() == block.timestamp) break;
            // slither-disable-next-line reentrancy-no-eth
            ve.checkpointTotalVe();
            if (gasleft() < 300_000) break;
        }

        // VeClaimNFT checkpointTotalVe() is intentionally bounded by MAX_SLOPE_CHANGES_PER_CALL.
        // If more expired slope-change buckets remain backlogged, globalLastTs() stays pinned in the
        // past. Indexing fresh takeover/royalty ETH at that stale timestamp lets already-expired locks
        // satisfy `lockEnd > rewardTs` and capture rewards that were generated after expiry.
        // Defer indexing until the ve system is fully checkpointed to the current block timestamp.
        uint256 rewardTsRaw = ve.globalLastTs();
        if (rewardTsRaw != block.timestamp) return;

        uint256 totalWeight = ve.totalVeBiasScaled();
        if (totalWeight == 0) return;
        if (!bypassMinVeFlush && Math.ceilDiv(totalWeight, SHAREHOLDER_WEIGHT_SCALE) < Constants.MIN_VE_FLUSH) {
            return;
        }

        if (rewardTsRaw > type(uint40).max) revert Errors.InvariantViolation();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 rewardTs = uint40(rewardTsRaw);
        if (!_canStoreRewardCheckpoint(rewardTs)) return;

        // delta = floor(pending * SHAREHOLDER_ACC / totalWeight)
        uint256 delta = Math.mulDiv(pending, SHAREHOLDER_ACC, totalWeight);
        if (delta == 0) return;

        // Solidity 0.8 reverts on overflow, so this cannot silently wrap. This monotonic
        // property is the foundation of double-claim prevention: userEthPerVePaid[user]
        // is set to current ethPerVe after each checkpoint, and idx == paid short-circuits.
        uint256 headroom = type(uint256).max - ethPerVe;
        if (delta > headroom) {
            delta = headroom;
            if (delta == 0) return;
        }
        ethPerVe += delta;

        // Checked multiply: reverts if `delta * rewardTs` overflows uint256.
        // The cumulative add is also checked: `ethPerVeTimeWeighted` is the
        // time-weighted reconstruction index for delayed-lock royalty payouts,
        // and a silent wrap on the running sum corrupts every later
        // reconstruction after the wrap point. Solidity 0.8 default arithmetic
        // is the right policy here.
        uint256 product = delta * uint256(rewardTs);
        ethPerVeTimeWeighted += product;
        _storeRewardCheckpoint(rewardTs);

        // distributed = floor(delta * totalWeight / SHAREHOLDER_ACC)
        uint256 distributed = Math.mulDiv(delta, totalWeight, SHAREHOLDER_ACC);
        pendingShareholderETH = pending - distributed;
        indexedEthOwed += distributed;

        emit Events.ShareholderFlush(distributed, delta);
    }

    /// @dev Consumes `amount` from the crystallised pool. The disjoint-buckets invariant
    ///      holds that every value moved into `_claimableEthStored` was already removed
    ///      from `indexedEthOwed` (debited in `checkpointUser`), so payout-time
    ///      consumption only updates the O(1) `totalCrystallisedStored` aggregator —
    ///      `indexedEthOwed` and `pendingShareholderETH` are untouched. The two-tuple
    ///      return is `(0, 0)` for the stored-claim path; `_attemptLockWithRestore`
    ///      reads the tuple and uses it to restore both buckets on rollback (a no-op
    ///      under this invariant).
    function _consumeReservedEth(uint256 amount) internal returns (uint256 indexedConsumed, uint256 pendingConsumed) {
        if (amount == 0) return (0, 0);
        // Defensive: under the disjoint invariant, `totalCrystallisedStored` MUST be at
        // least `amount` because the caller has just zeroed `_claimableEthStored[user]`
        // and that value is included in the aggregator.
        if (amount > totalCrystallisedStored) revert Errors.InvariantViolation();
        unchecked {
            totalCrystallisedStored -= amount;
        }
        return (0, 0);
    }

    // Only crystallises accrued rewards into _claimableEthStored (no fund transfer).
    // Permissionless: anyone may checkpoint any user. MarketRouter (wired as mineMarket)
    // calls checkpointTransfer, which delegates here.
    function checkpointUser(address user) public {
        if (user == address(0)) return;

        if (!_batchWiringVerified) {
            _requireCanonicalBaronRuntimeBundle();
        }

        uint256 idx = ethPerVe;
        uint256 paid = userEthPerVePaid[user];
        // After checkpoint, paid is set to current ethPerVe, so a second call in the same
        // block (before any new flush) is a no-op while ethPerVe is unchanged (monotonic idx >= paid).
        if (idx == paid) {
            // Zero-delta short-circuit: pay the per-user observed-min refresh ONLY
            // on first observation. Subsequent zero-delta calls leave the existing
            // pin in place — the operator-driven `recomputeGlobalWatermark` (or a
            // permissionless `pinUserObservedMin(user)` after a known lock change)
            // is responsible for widening the global watermark as locks retire.
            // This keeps the gas cost on the hot enter path (king-takeover settle)
            // bounded and preserves the EIP-170-tight `_settlePrevKingClaim`
            // headroom budget pinned by `MineCore_GasEstimationTrap`.
            //
            // First-observation sentinel covers two storage states: the post-pin
            // ceiling `type(uint40).max` (set by `_updateUserObservedMin` when the
            // user has no non-AutoMax lock) and the default `0` slot for a brand
            // new user that has never been pinned through any lifecycle hook. Both
            // resolve to a single live read so a fresh user gets pinned on the
            // next zero-delta touch and aggregates correctly under
            // `recomputeGlobalWatermark`.
            uint40 storedObservedMin = _userObservedMinNonAutoMaxLockEnd[user];
            if (storedObservedMin == 0 || storedObservedMin == type(uint40).max) {
                _updateUserObservedMin(user);
            }
            return;
        }

        uint256 latestTimeWeighted = ethPerVeTimeWeighted;
        uint40 latestRewardTs = _latestRewardTimestamp();

        // Cache old state needed for the accrual computation.
        uint256 oldTimeWeightedPaid = userTimeWeightedEthPerVePaid[user];
        uint256 oldRewardTs = uint256(userLastRewardTs[user]);
        uint256 oldRemainder = userRewardRemainder[user];

        // CEI: advance paid markers BEFORE the external call inside
        // _computePendingAccrual (ve.getShareholderLockParams).  A reentrant
        // checkpointUser call will see idx == paid and short-circuit.
        userEthPerVePaid[user] = idx;
        userTimeWeightedEthPerVePaid[user] = latestTimeWeighted;
        userLastRewardTs[user] = latestRewardTs;

        (uint256 wholeAccrued, uint256 remainder, uint40 minNonAutoMaxLockEnd) =
            _computePendingAccrual(user, paid, oldTimeWeightedPaid, oldRewardTs, oldRemainder);

        // Record the smallest observed non-AutoMax lockEnd as a structural floor on
        // overflow eviction. Watermark only narrows here; widening flows through
        // `recomputeGlobalWatermark` (owner-driven, aggregates per-user observations)
        // or the `forceSetOldestObservedNonAutoMaxLockEnd` operator override.
        _userObservedMinNonAutoMaxLockEnd[user] = minNonAutoMaxLockEnd;
        if (minNonAutoMaxLockEnd < _oldestObservedNonAutoMaxLockEnd) {
            _oldestObservedNonAutoMaxLockEnd = minNonAutoMaxLockEnd;
        }

        if (wholeAccrued != 0) {
            // Clamp the user's per-checkpoint credit to the available indexed pool.
            // The combined-floor over multiple flushes since the last checkpoint can
            // mathematically exceed `Σ_flushes distributed_i` by up to (N-1) wei
            // (floor-additivity property of `mulDiv` floor rounding —
            // M-AccountingFloorDrift class). Clamping at credit time keeps the
            // disjoint-buckets invariant strict: `Σ stored + indexed + pending ==
            // balance`. The matching `indexedEthOwed -= wholeAccrued` debit happens
            // here, not at consume time, so `_consumeReservedEth` only updates the
            // `totalCrystallisedStored` aggregator on the stored-claim path.
            if (wholeAccrued > indexedEthOwed) wholeAccrued = indexedEthOwed;
            if (wholeAccrued != 0) {
                _claimableEthStored[user] += wholeAccrued;
                indexedEthOwed -= wholeAccrued;
                totalCrystallisedStored += wholeAccrued;
                emit Events.UserCheckpointed(user, wholeAccrued);
            }
        }
        userRewardRemainder[user] = remainder;
    }

    /// @notice Batch-checkpoint multiple users in a single transaction.
    /// @dev Best-effort: reverts on individual users are silently skipped via try/catch.
    function checkpointUserBatch(address[] calldata users, uint256 maxUsers) external {
        uint256 n = users.length;
        if (maxUsers < n) n = maxUsers;
        for (uint256 i = 0; i < n;) {
            try this.checkpointUser(users[i]) {} catch {}
            unchecked {
                ++i;
            }
        }
    }

    function checkpointTransfer(address from, address to) external onlyMineMarket {
        if (from == to) return;

        checkpointUser(from);
        checkpointUser(to);
    }

    /// @dev Gas cost scales linearly with the user's lock count. At MAX_VE_NFTS_PER_USER = 32,
    ///      worst-case inner-loop cost is ~224k gas. If the ve contract's lock cap is ever raised,
    ///      this function (and by extension checkpointUser / compoundForMany batch) may exceed
    ///      block gas limits. Any ve upgrade MUST preserve the bounded-locks assumption.
    ///
    ///      The third return value, `minNonAutoMaxLockEnd`, is the smallest non-AutoMax
    ///      lockEnd observed in the iterated set (or `type(uint40).max` when no non-AutoMax
    ///      lock was observed). Callers that can write storage (e.g. `checkpointUser`)
    ///      feed this into `_oldestObservedNonAutoMaxLockEnd` to gate overflow eviction;
    ///      pure-view callers may discard it.
    function _computePendingAccrual(
        address user,
        uint256 paid,
        uint256 startPaidTimeWeighted,
        uint256 startRewardTs,
        uint256 remainder
    ) internal view returns (uint256 wholeAccrued, uint256 nextRemainder, uint40 minNonAutoMaxLockEnd) {
        minNonAutoMaxLockEnd = type(uint40).max;

        (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags) =
            ve.getShareholderLockParams(user);
        uint256 len = amounts.length;
        if (len != lockEnds.length || len != autoMaxFlags.length) revert Errors.InvariantViolation();
        if (len == 0) return (0, remainder, minNonAutoMaxLockEnd);

        uint256 idx = ethPerVe;
        if (idx == paid) return (0, remainder, minNonAutoMaxLockEnd);

        AccrualCtx memory ctx = AccrualCtx({
            paid: paid,
            startRewardTs: startRewardTs,
            startPaidTimeWeighted: startPaidTimeWeighted,
            deltaSumAll: idx - paid
        });
        nextRemainder = remainder;

        for (uint256 i = 0; i < len; i++) {
            (uint256 whole, uint256 rem, bool ok) = _computeLockAccrual(amounts[i], autoMaxFlags[i], lockEnds[i], ctx);
            // Track the smallest non-AutoMax lockEnd regardless of accrual outcome
            // so a delayed claim against an expired non-AutoMax lock still pins the
            // overflow ring head before eviction.
            if (!autoMaxFlags[i] && amounts[i] != 0) {
                uint40 le = uint40(lockEnds[i]);
                if (lockEnds[i] <= type(uint40).max && le < minNonAutoMaxLockEnd) {
                    minNonAutoMaxLockEnd = le;
                }
            }
            if (!ok) continue;

            wholeAccrued += whole;
            nextRemainder += rem;
            if (nextRemainder >= SHAREHOLDER_ACC) {
                wholeAccrued += nextRemainder / SHAREHOLDER_ACC;
                nextRemainder = nextRemainder % SHAREHOLDER_ACC;
            }
        }
    }

    function _computeLockAccrual(uint256 amount, bool autoMax, uint256 lockEnd, AccrualCtx memory ctx)
        internal
        view
        returns (uint256 whole, uint256 rem, bool ok)
    {
        if (amount == 0) return (0, 0, false);
        if (autoMax) {
            (whole, rem) = _scaleReward(amount * SHAREHOLDER_WEIGHT_SCALE, ctx.deltaSumAll);
            return (whole, rem, true);
        }
        if (lockEnd <= ctx.startRewardTs) return (0, 0, false);

        (uint256 endPaid, uint256 endTimeWeightedPaid) = _getRewardPrefixBefore(lockEnd);
        // reward checkpoints *after* creation (lockEnd > startRewardTs). Transferred/removed
        // locks are checkpointed first by MarketRouter.checkpointTransfer. Global index is
        // unaffected by individual lock changes — existing shareholders do NOT lose
        // unclaimed royalties.
        if (endPaid <= ctx.paid) return (0, 0, false);

        uint256 deltaSum = endPaid - ctx.paid;
        uint256 weightedDelta;
        // unchecked: ethPerVeTimeWeighted is accumulated in an unchecked block.
        // Modular subtraction is safe because both snapshots share the same wrap epoch.
        unchecked {
            uint256 timeWeightedDelta = endTimeWeightedPaid - ctx.startPaidTimeWeighted;
            weightedDelta = (lockEnd * deltaSum) - timeWeightedDelta;
        }
        // Defensive sanity bound — weightedDelta should never exceed lockEnd * deltaSum.
        if (weightedDelta > uint256(lockEnd) * ctx.deltaSumAll) revert Errors.InvariantViolation();
        (whole, rem) = _scaleReward(_slopeScaled(amount), weightedDelta);
        return (whole, rem, true);
    }

    // At high flush frequency (1 per block), array grows by 7200/day.
    // Binary search cost: at 10k entries ~13 iterations * 2100 = ~27k gas.
    // MAX_REWARD_CHECKPOINTS caps array growth. Once the array is full it is
    // frozen (historical entries stay immutable) and subsequent snapshots are
    // written to `_overflowCheckpoints` so that `_getRewardPrefixBefore` can
    // still return up-to-date cumulative values for active locks.
    //
    // Once the overflow array itself fills, it becomes a ring buffer: the
    // oldest entry is overwritten first (FIFO eviction via `_overflowRingHead`).
    // Safety: only entries older than MAX_LOCK_DURATION are evicted. If every
    // overflow entry is still inside the active lock horizon, flushes defer
    // before mutating the global indices so decaying-lock expiry math never has
    // to consume a "pinned timestamp / advanced cumulative" approximation.
    function _canStoreRewardCheckpoint(uint40 rewardTs) internal view returns (bool) {
        uint256 len = rewardCheckpoints.length;
        if (len < Constants.MAX_REWARD_CHECKPOINTS) return true;

        uint256 ovLen = _overflowCheckpoints.length;
        if (ovLen == 0) return true;

        uint256 lastWritten = _overflowLastWrittenIndex(ovLen);
        if (_overflowCheckpoints[lastWritten].timestamp == rewardTs) return true;
        if (ovLen < Constants.MAX_OVERFLOW_CHECKPOINTS) return true;

        uint256 head = _overflowRingHead;
        uint256 headTs = uint256(_overflowCheckpoints[head].timestamp);
        // Eviction floor: a delayed claim against any non-AutoMax shareholder
        // lock observed by this contract still needs `_getRewardPrefixBefore(lockEnd)`
        // to resolve to a real overflow entry, so the head MUST predate the
        // smallest observed non-AutoMax lockEnd before it can be evicted.
        if (headTs >= uint256(_oldestObservedNonAutoMaxLockEnd)) return false;
        return headTs + Constants.MAX_LOCK_DURATION < uint256(rewardTs);
    }

    function _storeRewardCheckpoint(uint40 rewardTs) internal {
        uint256 len = rewardCheckpoints.length;

        // --- Array full: route to overflow ---
        if (len >= Constants.MAX_REWARD_CHECKPOINTS) {
            _storeOverflowCheckpoint(rewardTs);
            return;
        }

        // --- Same-block coalesce within the array ---
        if (len != 0) {
            RewardCheckpoint storage last = rewardCheckpoints[len - 1];
            if (last.timestamp == rewardTs) {
                last.cumulativeEthPerVe = ethPerVe;
                last.cumulativeTimeWeightedEthPerVe = ethPerVeTimeWeighted;
                return;
            }
        }

        // --- Append new checkpoint ---
        rewardCheckpoints.push(
            RewardCheckpoint({
                timestamp: rewardTs, cumulativeEthPerVe: ethPerVe, cumulativeTimeWeightedEthPerVe: ethPerVeTimeWeighted
            })
        );
    }

    /// @dev Overflow checkpoint storage with ring-buffer eviction at cap.
    ///      Pre-cap: appends normally. At cap: overwrites oldest entry (FIFO)
    ///      only after it ages beyond MAX_LOCK_DURATION relative to `rewardTs`.
    ///      Distinct timestamps inside that horizon must have been filtered by
    ///      `_canStoreRewardCheckpoint`; reaching that state here is unsafe.
    function _storeOverflowCheckpoint(uint40 rewardTs) internal {
        uint256 ovLen = _overflowCheckpoints.length;

        // --- Same-block coalesce: find the most-recently-written entry ---
        if (ovLen != 0) {
            uint256 lastWritten = _overflowLastWrittenIndex(ovLen);
            if (_overflowCheckpoints[lastWritten].timestamp == rewardTs) {
                _overflowCheckpoints[lastWritten].cumulativeEthPerVe = ethPerVe;
                _overflowCheckpoints[lastWritten].cumulativeTimeWeightedEthPerVe = ethPerVeTimeWeighted;
                return;
            }
        }

        // --- Overflow array not yet full: append ---
        if (ovLen < Constants.MAX_OVERFLOW_CHECKPOINTS) {
            if (ovLen == 0) emit Events.RewardCheckpointCapReached(rewardCheckpoints.length);
            _overflowCheckpoints.push(
                RewardCheckpoint({
                    timestamp: rewardTs,
                    cumulativeEthPerVe: ethPerVe,
                    cumulativeTimeWeightedEthPerVe: ethPerVeTimeWeighted
                })
            );
            return;
        }

        // --- Overflow array full: ring-buffer eviction ---
        emit Events.OverflowCheckpointCapReached(ovLen);
        uint256 head = _overflowRingHead;
        uint256 headTs = uint256(_overflowCheckpoints[head].timestamp);

        // Evict oldest if it is beyond the lock horizon (no active lock can
        // reference it) AND beyond the smallest observed non-AutoMax lockEnd
        // (no delayed claim against an observed lock can still need it). The
        // structural-floor gate matches `_canStoreRewardCheckpoint`; reaching
        // this branch with the gate violated indicates the caller bypassed
        // `_canStoreRewardCheckpoint`.
        if (
            headTs + Constants.MAX_LOCK_DURATION < uint256(rewardTs)
                && headTs < uint256(_oldestObservedNonAutoMaxLockEnd)
        ) {
            _overflowCheckpoints[head].timestamp = rewardTs;
            _overflowCheckpoints[head].cumulativeEthPerVe = ethPerVe;
            _overflowCheckpoints[head].cumulativeTimeWeightedEthPerVe = ethPerVeTimeWeighted;
            _overflowRingHead = (head + 1) % ovLen;
        } else {
            revert Errors.InvariantViolation();
        }
    }

    /// @dev Index of the most-recently-written overflow entry.
    ///      Pre-ring: last array element. Ring-active: entry before the head (wrapping).
    function _overflowLastWrittenIndex(uint256 ovLen) internal view returns (uint256) {
        uint256 head = _overflowRingHead;
        if (head == 0) return ovLen - 1;
        return head - 1;
    }

    function _latestRewardTimestamp() internal view returns (uint40 ts) {
        uint256 ovLen = _overflowCheckpoints.length;
        if (ovLen != 0) return _overflowCheckpoints[_overflowLastWrittenIndex(ovLen)].timestamp;
        uint256 len = rewardCheckpoints.length;
        if (len != 0) ts = rewardCheckpoints[len - 1].timestamp;
    }

    /// @dev Binary search across the overflow ring buffer.
    ///      When `_overflowRingHead == 0` the array is sorted [0..ovLen).
    ///      When head != 0 the sorted logical order is [head..ovLen) ++ [0..head).
    ///      We translate logical indices to physical via `(logicalIdx + head) % ovLen`.
    function _getRewardPrefixBefore(uint256 ts) internal view returns (uint256 idx, uint256 timeWeightedIdx) {
        uint256 ovLen = _overflowCheckpoints.length;
        if (ovLen != 0) {
            uint256 head = _overflowRingHead;
            uint256 lastIdx = _overflowLastWrittenIndex(ovLen);
            RewardCheckpoint storage ovLast = _overflowCheckpoints[lastIdx];
            if (uint256(ovLast.timestamp) < ts) {
                return (ovLast.cumulativeEthPerVe, ovLast.cumulativeTimeWeightedEthPerVe);
            }

            // Binary search over logical indices [0, ovLen).
            // Physical index = (logical + head) % ovLen.
            uint256 ovLo = 0;
            uint256 ovHi = ovLen;
            while (ovLo < ovHi) {
                uint256 mid = (ovLo + ovHi) >> 1;
                uint256 phys = (mid + head) % ovLen;
                if (uint256(_overflowCheckpoints[phys].timestamp) < ts) {
                    ovLo = mid + 1;
                } else {
                    ovHi = mid;
                }
            }
            if (ovLo != 0) {
                uint256 phys = ((ovLo - 1) + head) % ovLen;
                RewardCheckpoint storage ovCp = _overflowCheckpoints[phys];
                return (ovCp.cumulativeEthPerVe, ovCp.cumulativeTimeWeightedEthPerVe);
            }
        }

        uint256 len = rewardCheckpoints.length;
        if (len == 0) return (0, 0);

        RewardCheckpoint storage last = rewardCheckpoints[len - 1];
        if (uint256(last.timestamp) < ts) {
            return (last.cumulativeEthPerVe, last.cumulativeTimeWeightedEthPerVe);
        }

        uint256 lo = 0;
        uint256 hi = len;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (uint256(rewardCheckpoints[mid].timestamp) < ts) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo == 0) return (0, 0);
        RewardCheckpoint storage cp = rewardCheckpoints[lo - 1];
        return (cp.cumulativeEthPerVe, cp.cumulativeTimeWeightedEthPerVe);
    }

    function _scaleReward(uint256 weight, uint256 indexDelta) internal pure returns (uint256 whole, uint256 rem) {
        if (weight == 0 || indexDelta == 0) return (0, 0);
        whole = Math.mulDiv(weight, indexDelta, SHAREHOLDER_ACC);
        rem = mulmod(weight, indexDelta, SHAREHOLDER_ACC);
    }

    function _slopeScaled(uint256 amount) internal pure returns (uint256) {
        // Use floor rounding to match globalBiasScaled floor semantics.
        return Math.mulDiv(amount, SHAREHOLDER_WEIGHT_SCALE, Constants.MAX_LOCK_DURATION);
    }

    /// @param mode 0 = ETH, 1 = LOCK_FURNACE
    function claimShareholder(
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant {
        _claimShareholder(msg.sender, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    /// @notice Claim on behalf of `user` (helper-only entrypoint).
    /// @dev Used by ClaimAllHelper so EOAs can call ClaimAllHelper directly and still claim for themselves.
    // claimShareholderFor does not emit DelegationSessionUsed, unlike
    // setAutoCompoundConfigForUser which does. This path uses onlyClaimAllHelper
    // (not delegation).
    function claimShareholderFor(
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant onlyClaimAllHelper {
        _claimShareholder(user, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    /// @notice Collect `user`'s Baron ETH rewards and route them to `to` (helper-only entrypoint).
    /// @dev ETH-only by construction (no lock/mode params): the looping-bot routing path where a
    ///      delegate Collects on behalf of `user` and the ETH is forwarded to the delegate. The
    ///      delegation gate (`P_CLAIM_SHAREHOLDER_FOR | P_ROUTE_SHAREHOLDER_ETH_TO_CALLER`) and the
    ///      caller-only constraint (`to == msg.sender` of the helper) are enforced in ClaimAllHelper;
    ///      this function trusts only the canonical helper via `onlyClaimAllHelper`. Adds no storage —
    ///      same crystallise/consume accounting as the user-direct ETH claim path.
    function claimShareholderForTo(address user, address payable to) external nonReentrant onlyClaimAllHelper {
        if (to == address(0)) revert Errors.ZeroAddress();

        checkpointUser(user);

        uint256 amount = _claimableEthStored[user];
        if (amount == 0) return;

        _claimableEthStored[user] = 0;
        _consumeReservedEth(amount);

        bool ok = _callWithValueNoReturndata(to, amount);
        if (!ok) revert Errors.EthTransferFailed();

        emit Events.ShareholderClaim(user, Constants.SHAREHOLDER_MODE_ETH, amount);
        emit Events.ShareholderClaimed(user, to, amount, Constants.SHAREHOLDER_MODE_ETH);
    }

    /// @notice Claim baron ETH rewards to a specified receiver address.
    /// @dev Allows smart-contract wallets whose primary address cannot receive ETH
    ///      to redirect their baron claims to an EOA or compatible receiver.
    function claimShareholderTo(
        address payable to,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant {
        if (to == address(0)) revert Errors.ZeroAddress();

        checkpointUser(msg.sender);

        uint256 amount = _claimableEthStored[msg.sender];
        if (amount == 0) return;

        _claimableEthStored[msg.sender] = 0;
        _consumeReservedEth(amount);

        if (mode == Constants.SHAREHOLDER_MODE_ETH) {
            bool ok = _callWithValueNoReturndata(to, amount);
            if (!ok) revert Errors.EthTransferFailed();
        } else if (mode == Constants.SHAREHOLDER_MODE_LOCK_FURNACE) {
            // Lock is created for msg.sender; revert if to != msg.sender to prevent misleading attribution.
            if (to != msg.sender) revert Errors.NotAuthorized();
            address f = address(furnace);
            if (!_isReciprocallyWiredFurnace(f)) revert Errors.WiringMismatch();
            IFurnace(f).lockEthReward{value: amount}(
                msg.sender, amount, targetTokenId, durationSeconds, createAutoMax, minVeOut
            );
        } else {
            revert Errors.InvalidMode();
        }

        emit Events.ShareholderClaim(msg.sender, mode, amount);
        emit Events.ShareholderClaimed(msg.sender, to, amount, mode);
    }

    function _claimShareholder(
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) internal {
        if (user == address(0)) revert Errors.ZeroAddress();

        // 1) checkpoint
        checkpointUser(user);

        // 2) read amount
        uint256 amount = _claimableEthStored[user];
        if (amount == 0) return;

        // 3) clear before external calls (CEI).
        // Combined with nonReentrant on public entries, reentrancy is fully mitigated.
        // Even without nonReentrant, CEI prevents double-spend (amount == 0 on re-entry).
        _claimableEthStored[user] = 0;
        _consumeReservedEth(amount);

        // 4) route
        if (mode == Constants.SHAREHOLDER_MODE_ETH) {
            bool ok = _callWithValueNoReturndata(user, amount);
            if (!ok) revert Errors.EthTransferFailed();
        } else if (mode == Constants.SHAREHOLDER_MODE_LOCK_FURNACE) {
            address f = address(furnace);
            if (!_isReciprocallyWiredFurnace(f)) revert Errors.WiringMismatch();
            IFurnace(f).lockEthReward{value: amount}(
                user, amount, targetTokenId, durationSeconds, createAutoMax, minVeOut
            );
        } else {
            revert Errors.InvalidMode();
        }

        emit Events.ShareholderClaim(user, mode, amount);
    }

    // Auto-compound config + execution

    function setAutoCompoundConfig(
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    ) external {
        _setAutoCompoundConfig(
            msg.sender, enabled, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps
        );
    }

    /// @notice Delegation-gated config setter (safe, non-custodial).
    /// @dev Requires `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR`. Non-custodial by construction:
    ///      (1) the destination tokenId is re-validated for user-ownership on every compound
    ///          execution via `_validateAutoCompoundDestination`; (2) the permission bit is
    ///          disjoint from every custody-moving bit in `DelegationPermissions`; (3) the
    ///          hub canonicity check in `_requireDelegated` rejects a drift between
    ///          `furnace.delegationHub()` and `mineCore.delegationHub()`.
    function setAutoCompoundConfigForUser(
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    ) external {
        if (user == address(0)) revert Errors.ZeroAddress();

        uint256 perms = DelegationPermissions.P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR;
        _requireDelegated(user, perms);

        uint256 refId = _setAutoCompoundConfig(
            user, enabled, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps
        );
        emit Events.DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR,
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
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    ) internal returns (uint256 refId) {
        ShareholderAutoCompoundConfig storage cfg = autoCompoundConfig[user];

        if (!enabled) {
            // Disable + clear pause.
            cfg.enabled = false;
            cfg.paused = false;
            // Reset cadence state so a future re-enable starts clean.
            cfg.lastCompoundTs = 0;

            // Optional clears (allowed by spec).
            cfg.tokenId = 0;
            cfg.durationSeconds = 0;
            cfg.minCadenceSeconds = 0;
            cfg.minEthToCompound = 0;
            cfg.maxSlippageBps = 0;

            emit Events.ShareholderAutoCompoundConfigured(user, false, 0, 0, 0, 0, 0);
            return 0;
        }

        if (tokenId == 0) revert Errors.InvalidToken();
        if (durationSeconds < Constants.MIN_LOCK_DURATION || durationSeconds > Constants.MAX_LOCK_DURATION) {
            revert Errors.InvalidDuration();
        }

        // Validate destination token exists and is owned by user.
        address tokenOwner = address(0);
        try ve.ownerOf(tokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (tokenOwner != user) revert Errors.NotAuthorized();

        (, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
        if (listed) revert Errors.LockListedOrFrozen();
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();
        if (autoMax && durationSeconds != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();

        cfg.enabled = true;
        cfg.paused = false;
        cfg.tokenId = tokenId;
        cfg.durationSeconds = durationSeconds;
        cfg.minCadenceSeconds = minCadenceSeconds;
        cfg.minEthToCompound = minEthToCompound;
        if (maxSlippageBps > MAX_AUTOCOMPOUND_SLIPPAGE_BPS) revert Errors.SlippageTooHigh();
        if (maxSlippageBps >= uint32(Constants.BPS_DENOM)) revert Errors.SlippageTooHigh();
        cfg.maxSlippageBps = maxSlippageBps;

        emit Events.ShareholderAutoCompoundConfigured(
            user, true, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps
        );
        return tokenId;
    }

    function _requireDelegated(address user, uint256 requiredPerms) internal view {
        address f = address(furnace);
        if (f == address(0)) revert Errors.ZeroAddress();
        if (!_isReciprocallyWiredFurnace(f)) revert Errors.WiringMismatch();

        address hub = furnace.delegationHub();
        if (hub == address(0)) revert Errors.ZeroAddress();
        if (hub.code.length == 0) revert Errors.NotAContract();
        if (_staticcallAddress(mineCore, _SEL_DELEGATION_HUB) != hub) revert Errors.WiringMismatch();

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
            uint32 minCadenceSeconds,
            uint256 minEthToCompound,
            uint32 maxSlippageBps,
            uint40 lastCompoundTs
        )
    {
        ShareholderAutoCompoundConfig storage cfg = autoCompoundConfig[user];
        enabled = cfg.enabled;
        paused = cfg.paused;
        tokenId = cfg.tokenId;
        durationSeconds = cfg.durationSeconds;
        minCadenceSeconds = cfg.minCadenceSeconds;
        minEthToCompound = cfg.minEthToCompound;
        maxSlippageBps = cfg.maxSlippageBps;
        lastCompoundTs = cfg.lastCompoundTs;
    }

    /// @notice Compound a single user's ETH royalties into a Furnace ve-lock.
    /// @dev Owner-or-keeper-allowlisted. The internal minVeOut is derived from a spot quote (sanity-check floor only —
    ///      does NOT prevent sandwich attacks). Offchain maintainer calls SHOULD submit via
    ///      a private relay (e.g. Flashbots Protect) for real MEV protection; owner
    ///      break-glass should do the same when practical. See _computeMinVeOutForCompound.
    function compoundFor(address user) external nonReentrant onlyAutoCompoundKeeper {
        if (user == address(0)) revert Errors.ZeroAddress();
        ShareholderAutoCompoundConfig storage cfg = autoCompoundConfig[user];
        if (!cfg.enabled) revert Errors.AutoCompoundNotEnabled();
        if (cfg.paused) revert Errors.AutoCompoundPaused();

        // Cadence.
        // lastCompoundTs == 0 means "never compounded" and MUST NOT block the first compound.
        if (cfg.lastCompoundTs != 0 && block.timestamp < uint256(cfg.lastCompoundTs) + uint256(cfg.minCadenceSeconds)) {
            revert Errors.CadenceNotMet();
        }

        // Always checkpoint before reading claimable.
        checkpointUser(user);
        uint256 amount = _claimableEthStored[user];
        {
            uint256 effectiveMinEth = cfg.minEthToCompound;
            uint256 globalMin = minAutoCompoundEth;
            if (effectiveMinEth < globalMin) effectiveMinEth = globalMin;
            if (amount == 0 || amount < effectiveMinEth) {
                if (amount != 0) emit Events.ShareholderAutoCompoundFailed(user, amount, cfg.tokenId);
                return;
            }
        }

        // Validate destination; pause-on-invalid.
        (bool ok, uint8 reason, uint256 tokenId, uint256 effectiveDuration) =
            _validateAutoCompoundDestination(user, cfg);
        if (!ok) {
            cfg.paused = true;
            emit Events.ShareholderAutoCompoundPaused(user, cfg.tokenId, reason);
            return;
        }

        // CEI ordering; bubble Furnace revert.
        (uint256 minVeOut, bool quoteOk) =
            _computeMinVeOutForCompound(user, amount, tokenId, effectiveDuration, cfg.maxSlippageBps);
        if (!quoteOk) revert Errors.CompoundQuoteFailed();

        address f = address(furnace);
        if (!_isReciprocallyWiredFurnace(f)) revert Errors.WiringMismatch();

        _claimableEthStored[user] = 0;
        _consumeReservedEth(amount);
        cfg.lastCompoundTs = uint40(block.timestamp);

        // Slither false-positive: ETH is sent only to the configured Furnace protocol contract.
        // slither-disable-next-line arbitrary-send-eth
        IFurnace(f).lockEthReward{value: amount}(user, amount, tokenId, effectiveDuration, false, minVeOut);

        emit Events.ShareholderAutoCompoundExecuted(user, msg.sender, amount, tokenId, effectiveDuration);
        emit Events.ShareholderClaim(user, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, amount);
    }

    /// @notice Batch-compound ETH royalties for multiple users.
    /// @dev Owner-or-keeper-allowlisted. Same MEV caveat as compoundFor — offchain maintainer
    ///      calls SHOULD use a private relay, and owner break-glass should do the same when
    ///      practical.
    function compoundForMany(address[] calldata users, uint256 maxUsers) external nonReentrant onlyAutoCompoundKeeper {
        _requireCanonicalBaronRuntimeBundle();
        _batchWiringVerified = true;

        uint256 n = users.length;
        if (maxUsers < n) n = maxUsers;
        if (n > Constants.MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL) {
            n = Constants.MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL;
        }

        address executor = msg.sender;
        for (uint256 i = 0; i < n; i++) {
            // slither-disable-next-line reentrancy-no-eth
            if (!_compoundForUserInBatch(executor, users[i])) {
                emit Events.ShareholderBatchTerminatedEarly(i, n);
                break;
            }
        }

        _batchWiringVerified = false;
    }

    function _compoundForUserInBatch(address executor, address user) internal returns (bool shouldContinue) {
        if (user == address(0)) return true;
        ShareholderAutoCompoundConfig storage cfg = autoCompoundConfig[user];
        if (!cfg.enabled || cfg.paused) return true;

        // Cadence: skip when too soon.
        // lastCompoundTs == 0 means "never compounded" and MUST NOT block the first compound.
        if (cfg.lastCompoundTs != 0 && block.timestamp < uint256(cfg.lastCompoundTs) + uint256(cfg.minCadenceSeconds)) {
            return true;
        }

        // Checkpoint per-user (best-effort: isolate per-user failures so a
        // single user's ve-state revert cannot DoS the entire batch).
        // slither-disable-next-line reentrancy-no-eth
        try this.checkpointUser(user) {}
        catch {
            cfg.paused = true;
            emit Events.ShareholderAutoCompoundPaused(
                user, cfg.tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_CHECKPOINT_FAILED
            );
            return true;
        }
        uint256 amount = _claimableEthStored[user];
        {
            uint256 effectiveMinEth = cfg.minEthToCompound;
            uint256 globalMin = minAutoCompoundEth;
            if (effectiveMinEth < globalMin) effectiveMinEth = globalMin;
            if (amount == 0 || amount < effectiveMinEth) {
                if (amount != 0) {
                    emit Events.ShareholderAutoCompoundFailed(user, amount, cfg.tokenId);
                }
                return true;
            }
        }

        // Validate destination; pause-on-invalid.
        (bool ok, uint8 reason, uint256 tokenId, uint256 effectiveDuration) =
            _validateAutoCompoundDestination(user, cfg);
        if (!ok) {
            cfg.paused = true;
            emit Events.ShareholderAutoCompoundPaused(user, cfg.tokenId, reason);
            return true;
        }

        // Best-effort semantics: do not revert batch if Furnace reverts.
        (uint256 minVeOut, bool quoteOk) =
            _computeMinVeOutForCompound(user, amount, tokenId, effectiveDuration, cfg.maxSlippageBps);
        if (!quoteOk) {
            emit Events.ShareholderAutoCompoundFailed(user, amount, tokenId);
            return true;
        }

        LockEthRewardAttemptResult result =
            _attemptLockWithRestore(user, cfg, amount, tokenId, effectiveDuration, minVeOut);

        if (result == LockEthRewardAttemptResult.Success) {
            emit Events.ShareholderAutoCompoundExecuted(user, executor, amount, tokenId, effectiveDuration);
            emit Events.ShareholderClaim(user, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, amount);
            return true;
        }

        if (result == LockEthRewardAttemptResult.NotAttempted) {
            return false;
        }

        cfg.paused = true;
        emit Events.ShareholderAutoCompoundPaused(
            user, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT
        );
        emit Events.ShareholderAutoCompoundFailed(user, amount, tokenId);
        return true;
    }

    /// @dev Optimistic-update + rollback pattern ("EIR"). State is advanced before the
    ///      Furnace interaction and fully restored on failure.
    ///      SAFETY: Depends on `compoundForMany` / `compoundFor` holding the `nonReentrant`
    ///      guard. Removing `nonReentrant` from callers would break the isolation guarantee.
    function _attemptLockWithRestore(
        address user,
        ShareholderAutoCompoundConfig storage cfg,
        uint256 amount,
        uint256 tokenId,
        uint256 effectiveDuration,
        uint256 minVeOut
    ) internal returns (LockEthRewardAttemptResult result) {
        uint40 oldLast = cfg.lastCompoundTs;
        _claimableEthStored[user] = 0;
        // Under the disjoint-buckets invariant, `_consumeReservedEth` returns (0, 0)
        // for every stored-claim path: the indexed debit happens at `checkpointUser`
        // time and pending is not touched by stored claims. The aggregator decrement
        // happens inside `_consumeReservedEth`. Capturing the tuple keeps the rollback
        // structurally complete: any future bucket-touching consume logic surfaces
        // here automatically instead of silently leaving state mid-flight.
        (uint256 indexedConsumed, uint256 pendingConsumed) = _consumeReservedEth(amount);
        cfg.lastCompoundTs = uint40(block.timestamp);

        result = _lockEthRewardBestEffort(user, amount, tokenId, effectiveDuration, minVeOut);
        if (result == LockEthRewardAttemptResult.Success) return result;

        _claimableEthStored[user] = amount;
        indexedEthOwed += indexedConsumed;
        pendingShareholderETH += pendingConsumed;
        // Mirror the totalCrystallisedStored decrement performed inside _consumeReservedEth.
        totalCrystallisedStored += amount;
        cfg.lastCompoundTs = oldLast;
    }

    /// @dev Computes minVeOut from Furnace spot quote and user's maxSlippageBps.
    ///      WARNING: This floor does NOT prevent sandwich attacks — the quote and the subsequent
    ///      Furnace swap read the same manipulable state. Real MEV protection relies on keepers
    ///      submitting compound txs via a private relay (e.g. Flashbots Protect).
    /// @return minVeOut The computed minimum ve output (sanity-check floor only).
    /// @return quoteOk True if quote succeeded; false if it failed (caller must skip to avoid executing without any floor).
    // The quote and the subsequent Furnace swap read the same manipulable state.
    // Operational mitigation: private submission (e.g. Flashbots Protect) for compound transactions.
    function _computeMinVeOutForCompound(
        address user,
        uint256 ethAmount,
        uint256 tokenId,
        uint256 effectiveDuration,
        uint32 slippageBpsOverride
    ) internal view returns (uint256 minVeOut, bool quoteOk) {
        address quoter = furnace.furnaceQuoter();
        if (quoter == address(0)) return (0, false);
        try IFurnaceQuoter(quoter).quoteEnterWithEth(user, ethAmount, tokenId, effectiveDuration, false) returns (
            uint256, uint256, uint256 veOut, uint256
        ) {
            if (veOut == 0) return (0, false);
            uint256 slippageBps = uint256(slippageBpsOverride);
            if (slippageBps == 0) slippageBps = Constants.DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS;
            if (slippageBps >= Constants.BPS_DENOM) revert Errors.SlippageTooHigh();
            minVeOut = (veOut * (Constants.BPS_DENOM - slippageBps)) / Constants.BPS_DENOM;
            // `Furnace.enter*` requires `minVeOut > 0`. If the computed floor rounds down to 0,
            // clamp to 1 wei of ve so keepers don't revert on "0 floor" configurations.
            if (minVeOut == 0 && veOut > 0) minVeOut = 1;
            return (minVeOut, true);
        } catch {
            return (0, false);
        }
    }

    function _lockEthRewardBestEffort(
        address user,
        uint256 amount,
        uint256 tokenId,
        uint256 effectiveDuration,
        uint256 minVeOut
    ) internal returns (LockEthRewardAttemptResult result) {
        // EIP-150: a call can receive at most `gasleft() - gasleft()/64`.
        // Keep a fixed buffer so we can restore state in the caller on failure without reverting the batch.
        // If the local batch gas has already fallen below that floor, do not classify the user as failed:
        // no downstream Furnace call was attempted yet.
        uint256 g = gasleft();
        uint256 cap = g - (g / 64);
        if (cap <= Constants.FURNACE_LOCK_GAS_BUFFER) return LockEthRewardAttemptResult.NotAttempted;
        uint256 callGas = cap - Constants.FURNACE_LOCK_GAS_BUFFER;

        address f = address(furnace);
        // Defensive: never allow value-sending calls to an EOA or a miswired protocol contract.
        // A false result here also means no Furnace call was attempted.
        // Skip the expensive 16-staticcall wiring check when called from a batch that
        // already validated wiring at entry (compoundForMany).
        if (!_batchWiringVerified && !_isReciprocallyWiredFurnace(f)) {
            return LockEthRewardAttemptResult.NotAttempted;
        }

        bytes memory data = abi.encodeWithSelector(
            IFurnace.lockEthReward.selector, user, amount, tokenId, effectiveDuration, false, minVeOut
        );

        bool success;
        // Avoid "return bomb" griefing by not copying returndata.
        assembly {
            success := call(callGas, f, amount, add(data, 0x20), mload(data), 0, 0)
        }
        return success ? LockEthRewardAttemptResult.Success : LockEthRewardAttemptResult.Failed;
    }

    function _callWithValueNoReturndata(address to, uint256 value) internal returns (bool ok) {
        // Forward at most `ethPushGasCap` gas so recipients cannot execute expensive cross-contract
        // logic during the callback, while leaving enough budget for ERC-4337 / smart-wallet
        // receive hooks. Returndata is discarded to avoid return bombs.
        //
        // In gas-starved contexts we forward whatever's left untouched: clipping down would
        // only harm the caller. The `+ 5000` buffer absorbs the EIP-150 64/64 overhead so the
        // callee effectively sees `cap` gas when we do clip.
        uint256 cap = ethPushGasCap;
        assembly {
            let callGas := gas()
            if and(gt(cap, 0), gt(callGas, add(cap, 5000))) { callGas := cap }
            ok := call(callGas, to, value, 0, 0, 0, 0)
        }
    }

    function _validateAutoCompoundDestination(address user, ShareholderAutoCompoundConfig storage cfg)
        internal
        view
        returns (bool ok, uint8 reason, uint256 tokenId, uint256 effectiveDuration)
    {
        tokenId = cfg.tokenId;
        if (tokenId == 0) {
            return (false, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID, 0, 0);
        }

        // ownerOf reverts on invalid tokenId.
        address tokenOwner = address(0);
        try ve.ownerOf(tokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            return (false, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID, tokenId, 0);
        }

        if (tokenOwner != user) {
            return (false, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER, tokenId, 0);
        }

        (, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
        if (listed) {
            return (false, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED, tokenId, 0);
        }
        if (lockEnd <= block.timestamp) {
            return (false, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED, tokenId, 0);
        }

        // NOTE: `lockEnd > block.timestamp` is already verified above, so `remaining` is always > 0 here.
        // The ternary is defensive-only but can never take the else branch.
        uint256 remaining = lockEnd > block.timestamp ? (lockEnd - block.timestamp) : 0;

        // Non-AutoMax locks with < MIN_LOCK_DURATION remaining are ineligible as
        // compound destinations (the Furnace would revert with InvalidDuration).
        if (!autoMax && remaining < Constants.MIN_LOCK_DURATION) {
            return (false, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED, tokenId, 0);
        }

        // Auto-compound duration is extension-only for existing locks:
        // honor the user's configured target remaining duration, but never shorten
        // a lock that already has more remaining time.
        effectiveDuration = cfg.durationSeconds;
        if (remaining > effectiveDuration) effectiveDuration = remaining;

        // AutoMax keeps its MAX-duration semantics.
        if (autoMax) effectiveDuration = Constants.MAX_LOCK_DURATION;

        return (true, 0, tokenId, effectiveDuration);
    }

    /// @notice Live claimable ETH for a shareholder, including uncheckpointed accrual.
    /// @dev Routes through `_computeShareholderState` so external callers receive the full live
    ///      entitlement (stored + pending). The storage-only value is exposed separately via
    ///      `claimableEthStored(address)` for callers that specifically need the crystallised
    ///      balance (off-chain indexers, storage-invariant assertions).
    function claimableEth(address user) external view returns (uint256) {
        (uint256 live,,) = _computeShareholderState(user);
        return live;
    }

    /// @notice Checkpointed, storage-only claimable ETH for a shareholder.
    /// @dev Excludes uncheckpointed accrual since the user's last checkpoint. Matches the value
    ///      an internal payout path would consume after calling `checkpointUser`. Use `claimableEth`
    ///      for the live entitlement.
    function claimableEthStored(address user) external view returns (uint256) {
        return _claimableEthStored[user];
    }

    /// @notice Live shareholder claim preview.
    /// @dev `claimable` includes stored `_claimableEthStored[user]` plus any uncheckpointed rewards implied by
    ///      historical reward checkpoints. Offchain clients MUST treat the returned `claimable` as
    ///      authoritative and MUST NOT recompute `claimable + userVe * (ethPerVe - paid) / ACC`, because
    ///      decaying locks require historical flush timestamps.
    function getShareholderState(address user) external view returns (uint256 claimable, uint256 userVe, uint256 paid) {
        return _computeShareholderState(user);
    }

    /// @dev Shared live-preview computation used by `getShareholderState` and the
    ///      `claimableEth` view shim. Returns `(claimable, userVe, paid)` where `claimable`
    ///      is the stored bucket plus any uncheckpointed accrual implied by the global
    ///      reward index. Safe to call with `user == address(0)` (returns zeros + zero paid).
    function _computeShareholderState(address user)
        internal
        view
        returns (uint256 claimable, uint256 userVe, uint256 paid)
    {
        claimable = _claimableEthStored[user];
        userVe = ve.veBalanceOf(user);
        paid = userEthPerVePaid[user];

        if (user == address(0) || ethPerVe == paid) return (claimable, userVe, paid);

        (
            uint256 additional,
            /* nextRemainder */, /* minNonAutoMaxLockEnd */
        ) = _computePendingAccrual(
            user, paid, userTimeWeightedEthPerVePaid[user], uint256(userLastRewardTs[user]), userRewardRemainder[user]
        );
        // Mirror the `checkpointUser` clamp so the live preview reflects what a fresh
        // checkpoint would actually credit (combined-floor over many flushes can
        // otherwise exceed the available indexed pool). The clamp is per-user, not
        // multi-user-race-aware: if multiple shareholders have uncheckpointed accrual,
        // the first to call `checkpointUser` consumes the indexed pool and the others
        // see a smaller preview on the next view call. Matches the on-chain race
        // semantic — "what would I get if I checkpoint right now and nobody else has".
        if (additional > indexedEthOwed) additional = indexedEthOwed;
        claimable += additional;
    }
}
