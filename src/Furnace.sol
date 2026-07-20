// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Constants} from "./lib/Constants.sol";
import {IClaimToken} from "./interfaces/IClaimToken.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IVeClaimNFTLockStartView} from "./interfaces/IVeClaimNFTLockStartView.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";
import {IFurnace} from "./interfaces/IFurnace.sol";
import {IFurnaceQuoter} from "./interfaces/IFurnaceQuoter.sol";
import {ILpStakingVault7D} from "./interfaces/ILpStakingVault7D.sol";

import {IDelegationHub} from "./interfaces/IDelegationHub.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "./lib/DelegationActionTypes.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {IFurnaceDripLens} from "./interfaces/IFurnaceDripLens.sol";
import {FurnaceGuardHelper} from "./FurnaceGuardHelper.sol";
import {FurnaceExtendHelper} from "./FurnaceExtendHelper.sol";
import {UpgradeableProtocolBase} from "./lib/UpgradeableProtocolBase.sol";

/// @notice Unified entry + bonus engine. All ETH→CLAIM+lock flows enforce minVeOut.
/// @dev Entry routing + bonus model + drip engine are implemented.
///
///      SLIPPAGE MODEL: Swap-backed entry paths (`enterWithEth`, `enterWithToken`) pass
///      `amountOutMin = 0` to the DEX router. Slippage protection is enforced atomically
///      downstream via the caller-supplied `minVeOut` parameter. KEEPERS MUST use private
///      mempools (e.g. Flashbots Protect on Base) for all entry transactions. If `minVeOut` is not met,
///      the entire transaction (including the swap) reverts. Callers MUST always supply a
///      sane `minVeOut` value derived from a recent FurnaceQuoter quote.
///
///      DELEGATECALL: Bonus AMM event emission is delegated to FurnaceGuardHelper via
///      delegatecall to keep Furnace runtime bytecode under EIP-170 limits. The target
///      function (emitBonusPaid) MUST remain stateless (events only).
///
///      TOKEN SAFETY: Only standard ERC20 tokens allowlisted in EntryTokenRegistry are
///      supported. Non-WETH token entry requires an exact `amountIn` receipt on the initial
///      transfer into Furnace; fee-on-transfer, rebasing, and other balance-mutating tokens
///      therefore revert before swap execution.
contract Furnace is UpgradeableProtocolBase, IERC721Receiver, IFurnace, IFurnaceDripLens {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a slippage-bounded entry settles within 2.00% (200 bps) of the
    ///         user-supplied `minVeOut`. Both `user` and `tokenIdUsed` are indexed so MEV /
    ///         keeper observability tooling can filter directly per-user or per-lock without
    ///         fanning out to every entry call.
    /// @dev `tokenIdUsed` is the second indexed topic. ABI consumers should be generated
    ///      against this canonical signature (see consumer artifacts in `abis/` and the
    ///      Dune integration pack).
    event NearSlippageLimitEntry(
        address indexed user, uint256 indexed tokenIdUsed, uint256 minVeOut, uint256 actualVeOut, uint256 marginBps
    );

    // Minimal interfaces

    // Immutable wiring

    IClaimToken public immutable claim;
    IVeClaimNFT public immutable ve;

    /// @dev Used as the "launch" anchor when MineCore is not wired or not a contract.
    uint256 public deploymentTime;

    /// @dev Self-deployed externalized guard helper used to keep Furnace runtime bytecode under EIP-170.
    ///      The helper authorizes callers against the canonical CLAIM/ve roots so it remains proxy-safe
    ///      without storing the live proxy address in Furnace state.
    address payable internal immutable _guardHelper;

    /// @dev Externalized `extendWithBonus` execution body. The two extend externals are pure
    ///      msg.data-forwarding delegatecall shims into this helper (mirroring the merge path),
    ///      which keeps the Furnace runtime under EIP-170 while the bonus-basis logic lives off-core.
    ///      Canonical-bound to the same CLAIM/ve roots as `_guardHelper`.
    address payable internal immutable _extendHelper;

    // Wiring (onlyOwner, upgradable via timelock)

    address public shareholderRoyalties; // authorized caller of lockEthReward; also allowed ETH sender in receive()
    address public mineCore;
    address public mineMarket;

    /// @notice LP rewards vault address (LpStakingVault7D).
    /// @dev If set to address(0), the LP rewards split + overflow drip are disabled.
    address public lpRewardsVault;

    /// @dev Seller observed when the canonically wired MineMarket transfers a lock into Furnace custody
    ///      via `safeTransferFrom(...)` for sellback. `sellLockToFurnaceFromMarket(...)` must bind the
    ///      payout recipient to this observed owner instead of trusting a caller-supplied `seller` blindly.
    mapping(uint256 => address) internal pendingSellSeller;

    // Canonical external allowlist + routing config (EntryTokenRegistry)
    address public entryTokenRegistry;

    /// @notice Canonical Furnace quoter / math helper (FurnaceQuoter).
    /// @dev Used both by external quote paths and by live bonus math inside Furnace.
    address public furnaceQuoter;

    // Freeze (one-way config lock for core game-rule wiring)
    bool public configFrozen;

    // Pause / config
    address public guardian; // locking-pause surface + emergency self-rotation
    bool public lockingPaused;

    /// @notice Optional DelegationHub for session-based bot permissions.
    /// @dev When unset, delegated entrypoints revert.
    address public delegationHub;

    // Bonus + drip accounting

    /// @notice R: CLAIM inventory reserved for bonuses + LP rewards.
    uint256 public furnaceReserve;

    /// @notice V: virtual depth (CLAIM units).
    uint256 public bonusVirtualDepth;

    /// @notice Timestamp of last virtual depth update.
    uint256 public lastBonusUpdate;

    // Sell impact (burst protection)

    /// @notice Cumulative sell volume over the impact window (decays linearly).
    uint256 public sellImpactVolume;

    /// @notice Timestamp of last sell impact update.
    uint256 public lastSellImpactUpdate;

    /// @notice Timestamp of last LP overflow drip accrual.
    uint256 public lastLpOverflowDripUpdate;

    /// @notice LP rewards stream rate (CLAIM/sec).
    /// @dev Funded by: (1) Furnace LP split, (2) overflow drip, (3) sellback LP share.
    uint256 internal lpStreamRatePerSec;

    /// @notice LP rewards stream period end timestamp.
    uint256 internal lpStreamPeriodFinish;

    /// @notice LP rewards stream last accrual timestamp.
    uint256 internal lpStreamLastUpdate;

    /// @dev Unscheduled LP stream dust carried across re-fundings so rounded-down wei are never stranded.
    uint256 internal lpStreamCarry;

    /// @notice Timestamp after which an emergency vault rewire can be executed (0 = none pending).
    uint256 public emergencyVaultRewireExecuteAfter;

    /// @notice Replacement LP vault locked in for the pending emergency rewire (0 = none pending).
    address public emergencyVaultRewireTargetVault;

    uint256 internal constant EMERGENCY_VAULT_REWIRE_DELAY = 7 days;

    // LP sellback cap (volume-driven LP funding)

    /// @notice Day index (floor(timestamp / 1 days)) for `lpSaleFundedToday`.
    uint256 internal lpSaleFundedDay;

    /// @notice Total CLAIM wei funded to LP stream from sellbacks today (capped).
    uint256 internal lpSaleFundedToday;

    // Modifiers

    modifier whenNotFrozen() {
        if (configFrozen) revert Errors.ConfigFrozen();
        _;
    }

    modifier onlyShareholderRoyalties() {
        FurnaceGuardHelper(_guardHelper)
            .requireOnlyShareholderRoyalties(address(this), address(ve), shareholderRoyalties, mineCore, msg.sender);
        _;
    }

    modifier onlyMineCore() {
        if (msg.sender != mineCore) revert Errors.OnlyMineCore();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Errors.OnlyGuardian();
        _;
    }

    modifier whenLockingEnabled() {
        _whenLockingEnabled();
        _;
    }

    function _whenLockingEnabled() internal view {
        if (lockingPaused) revert Errors.LockingPaused();
    }

    function _requireLpRewardsVaultCompatible(address vault, bool strictFurnaceError) internal view {
        // The LP vault indexes reward deltas against its own immutable CLAIM token and validates
        // destination locks against its own immutable ve root. If those roots differ from the
        // Furnace's canonical roots, streamed CLAIM can be stranded in the vault or lock/compound
        // surfaces can validate against the wrong ve tree.
        FurnaceGuardHelper(_guardHelper)
            .requireLpRewardsVaultCompatible(address(this), address(claim), address(ve), vault, strictFurnaceError);
    }

    function _requireCanonicalMineMarketEntryCaller() internal view {
        FurnaceGuardHelper(_guardHelper)
            .requireCanonicalMineMarketEntryCaller(
                address(this), address(claim), address(ve), shareholderRoyalties, mineCore, mineMarket, msg.sender
            );
    }

    /// @dev EIP-7702 designator detection. The designator is the only on-chain
    ///      code shape that compiles to exactly 23 bytes — EIP-3541 prevents any
    ///      new contract from being deployed with bytecode whose first byte is
    ///      `0xEF`, and pre-3541 contracts pre-date 7702 and have no path to
    ///      land at this length on Base. Bare EOAs (`code.length == 0`) and
    ///      normal contracts pass through unchanged. The check is inlined at
    ///      every call site (constructor immutable roots + runtime owner /
    ///      guardian seats) to keep Furnace under EIP-170 — pulling the helper
    ///      body into runtime would tip the impl past 24 KiB.
    constructor(address _claim, address _ve, address _helper, address initialOwner) {
        if (_claim == address(0) || _ve == address(0) || _helper == address(0)) revert Errors.ZeroAddress();
        if (_claim.code.length == 0 || _ve.code.length == 0 || _helper.code.length == 0) {
            revert Errors.NotAContract();
        }
        if (_claim.code.length == 23 || _ve.code.length == 23 || _helper.code.length == 23) {
            revert Errors.DelegatedEOA();
        }
        claim = IClaimToken(_claim);
        ve = IVeClaimNFT(_ve);
        _guardHelper = payable(_helper);
        // Self-deploy the extend-body helper, canonical-bound to the same CLAIM/ve roots and this
        // Furnace's guard helper. Embedded here (rather than pre-deployed like the guard helper)
        // because its creation code is small enough to stay well under the EIP-3860 initcode
        // ceiling, and self-deployment keeps the Furnace constructor signature stable.
        _extendHelper = payable(address(new FurnaceExtendHelper(_claim, _ve, _helper)));

        if (initialOwner != address(0)) {
            if (initialOwner.code.length == 23) revert Errors.DelegatedEOA();
            __UpgradeableProtocolBase_init(initialOwner);

            uint256 ts = block.timestamp;
            deploymentTime = ts;
            guardian = initialOwner;
            lastBonusUpdate = ts;
            lastSellImpactUpdate = ts;
            lastLpOverflowDripUpdate = ts;
            lpStreamLastUpdate = ts;
            lpSaleFundedDay = ts / 1 days;
        }
        _disableInitializers();
    }

    /// @notice The self-deployed `FurnaceExtendHelper` that holds the `extendWithBonus` body.
    /// @dev Exposed for deploy-time verification and manifest recording; the address is fixed at
    ///      Furnace-impl construction and immutable thereafter.
    function extendHelper() external view returns (address) {
        return _extendHelper;
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert Errors.ZeroAddress();
        // EIP-7702 rejection at this proxy seat is provided by two
        // independent layers, both of which run before any owner-only
        // surface here is callable: (a) `FurnaceProxy._validatedOwner` in
        // `lib/RuntimeProxyWrappers.sol` validates the proxy admin owner at
        // construction; (b) the constructor seat above carries the same
        // rejection on the impl-direct (non-proxied) deploy path. The
        // shared `transferOwnership` rejection is overridden out of the
        // Furnace runtime (see `_validateNewOwner` below) — Furnace is the
        // only contract that lives within ~25 bytes of the EIP-170 limit,
        // so the protection is concentrated at the proxy admin seat and the
        // deploy-time owner-Safe pinning.
        __UpgradeableProtocolBase_init(initialOwner);

        uint256 ts = block.timestamp;
        deploymentTime = ts;
        guardian = initialOwner;
        lastBonusUpdate = ts;
        lastSellImpactUpdate = ts;
        lastLpOverflowDripUpdate = ts;
        lpStreamLastUpdate = ts;
        lpSaleFundedDay = ts / 1 days;
    }

    /// @dev EIP-170 budget escape: Furnace is the only impl that lives within
    ///      ~25 bytes of the runtime limit, so the shared 7702-rejection check
    ///      in `UpgradeableProtocolBase.transferOwnership` is dropped here.
    ///      The owner role is still defended by:
    ///        - `FurnaceProxy._validatedOwner` (proxy admin owner at deploy);
    ///        - the constructor seat above (impl-direct deploy);
    ///        - operator deploy script discipline pinning the owner Safe; and
    ///        - the wiring guard pinning `guardian == mineCore` post-wiring.
    ///      Bare EOAs (`code.length == 0`) and normal contracts are unaffected.
    function _validateNewOwner(address) internal view virtual override {
        // Intentional no-op; see contract NatSpec on the override above.
    }

    /// @notice Accept native ETH only from known protocol senders.
    /// @dev Restricts to WETH (unwrap in _swapTokenToClaim) and
    ///      ShareholderRoyalties (lockEthReward msg.value forwarding path).
    ///      Prevents accidental, unrecoverable ETH deposits from arbitrary senders.
    receive() external payable {
        FurnaceGuardHelper(_guardHelper).validateReceiveEth(entryTokenRegistry, shareholderRoyalties, msg.sender);
    }

    // ERC721 Receiver

    /// @notice Accept veCLAIM transfers from MarketRouter (MineMarket) only.
    /// @dev VeClaimNFT uses `safeTransferFrom`, which requires this hook on contract recipients.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        FurnaceGuardHelper(_guardHelper)
            .validateSellLockReceive(
                address(this),
                address(claim),
                address(ve),
                shareholderRoyalties,
                mineCore,
                mineMarket,
                msg.sender,
                operator,
                from,
                tokenId,
                lockingPaused
            );

        pendingSellSeller[tokenId] = from;
        return IERC721Receiver.onERC721Received.selector;
    }

    // Wiring (onlyOwner, upgradable via timelock)

    function renounceOwnership() external pure {
        revert Errors.NotAuthorized();
    }

    function setShareholderRoyalties(address _sr) external onlyOwner whenNotFrozen {
        FurnaceGuardHelper(_guardHelper).validateShareholderRoyaltiesSetter(address(this), _sr);
        address oldSR = shareholderRoyalties;
        shareholderRoyalties = _sr;
        emit Events.ShareholderRoyaltiesChanged(oldSR, _sr);
    }

    function setMineCore(address _mineCore) external onlyOwner whenNotFrozen {
        FurnaceGuardHelper(_guardHelper).validateMineCoreSetter(address(this), _mineCore);
        address oldMineCore = mineCore;
        address oldGuardian = guardian;

        if (oldMineCore != _mineCore) {
            // Fail closed if any LP stream liability is outstanding. The setter is `onlyOwner`
            // and intentionally NOT `nonReentrant`, so it must not reach the
            // `_accrueLpOverflowDrip()` delegatecall path (which executes
            // `FurnaceGuardHelper.emitLpOverflowDripPaid` in Furnace's storage context).
            // Operators must call `tick()` (or wait for any user path that calls
            // `_accrueLpOverflowDrip`) to settle pending drip first, then call `setMineCore`
            // once the stream liability is zero. This matches the pattern in `setLpRewardsVault`.
            if (_lpRewardsVaultLiability() != 0) revert Errors.LpRewardsStreamActive();

            lastLpOverflowDripUpdate = block.timestamp;

            // Reset sell impact state to prevent stale spread carry-over from prior wiring.
            sellImpactVolume = 0;
            lastSellImpactUpdate = block.timestamp;
        }

        mineCore = _mineCore;
        emit Events.MineCoreChanged(oldMineCore, _mineCore);

        // Atomically update guardian to match the new mineCore.
        if (guardian != _mineCore) {
            guardian = _mineCore;
            emit Events.GuardianChanged(oldGuardian, _mineCore);
        }
    }

    function setMineMarket(address _mineMarket) external onlyOwner whenNotFrozen {
        FurnaceGuardHelper(_guardHelper).validateMineMarketSetter(_mineMarket);
        address oldMineMarket = mineMarket;
        mineMarket = _mineMarket;
        emit Events.MineMarketChanged(oldMineMarket, _mineMarket);
    }

    /// @notice Permanently lock core game-rule wiring and bonus-routing surfaces
    ///         (shareholderRoyalties, mineCore, mineMarket, furnaceQuoter, lpRewardsVault).
    /// @dev After freeze, only operational peripherals (delegationHub, entryTokenRegistry, guardian)
    ///      and the delayed emergency LP vault rewire flow remain owner-configurable.
    function freezeConfig() external onlyOwner whenNotFrozen {
        FurnaceGuardHelper(_guardHelper)
            .validateFreezeConfig(
                address(this),
                address(claim),
                address(ve),
                shareholderRoyalties,
                mineCore,
                mineMarket,
                furnaceQuoter,
                lpRewardsVault,
                guardian
            );

        configFrozen = true;
        emit Events.ConfigFrozen();
    }

    /// @notice Owner-rotates the canonical DelegationHub for keeper-bot infrastructure.
    /// @dev Intentionally remains owner-mutable AFTER `freezeConfig()` because the hub is an
    ///      operational peripheral (NatSpec at `freezeConfig`), not a core game-rule wiring
    ///      surface. Freezing it would block legitimate post-freeze hub rotations during
    ///      coordinated MineCore upgrades.
    ///
    ///      Setter-time wiring check: the candidate hub MUST already be the
    ///      canonical hub for this Furnace's MineCore. Without this gate a mis-wired hub
    ///      silently DoSes every delegated entry until an operator notices, because runtime
    ///      `_requireDelegated` reverts `WiringMismatch` per call. `_requireDelegated`
    ///      already prevents fund loss; this gate closes the operational-hygiene gap.
    ///
    ///      Freeze asymmetry vs `MineCore.setDelegationHub` (which IS `whenNotFrozen`): the
    ///      authoritative hub identity lives on `MineCore`. After `MineCore.freezeConfig()`
    ///      the canonical hub is permanent there, and the wiring check on this Furnace
    ///      setter requires the candidate to equal `mineCore.delegationHub()`. This means
    ///      Furnace cannot drift to a hub that MineCore has not also approved — the freedom
    ///      to mutate post-freeze on Furnace is functionally bounded by MineCore's frozen
    ///      hub. Combined with the runtime `_requireDelegated` cross-validation on every
    ///      authenticated call, a malicious or accidental rebind on the Furnace side
    ///      cannot escalate authority. Hence: owner-mutable post-freeze on Furnace,
    ///      frozen on MineCore — by design, not by oversight.
    function setDelegationHub(address _delegationHub) external onlyOwner {
        if (_delegationHub == address(0)) revert Errors.ZeroAddress();
        if (_delegationHub.code.length == 0) revert Errors.NotAContract();
        FurnaceGuardHelper(_guardHelper)
            .requireCanonicalDelegationHub(address(this), address(claim), address(ve), _delegationHub, mineCore);
        address old = delegationHub;
        delegationHub = _delegationHub;
        emit Events.DelegationHubChanged(old, _delegationHub);
    }

    /// @notice Owner-rotates the EntryTokenRegistry pointer used by token-entry routing.
    /// @dev Intentionally remains owner-mutable AFTER `freezeConfig()` for the same reason
    ///      as `setDelegationHub`: the registry is an operational peripheral, not a core
    ///      game-rule wiring surface, and a coordinated MineCore upgrade may need to
    ///      re-point Furnace at a freshly-deployed registry without redeploying Furnace.
    ///
    ///      Setter-time wiring check: `validateDistinctEntryTokenRegistry` requires the
    ///      candidate registry to NOT equal `mineCore` itself (catches an obvious
    ///      misconfiguration). Authority is functionally bounded by `mineCore` — which is
    ///      frozen at `freezeConfig` — because the registry only consumes entry-token
    ///      routes and cannot mint, transfer, or rebind protocol-critical state.
    function setEntryTokenRegistry(address _registry) external onlyOwner {
        FurnaceGuardHelper(_guardHelper).validateDistinctEntryTokenRegistry(mineCore, _registry);

        entryTokenRegistry = _registry;
        emit Events.EntryTokenRegistrySet(_registry);
    }

    /// @notice Sets the canonical FurnaceQuoter used by both quote helpers and live bonus math.
    function setFurnaceQuoter(address _quoter) external onlyOwner whenNotFrozen {
        FurnaceGuardHelper(_guardHelper).requireFurnaceQuoterCompatible(address(this), _quoter);

        address old = furnaceQuoter;
        furnaceQuoter = _quoter;
        emit Events.FurnaceQuoterSet(old, _quoter);
    }

    /// @notice Set the LP rewards vault.
    /// @dev address(0) disables the LP rewards split + overflow drip.
    ///      Safety: already-earned LP value MUST keep flowing to the same vault.
    ///      Rewiring while any parked LP liability exists can redirect or strand rewards
    ///      that were funded/accrued for the prior vault's LP stakers.
    function setLpRewardsVault(address _lpRewardsVault) external onlyOwner whenNotFrozen nonReentrant {
        address oldVault = lpRewardsVault;

        // address(0) disables LP routing and drip; non-zero MUST be a valid vault contract.
        if (_lpRewardsVault != address(0)) {
            if (_lpRewardsVault.code.length == 0) revert Errors.NotAContract();

            _requireLpRewardsVaultCompatible(_lpRewardsVault, true);
        }

        // Changing the destination while any already-earned LP rewards remain attributable to the
        // current vault would redirect or strand value. This includes both:
        // - parked/funded stream liability sitting in Furnace balance, and
        // - overflow-drip rewards that have already accrued for the current vault period but have
        //   not yet been checkpointed into the stream.
        if (oldVault != _lpRewardsVault) {
            // Accrue overflow drip before checking liability to avoid double-counting
            // pending drip that would become stream liability after accrual.
            _accrueLpOverflowDrip();

            _settleMaturedLpCarry(oldVault);

            if (_lpRewardsVaultLiability() != 0) revert Errors.LpRewardsStreamActive();

            // Bind future overflow-drip accrual to the new vault period only.
            // Without this cursor reset, time spent with LP routing disabled (vault == 0) or under
            // a prior vault can retroactively drip into the newly configured vault on the next tick.
            lastLpOverflowDripUpdate = block.timestamp;
        }

        lpRewardsVault = _lpRewardsVault;
        emit Events.LpRewardsVaultSet(oldVault, _lpRewardsVault);
    }

    /// @notice Initiate an emergency LP vault rewire to a precommitted replacement vault.
    /// @dev This delayed path remains available even after `freezeConfig()` so governance can
    ///      recover from a broken LP vault without reopening general frozen config surfaces.
    ///      The request stores the exact replacement vault up front so the 7-day delay applies
    ///      to the actual destination, not just to the requested rewire action.
    ///
    ///      Body lives in `FurnaceGuardHelper.requestEmergencyVaultRewireDelegated` to keep
    ///      Furnace under EIP-170. The shim below preserves `onlyOwner` and bubbles the
    ///      original revert payload (e.g. `EmergencyRewireAlreadyRequested`) intact.
    function requestEmergencyVaultRewire(address) external onlyOwner {
        _delegateMsgDataToHelper();
    }

    /// @notice Cancel a pending emergency vault rewire request.
    /// @dev Body lives in `FurnaceGuardHelper.cancelEmergencyVaultRewire` (matching selector).
    function cancelEmergencyVaultRewire() external onlyOwner {
        _delegateMsgDataToHelper();
    }

    /// @notice Execute the emergency vault rewire after the delay has elapsed.
    ///         Zeros out stranded LP stream state and atomically rebinds the LP vault.
    /// @dev Body lives in `FurnaceGuardHelper.executeEmergencyVaultRewire` (matching selector).
    function executeEmergencyVaultRewire() external onlyOwner {
        _delegateMsgDataToHelper();
    }

    /// @notice Rescue a veNFT stuck in pending-sell state.
    /// @dev If `onERC721Received` accepted a veNFT but `sellLockToFurnaceFromMarket` was never
    ///      invoked for it, the NFT is orphaned. This function burns the lock and returns the
    ///      underlying CLAIM to the original seller.
    ///      VeClaimNFT restricts `safeTransferFrom` to the canonical market path, so the NFT
    ///      cannot be returned as-is; burning is the only recovery mechanism.
    ///
    ///      Body lives in `FurnaceGuardHelper.rescuePendingSellNFT` (matching selector). The
    ///      shim preserves `onlyOwner` + `nonReentrant` and forwards `msg.data` verbatim.
    function rescuePendingSellNFT(uint256) external onlyOwner nonReentrant {
        _delegateMsgDataToHelper();
    }

    /// @dev Shared msg.data-forwarding delegatecall trampoline for the four emergency /
    ///      rescue paths. Avoids the ~600-byte abi.encodeCall expansion (load-bearing for
    ///      EIP-170 headroom). Bubbles the inner revert payload verbatim so test suites and
    ///      operators see the original typed error (`EmergencyRewireAlreadyRequested`,
    ///      `LpRewardsStreamActive`, …) rather than a generic `InvariantViolation` wrapper.
    ///      Returns control to Solidity so caller modifiers (`nonReentrant`) can release
    ///      their lock; we deliberately do NOT use `return(...)` in assembly.
    function _delegateMsgDataToHelper() private {
        address helper = _guardHelper;
        // nosemgrep: sol-arbitrary-delegatecall
        // slither-disable-next-line controlled-delegatecall,low-level-calls
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), helper, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
        }
    }

    function setGuardian(address _guardian) external {
        if (msg.sender != owner() && msg.sender != guardian) revert Errors.NotAuthorized();
        if (_guardian == address(0)) revert Errors.ZeroAddress();
        if (_guardian == address(this)) revert Errors.NotAuthorized();

        // Canonical single pause surface: Furnace.guardian MUST be MineCore so that
        // MineCore.setLockingPaused() is the only locking pause control path.
        // The wiring guard pins `_guardian == mineCore` once MineCore is wired,
        // and `MineCore` is a contract — never a 7702 designator. The brief
        // pre-wiring window is closed operationally by the deployment script,
        // which atomically wires `mineCore` immediately after Furnace deploy
        // (see `scripts/deploy_prod.mjs::DEPLOY_SCRIPT_CREATE_ORDER`).
        if (mineCore != address(0) && _guardian != mineCore) revert Errors.WiringMismatch();

        address oldGuardian = guardian;
        guardian = _guardian;
        emit Events.GuardianChanged(oldGuardian, _guardian);
    }

    function setLockingPaused(bool paused) external onlyGuardian {
        if (paused == lockingPaused) return;
        lockingPaused = paused;
        emit Events.LockingPausedChanged(paused);
    }

    /// @notice Credits CLAIM minted to Furnace by MineCore into reserve accounting.
    /// @dev MineCore MUST call this immediately after minting the Furnace emission stream to this contract.
    function creditReserve(uint256 amount) external nonReentrant onlyMineCore {
        // Accrue drip first so newly credited reserve is not used for the past.
        _accrueLpOverflowDrip();

        if (amount == 0) return;
        furnaceReserve += amount;
        // bonusVirtualDepth is not recalculated here. The depth will self-correct
        // toward the new reserve-derived target on the next entry via the 3-hour decay interpolation.
        _syncFurnaceReserve();
        emit Events.ReserveCredited(amount, furnaceReserve);
    }

    /// @dev Enforces `furnaceReserve <= CLAIM.balanceOf(this) - lpStreamLiability` by clamping
    ///      the accounting value down if it ever drifts above the contract's actual available balance.
    ///
    ///      This hardens the system against:
    ///      - MineCore mis-crediting `creditReserve(amount)`
    ///      - accidental token transfers out of the Furnace without updating `furnaceReserve`
    function _syncFurnaceReserve() internal {
        (uint256 cap, uint256 bal, uint256 liability) = FurnaceGuardHelper(_guardHelper)
            .reserveSyncState(
                address(claim),
                address(this),
                lpStreamCarry,
                lpStreamPeriodFinish,
                lpStreamRatePerSec,
                lpStreamLastUpdate
            );

        uint256 old = furnaceReserve;
        if (old > cap) {
            furnaceReserve = cap;
            emit Events.ReserveClamped(msg.sender, old, cap, bal, liability);
        }
    }

    // Entry paths (SPEC v1.0.0)

    uint8 internal constant MODE_ENTER_WITH_ETH = 0;
    uint8 internal constant MODE_ENTER_WITH_CLAIM = 1;
    uint8 internal constant MODE_LOCK_FURNACE = 2;
    uint8 internal constant MODE_ENTER_WITH_TOKEN = 3;

    /// @notice Enter with native ETH: swap ETH → CLAIM, apply bonus, lock as veCLAIM.
    /// @param minVeOut Minimum veCLAIM output; reverts if not met. MUST be > 0 for sandwich protection.
    ///        UIs should derive this from a FurnaceQuoter quote with a slippage buffer.
    function enterWithEth(uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
        external
        payable
        nonReentrant
        whenLockingEnabled
        returns (uint256 tokenIdUsed)
    {
        uint256 ethIn = msg.value;
        if (ethIn == 0) revert Errors.AmountZero();

        uint256 principalClaim = _swapEthToClaim(ethIn);

        tokenIdUsed = _enterAfterPrincipal(
            msg.sender,
            MODE_ENTER_WITH_ETH,
            ethIn,
            principalClaim,
            targetTokenId,
            durationSeconds,
            createAutoMax,
            minVeOut
        );
    }

    function enterWithClaim(
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant whenLockingEnabled returns (uint256 tokenIdUsed) {
        if (claimAmount == 0) revert Errors.AmountZero();

        // Ensure registry is wired + router config is set (spec precondition).
        _requireRegistryAndRouterConfig();
        _pullClaimFromSender(claimAmount);

        tokenIdUsed = _enterAfterPrincipal(
            msg.sender, MODE_ENTER_WITH_CLAIM, 0, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );
    }

    function enterWithClaimFor(
        address user,
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant whenLockingEnabled returns (uint256 tokenIdUsed) {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (claimAmount == 0) revert Errors.AmountZero();

        // Allowlisted callers: MarketRouter + LpStakingVault7D + MineCore (spec §7.2).
        address vault = lpRewardsVault;
        if (msg.sender == mineMarket) {
            _requireCanonicalMineMarketEntryCaller();
        } else if (msg.sender == vault) {
            _requireLpRewardsVaultCompatible(vault, false);
        } else if (msg.sender == mineCore) {
            FurnaceGuardHelper(_guardHelper)
                .requireCanonicalMineCoreEntryCaller(address(this), address(claim), address(ve), mineCore, msg.sender);
        } else {
            revert Errors.NotAuthorized();
        }

        _requireRegistryAndRouterConfig();
        _pullClaimFromSender(claimAmount);

        tokenIdUsed = _enterAfterPrincipal(
            user, MODE_ENTER_WITH_CLAIM, 0, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );
    }

    /// @notice Enter with an ERC20 token: swap token → CLAIM (1- or 2-hop), apply bonus, lock as veCLAIM.
    /// @param minVeOut Minimum veCLAIM output; reverts if not met. MUST be > 0 for sandwich protection.
    ///        UIs should derive this from a FurnaceQuoter quote with a slippage buffer.
    function enterWithToken(
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant whenLockingEnabled returns (uint256 tokenIdUsed) {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (amountIn == 0) revert Errors.AmountZero();
        if (tokenIn == address(claim)) revert Errors.InvalidToken();

        uint256 actualReceived = _receiveEntryToken(tokenIn, msg.sender, amountIn);
        uint256 principalClaim = _swapTokenToClaim(tokenIn, actualReceived);

        tokenIdUsed = _enterAfterPrincipal(
            msg.sender,
            MODE_ENTER_WITH_TOKEN,
            0,
            principalClaim,
            targetTokenId,
            durationSeconds,
            createAutoMax,
            minVeOut
        );
    }

    // Delegated entry (bot pays, user receives the veCLAIM lock)

    function enterWithEthFor(
        address user,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external payable nonReentrant whenLockingEnabled returns (uint256 tokenIdUsed) {
        if (user == address(0)) revert Errors.ZeroAddress();
        _requireDelegated(user, DelegationPermissions.P_FURNACE_ENTER_ETH_FOR);

        uint256 ethIn = msg.value;
        if (ethIn == 0) revert Errors.AmountZero();

        uint256 principalClaim = _swapEthToClaim(ethIn);

        tokenIdUsed = _enterAfterPrincipal(
            user, MODE_ENTER_WITH_ETH, ethIn, principalClaim, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );

        _emitDelegationSession(
            user,
            DelegationActionTypes.FURNACE_ENTER_WITH_ETH_FOR,
            DelegationPermissions.P_FURNACE_ENTER_ETH_FOR,
            tokenIdUsed
        );
    }

    /// @notice Delegated CLAIM entry: caller provides CLAIM, `user` receives the ve lock.
    function enterWithClaimFromCallerFor(
        address user,
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant whenLockingEnabled returns (uint256 tokenIdUsed) {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (claimAmount == 0) revert Errors.AmountZero();
        _requireDelegated(user, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);

        _requireRegistryAndRouterConfig();
        _pullClaimFromSender(claimAmount);

        tokenIdUsed = _enterAfterPrincipal(
            user, MODE_ENTER_WITH_CLAIM, 0, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );

        _emitDelegationSession(
            user,
            DelegationActionTypes.FURNACE_ENTER_WITH_CLAIM_FOR,
            DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR,
            tokenIdUsed
        );
    }

    /// @notice Delegated token entry: caller provides `tokenIn`, `user` receives the ve lock.
    function enterWithTokenFromCallerFor(
        address user,
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant whenLockingEnabled returns (uint256 tokenIdUsed) {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (amountIn == 0) revert Errors.AmountZero();
        if (tokenIn == address(claim)) revert Errors.InvalidToken();
        _requireDelegated(user, DelegationPermissions.P_FURNACE_ENTER_TOKEN_FOR);

        uint256 actualReceived = _receiveEntryToken(tokenIn, msg.sender, amountIn);
        uint256 principalClaim = _swapTokenToClaim(tokenIn, actualReceived);

        tokenIdUsed = _enterAfterPrincipal(
            user, MODE_ENTER_WITH_TOKEN, 0, principalClaim, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );

        _emitDelegationSession(
            user,
            DelegationActionTypes.FURNACE_ENTER_WITH_TOKEN_FOR,
            DelegationPermissions.P_FURNACE_ENTER_TOKEN_FOR,
            tokenIdUsed
        );
    }

    function lockEthReward(
        address user,
        uint256 ethAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external payable nonReentrant onlyShareholderRoyalties whenLockingEnabled {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (ethAmount == 0) revert Errors.AmountZero();
        // Harden against accidental mismatches: `ethAmount` must match `msg.value`.
        if (msg.value != ethAmount) revert Errors.EthValueMismatch();

        uint256 principalClaim = _swapEthToClaim(ethAmount);

        _enterAfterPrincipal(
            user, MODE_LOCK_FURNACE, ethAmount, principalClaim, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );
    }

    // Sellback (lock → liquid CLAIM)

    /// @notice Sell a lock to the Furnace via MarketRouter, using MarketRouter as the NFT operator.
    /// @dev This path exists to enable single-tx Market Sell routing from MarketRouter.
    ///      Preconditions:
    ///      - msg.sender MUST be the canonically wired MineMarket (MarketRouter) bundle
    ///      - MarketRouter MUST have already checkpointed `seller` in ShareholderRoyalties
    ///      - `tokenId` MUST already be owned by this Furnace (MarketRouter transfers it first)
    ///      - ve-listed flag MUST be false (MarketRouter clears it before transfer)
    function sellLockToFurnaceFromMarket(address seller, uint256 tokenId, uint256 minClaimOut)
        external
        nonReentrant
        whenLockingEnabled
        returns (uint256 claimOut)
    {
        _requireCanonicalMineMarketEntryCaller();
        if (seller == address(0)) revert Errors.ZeroAddress();
        if (furnaceQuoter == address(0)) revert Errors.ZeroAddress();

        // ORDERING INVARIANT: _accrueLpOverflowDrip() MUST run before the quoter call below.
        // The quoter reads furnaceReserve; accruing first ensures the quote is computed against
        // up-to-date reserve state. The guard helper's reserveBefore == reserveNow assertion in
        // normalizeSellExecutionQuote provides a runtime safety net but does not replace correct
        // ordering here.
        _accrueLpOverflowDrip();

        // The token must already be owned by the Furnace (MarketRouter transferred it).
        if (ve.ownerOf(tokenId) != address(this)) revert Errors.NotAuthorized();

        // Bind payout to the actual owner observed during the safeTransferFrom custody handoff.
        address observedSeller = pendingSellSeller[tokenId];
        if (observedSeller == address(0) || observedSeller != seller) revert Errors.NotAuthorized();

        // Clear before external calls; any later revert restores state.
        delete pendingSellSeller[tokenId];

        // Load lock info (effective end for AutoMax).
        uint256 lockAmount;
        uint256 lockEnd;
        bool autoMax;
        bool listed;
        (lockAmount, lockEnd, autoMax, listed) = ve.getLockInfo(tokenId);
        if (lockAmount == 0) revert Errors.InvalidToken();
        if (listed) revert Errors.LockListedOrFrozen();
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();

        FurnaceGuardHelper.SellExecutionData memory q;
        uint256 cut;
        (q, cut) = FurnaceGuardHelper(_guardHelper)
            .normalizeSellExecutionQuote(
                furnaceQuoter,
                lockAmount,
                lockEnd,
                autoMax,
                minClaimOut,
                furnaceReserve,
                mineCore,
                lpSaleFundedDay,
                lpSaleFundedToday
            );

        claimOut = q.claimOut;

        // NOTE: furnaceReserve += q.reserveAdd is deferred until after the burn-and-withdraw
        // below. Incrementing here would transiently inflate furnaceReserve above the actual
        // available CLAIM balance (the lock's principal has not yet been released to this
        // contract). While nonReentrant prevents exploitation, deferring the write eliminates
        // the transient invariant violation entirely.

        // Accrue sell impact volume (pure state mutation) before any external calls.
        _accrueSellImpactVolume(lockAmount);

        if (q.lpReward != 0) {
            _trackLpSaleRewardFunding(q.lpReward);
        }

        {
            // nosemgrep: sol-arbitrary-delegatecall
            // slither-disable-next-line controlled-delegatecall
            (bool ok,) = _guardHelper.delegatecall(
                abi.encodeCall(
                    FurnaceGuardHelper.emitLockSoldToFurnace,
                    (
                        seller,
                        tokenId,
                        lockAmount,
                        claimOut,
                        q.spreadBps,
                        cut,
                        q.lpSaleShareBps,
                        q.lpReward,
                        q.reserveAdd,
                        q.bonusBpsUsed
                    )
                )
            );
            if (!ok) revert Errors.InvariantViolation();
        }

        // Burn + withdraw the underlying principal from ve to the Furnace.
        uint256 withdrawn = ve.furnaceBurnAndWithdraw(tokenId, address(this));
        if (withdrawn != lockAmount) revert Errors.InvariantViolation();

        // Credit reserve AFTER the burn so furnaceReserve never exceeds actual available balance.
        furnaceReserve += q.reserveAdd;

        delete lastAutoMaxBonusClaim[tokenId];
        delete bonusBasis[tokenId];

        if (q.lpReward != 0) {
            _fundLpStreamInternal(q.lpReward, false);
        }

        IERC20(address(claim)).safeTransfer(seller, claimOut);

        // Single trailing sync captures all balance mutations (reserve credit,
        // burn withdraw, LP stream funding, seller payout).
        _syncFurnaceReserve();
    }

    // Entry internals

    function _enterAfterPrincipal(
        address user,
        uint8 mode,
        uint256 ethIn,
        uint256 principalClaim,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) internal returns (uint256 tokenIdUsed) {
        if (principalClaim == 0) revert Errors.AmountZero();
        if (furnaceQuoter == address(0)) revert Errors.ZeroAddress();
        if (minVeOut == 0) revert Errors.MinVeOutRequired();

        (uint256 d, uint256 weight) = FurnaceGuardHelper(_guardHelper)
            .resolveEntryDurationAndWeight(address(ve), user, targetTokenId, durationSeconds, createAutoMax);
        // weight is bounded by `Constants.BPS_DENOM * Constants.WEIGHT_PRECISION` (~1e12) and
        // principalClaim is bounded by total CLAIM supply (~1e27); the product fits well inside uint256.
        uint256 principalEff = (principalClaim * weight) / Constants.WEIGHT_DENOM;

        (, uint256 userBonus,) = _applyBonusAmm(user, principalClaim, principalEff, d);

        uint256 amountLocked = principalClaim + userBonus;
        // `minVeOut` guards only ve minted from newly locked value (principal + user bonus).
        // It intentionally excludes any additional delta from extending an existing lock's prior principal.
        uint256 guardedVeOut;
        (guardedVeOut, tokenIdUsed) = _lockToDestination(user, amountLocked, targetTokenId, d, createAutoMax);

        // Track user-supplied principal only (never `userBonus`) so the extend bonus basis reflects
        // real capital committed, not Furnace-paid bonuses already folded into the lock.
        bonusBasis[tokenIdUsed] += principalClaim;

        if (guardedVeOut < minVeOut) revert Errors.MinVeOutNotMet();

        {
            uint256 marginBps = ((guardedVeOut - minVeOut) * Constants.BPS_DENOM) / guardedVeOut;
            if (marginBps <= 200) {
                emit NearSlippageLimitEntry(user, tokenIdUsed, minVeOut, guardedVeOut, marginBps);
            }
        }

        // Enforce reserve accounting invariant after the lock has pulled CLAIM out of the Furnace.
        _syncFurnaceReserve();

        emit Events.FurnaceEnter(user, mode, ethIn, principalClaim, userBonus, tokenIdUsed);

        return tokenIdUsed;
    }

    function _lockToDestination(
        address user,
        uint256 amountLocked,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) internal returns (uint256 veOut, uint256 tokenIdUsed) {
        if (targetTokenId == 0) {
            return _createNewLock(user, amountLocked, durationSeconds, createAutoMax);
        }

        veOut = _lockIntoExisting(user, amountLocked, targetTokenId, durationSeconds, createAutoMax);
        tokenIdUsed = targetTokenId;
    }

    function _createNewLock(address user, uint256 amountLocked, uint256 durationSeconds, bool createAutoMax)
        internal
        returns (uint256 veOut, uint256 tokenId)
    {
        veOut = FurnaceGuardHelper(_guardHelper).validateNewLock(amountLocked, durationSeconds, createAutoMax);

        // nosemgrep: sol-arbitrary-delegatecall
        // slither-disable-next-line controlled-delegatecall
        (bool ok, bytes memory ret) = _guardHelper.delegatecall(
            abi.encodeCall(
                FurnaceGuardHelper.createLockDelegated,
                (address(claim), address(ve), user, amountLocked, durationSeconds, createAutoMax)
            )
        );
        if (!ok) revert Errors.InvariantViolation();
        tokenId = abi.decode(ret, (uint256));
    }

    /// @dev Top up an existing lock.  `createAutoMax` is deliberately ignored for existing
    ///      locks: the destination's AutoMax state is preserved unchanged.  Users who want
    ///      to convert a non-AutoMax lock must call `VeClaimNFT.setAutoMax(tokenId, true)`
    ///      separately.  Duration is NOT extended — use `extendWithBonus` for that.
    ///      See developer Furnace docs §"Destination rules".
    function _lockIntoExisting(
        address user,
        uint256 amountLocked,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool /* createAutoMax */
    )
        internal
        returns (uint256 veOut)
    {
        FurnaceGuardHelper.ExistingLockResolution memory r = FurnaceGuardHelper(_guardHelper)
            .resolveExistingLockDestination(address(ve), user, targetTokenId, amountLocked, durationSeconds);

        veOut = r.veOut;

        _approveVeAndAddToLock(user, targetTokenId, amountLocked);
    }

    // Extension with bonus (SPEC extension)

    uint8 internal constant MODE_EXTEND_WITH_BONUS = 4;
    uint8 internal constant MODE_AUTOMAX_BONUS = 5;

    /// @notice Per-lock timestamp of the last AutoMax bonus claim.
    mapping(uint256 => uint256) public lastAutoMaxBonusClaim;

    /// @notice Per-lock cumulative user-supplied principal, EXCLUDING Furnace-paid bonuses.
    /// @dev The `extendWithBonus` duration-weight bonus is priced against this basis rather than the
    ///      live `Lock.amount`. `Lock.amount` grows every time a bonus is added back into the lock,
    ///      so pricing the next commitment off it would let a laddered sequence of extensions
    ///      compound the bonus multiplicatively over a single commitment. Pricing off `bonusBasis`
    ///      keeps the cumulative bonus path-independent. A value of 0 marks a lock created before
    ///      this accounting existed; the first extend that touches it seeds the basis from the live
    ///      `Lock.amount` once. MUST remain the last Furnace storage variable; append-only for proxy
    ///      layout safety. Mutated off-core by `FurnaceExtendHelper` under delegatecall.
    mapping(uint256 => uint256) public bonusBasis;

    /// @notice Extend a non-AutoMax lock's duration and receive a bonus on the existing
    ///         principal for the incremental commitment. No new capital required.
    ///         AutoMax locks must use `claimAutoMaxBonus` instead.
    /// @dev Body offloaded to `FurnaceExtendHelper.extendWithBonus(uint256,uint256,uint256)` via a
    ///      msg.data-forwarding assembly delegatecall (selectors match). `nonReentrant` +
    ///      `whenLockingEnabled` are held for the full delegatecall and the helper's callback into
    ///      `__bonusAmmFromHelper`. The bonus is priced against `bonusBasis` (see the helper).
    ///      Parameters (tokenId, durationSeconds, minBonusOut) are forwarded verbatim via msg.data.
    function extendWithBonus(
        uint256,
        /* tokenId */
        uint256,
        /* durationSeconds */
        uint256 /* minBonusOut */
    )
        external
        nonReentrant
        whenLockingEnabled
        returns (uint256 bonusClaim)
    {
        return _delegateToHelper(_extendHelper);
    }

    /// @notice Delegated extend: caller extends `user`'s lock; bonus accrues to the lock.
    /// @dev Body + delegation gate offloaded to
    ///      `FurnaceExtendHelper.extendWithBonusFor(address,uint256,uint256,uint256)` via
    ///      msg.data-forwarding delegatecall. Bonus + principal both stay with `user`.
    function extendWithBonusFor(
        address, /* user */
        uint256, /* tokenId */
        uint256, /* durationSeconds */
        uint256 /* minBonusOut */
    )
        external
        nonReentrant
        whenLockingEnabled
        returns (uint256 bonusClaim)
    {
        return _delegateToHelper(_extendHelper);
    }

    // Merge with bonus (v1.0.0 — replaces VeClaimNFT.mergeLocks{,ForUser})

    /// @notice Merge `fromTokenId` into `intoTokenId` and pay an extension-style bonus on the
    ///         duration component when the merge effectively extends the surviving lock.
    /// @dev Bonus is 0 when both inputs share the same effective remaining duration (including
    ///      both AutoMax). The surviving lock absorbs `fromAmount + intoAmount + bonusClaim`.
    ///      Body offloaded to `FurnaceExtendHelper.mergeLocksWithBonus(uint256,uint256,uint256)` via
    ///      a msg.data-forwarding assembly delegatecall. Selectors match so the helper's
    ///      dispatcher resolves automatically. `nonReentrant` + `whenLockingEnabled` are held
    ///      for the full delegatecall and the helper's callback into `__bonusAmmFromHelper`.
    ///      Parameters (fromTokenId, intoTokenId, minBonusOut) are forwarded verbatim via msg.data.
    function mergeLocksWithBonus(
        uint256,
        /* fromTokenId */
        uint256,
        /* intoTokenId */
        uint256 /* minBonusOut */
    )
        external
        nonReentrant
        whenLockingEnabled
        returns (uint256 bonusClaim)
    {
        return _delegateToHelper(_extendHelper);
    }

    /// @notice Delegated merge: caller submits, `user` is the lock owner and bonus recipient.
    /// @dev Body + delegation gate offloaded to
    ///      `FurnaceExtendHelper.mergeLocksWithBonusFor(address,uint256,uint256,uint256)`
    ///      via msg.data-forwarding delegatecall. Bonus + merged principal both stay with
    ///      `user` — the delegate cannot redirect value. Emits `DelegationSessionUsed` from
    ///      Furnace's address inside the helper body.
    function mergeLocksWithBonusFor(
        address, /* user */
        uint256, /* fromTokenId */
        uint256, /* intoTokenId */
        uint256 /* minBonusOut */
    )
        external
        nonReentrant
        whenLockingEnabled
        returns (uint256 bonusClaim)
    {
        return _delegateToHelper(_extendHelper);
    }

    /// @dev Shared msg.data-forwarding delegatecall trampoline for the merge and extend externals.
    ///      Forwards verbatim calldata to `helper` (the extend helper holds both the extend and
    ///      merge bodies; selectors match the helper bodies). Returns the helper's `uint256
    ///      bonusClaim` via returndatacopy. Bubbles inner reverts verbatim so callers see the
    ///      original typed errors.
    function _delegateToHelper(address helper) private returns (uint256 bonusClaim) {
        // nosemgrep: sol-arbitrary-delegatecall
        // slither-disable-next-line controlled-delegatecall,low-level-calls
        assembly ("memory-safe") {
            // Use the free memory pointer so Solidity can still encode the return
            // value after this block. Writing at offset 0 would clobber 0x40 (FMP)
            // and brick Solidity's epilogue with a memory-allocation OOG.
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), helper, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            bonusClaim := mload(ptr)
        }
    }

    /// @dev Auth-gated re-entry from the helper's merge body (running in delegatecall).
    ///      The helper does a regular `CALL` to `address(this).__bonusAmmFromHelper(...)`,
    ///      which arrives here with `msg.sender == address(this)`. The wrapping merge
    ///      external still owns the `nonReentrant` lock, so this callback intentionally
    ///      omits `nonReentrant` to avoid double-acquisition.
    function __bonusAmmFromHelper(address user, uint256 principalClaim, uint256 principalEff, uint256 lockDurationSec)
        external
        returns (uint256 grossBonus, uint256 userBonus, uint256 lpBonus)
    {
        if (msg.sender != address(this)) revert Errors.NotAuthorized();
        return _applyBonusAmm(user, principalClaim, principalEff, lockDurationSec);
    }

    /// @notice Claim accrued extension bonus for an AutoMax lock.
    ///         Permissionless — any address (keeper/bot) can trigger it.
    ///         24h minimum cooldown per lock.
    function claimAutoMaxBonus(uint256 tokenId) external nonReentrant whenLockingEnabled returns (uint256 bonusClaim) {
        uint256 lockAmount;
        {
            uint256 lockEnd;
            bool autoMax;
            bool listed;
            (lockAmount, lockEnd, autoMax, listed) = ve.getLockInfo(tokenId);
            if (lockAmount == 0) revert Errors.InvalidToken();
            if (!autoMax) revert Errors.InvalidDuration();
            if (listed) revert Errors.LockListedOrFrozen();
            if (lockEnd <= block.timestamp) revert Errors.LockExpired();
        }

        bonusClaim = _claimAutoMaxBonusCore(tokenId, lockAmount);
        _syncFurnaceReserve();
    }

    /// @notice Batch-claim accrued extension bonuses for multiple AutoMax locks in a single tx.
    ///         Best-effort per lock: ineligible locks are silently skipped (no revert).
    /// @param tokenIds The locks to process.
    /// @param maxLocks Hard cap on how many locks to process (gas bound).
    /// @return totalBonus Aggregate bonus CLAIM distributed across all processed locks.
    function claimAutoMaxBonusBatch(uint256[] calldata tokenIds, uint256 maxLocks)
        external
        nonReentrant
        whenLockingEnabled
        returns (uint256 totalBonus)
    {
        uint256 n = tokenIds.length;
        if (maxLocks < n) n = maxLocks;
        if (n > Constants.MAX_AUTOMAX_BONUS_BATCH) n = Constants.MAX_AUTOMAX_BONUS_BATCH;

        for (uint256 i = 0; i < n;) {
            if (i > 0 && tokenIds[i] <= tokenIds[i - 1]) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 lockAmount;
            {
                uint256 lockEnd;
                bool autoMax;
                bool listed;
                (lockAmount, lockEnd, autoMax, listed) = ve.getLockInfo(tokenIds[i]);
                if (lockAmount == 0 || !autoMax || listed || lockEnd <= block.timestamp) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
            }
            totalBonus += _claimAutoMaxBonusCore(tokenIds[i], lockAmount);
            unchecked {
                ++i;
            }
        }

        _syncFurnaceReserve();
    }

    /// @dev Core AutoMax bonus logic for a single pre-validated lock.
    ///      Returns 0 on first-touch init, when fewer than 1 day has elapsed, or when
    ///      the AMM computes `grossBonus == 0`.
    function _claimAutoMaxBonusCore(uint256 tokenId, uint256 lockAmount) internal returns (uint256 bonusClaim) {
        uint256 lastClaim = lastAutoMaxBonusClaim[tokenId];
        if (lastClaim == 0) {
            lastAutoMaxBonusClaim[tokenId] = block.timestamp;
            return 0;
        }

        // AutoMax bonus accrues only on principal that has actually been present since the current
        // mutation epoch. Top-ups, merges, or autoMax toggles refresh `lockStart`; use that as an
        // accrual floor so freshly added principal cannot inherit an older cooldown window.
        uint256 lockStart = IVeClaimNFTLockStartView(address(ve)).lockStartOf(tokenId);
        if (lockStart > lastClaim) lastClaim = lockStart;

        uint256 elapsed = block.timestamp - lastClaim;
        if (elapsed < 1 days) return 0;

        if (elapsed > Constants.MAX_LOCK_DURATION) elapsed = Constants.MAX_LOCK_DURATION;
        uint256 pseudoOldRemaining = Constants.MAX_LOCK_DURATION - elapsed;

        uint256 principalEff = FurnaceGuardHelper(_guardHelper)
            .incrementalPrincipalEff(lockAmount, Constants.MAX_LOCK_DURATION, pseudoOldRemaining);

        address lockOwner = ve.ownerOf(tokenId);

        uint256 grossBonus = 0;
        uint256 userBonus = 0;
        if (principalEff > 0) {
            (, userBonus) = IFurnaceQuoter(furnaceQuoter).quoteAutoMaxBonus(tokenId);
            if (userBonus == 0) return 0;
            (grossBonus, userBonus,) = _applyBonusAmm(lockOwner, lockAmount, principalEff, Constants.MAX_LOCK_DURATION);
        }

        // Permissionless keepers must not be able to burn an accrual window when the AMM would pay
        // nothing (for example because reserve is empty or the payout rounds to zero). However, once
        // the AMM actually spends reserve, the cooldown must advance even if rounding sends the full
        // gross bonus to the LP side.
        if (grossBonus == 0) return 0;

        // Symmetric with the extend body: refund sub-MIN_TOPUP_AMOUNT user dust to reserve
        // instead of reverting from `_addToLock`. The quoter preflight above prevents
        // permissionless keepers from consuming an AutoMax accrual window when the delivered
        // user bonus would be zero.
        if (userBonus >= Constants.MIN_TOPUP_AMOUNT) {
            _approveVeAndAddToLock(lockOwner, tokenId, userBonus);
        } else if (userBonus > 0) {
            furnaceReserve += userBonus;
            userBonus = 0;
        }

        lastAutoMaxBonusClaim[tokenId] = block.timestamp;
        bonusClaim = userBonus;

        emit Events.AutoMaxBonusClaimed(lockOwner, tokenId, bonusClaim);
    }

    function _requireRegistryAndRouterConfig()
        internal
        view
        returns (IEntryTokenRegistry reg, address router, address factory, address weth, address claimToken)
    {
        address regAddr = entryTokenRegistry;
        (router, factory, weth, claimToken) =
            FurnaceGuardHelper(_guardHelper).getValidatedRouterConfig(regAddr, address(claim));
        reg = IEntryTokenRegistry(regAddr);
    }

    /// @dev Exact-receipt transferFrom via delegatecall to FurnaceGuardHelper.
    function _receiveTokenBalanceDelta(address tokenIn, address from, uint256 amountIn)
        internal
        returns (uint256 actualReceived)
    {
        // nosemgrep: sol-arbitrary-delegatecall
        // slither-disable-next-line controlled-delegatecall
        (bool ok, bytes memory ret) = _guardHelper.delegatecall(
            abi.encodeCall(FurnaceGuardHelper.receiveTokenBalanceDelta, (tokenIn, from, amountIn))
        );
        if (!ok) revert Errors.TransferFailed();
        actualReceived = abi.decode(ret, (uint256));
    }

    /// @dev Receive entry tokens into Furnace.
    ///      WETH stays on the built-in unwrap path; other ERC20s must be explicitly marked
    ///      exact-receipt safe in the registry and pass the exact-receipt guard.
    function _receiveEntryToken(address tokenIn, address from, uint256 amountIn)
        internal
        returns (uint256 actualReceived)
    {
        (IEntryTokenRegistry reg,,, address weth,) = _requireRegistryAndRouterConfig();
        if (tokenIn == weth) {
            IERC20(tokenIn).safeTransferFrom(from, address(this), amountIn);
            return amountIn;
        }

        if (!reg.isFurnaceEntryTokenExactReceiptSafe(tokenIn)) revert Errors.UnsafeEntryToken();
        return _receiveTokenBalanceDelta(tokenIn, from, amountIn);
    }

    /// @dev Swap native ETH → CLAIM via FurnaceGuardHelper.
    ///      Slippage is enforced downstream via the caller-supplied `minVeOut` check.
    function _swapEthToClaim(uint256 ethIn) internal returns (uint256 principalClaim) {
        (, address router, address factory, address weth, address claimToken) = _requireRegistryAndRouterConfig();
        principalClaim = FurnaceGuardHelper(_guardHelper).executeSwapEthToClaim{value: ethIn}(
            entryTokenRegistry, router, factory, weth, claimToken, address(this)
        );
    }

    /// @dev Swap an ERC20 token → CLAIM via FurnaceGuardHelper.
    ///      Slippage is enforced downstream via the caller-supplied `minVeOut` check.
    function _swapTokenToClaim(address tokenIn, uint256 amountIn) internal returns (uint256 principalClaim) {
        (, address router, address factory, address weth, address claimToken) = _requireRegistryAndRouterConfig();
        IERC20(tokenIn).safeTransfer(_guardHelper, amountIn);
        principalClaim = FurnaceGuardHelper(_guardHelper)
            .executeSwapTokenToClaim(
                entryTokenRegistry, tokenIn, amountIn, router, factory, weth, claimToken, address(this)
            );
    }

    function _pullClaimFromSender(uint256 amount) internal {
        IERC20(address(claim)).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _approveVeAndAddToLock(address user, uint256 tokenId, uint256 amount) internal {
        // nosemgrep: sol-arbitrary-delegatecall
        // slither-disable-next-line controlled-delegatecall
        (bool ok,) = _guardHelper.delegatecall(
            abi.encodeCall(FurnaceGuardHelper.addToLockDelegated, (address(claim), address(ve), user, tokenId, amount))
        );
        if (!ok) revert Errors.InvariantViolation();
    }

    /// @dev Bonus AMM: denominators are fresh. lockedSupply/totalSupply read live (ve.totalLockedClaim(), claim.totalSupply()).
    ///      Virtual-depth decay + quote math are externalized to FurnaceGuardHelper to keep Furnace under EIP-170.
    ///      Requires furnaceQuoter to be set (bonus math is offloaded to quoter to keep Furnace under EIP-170).
    function _bonusAmmComputeAndUpdate(
        address user,
        uint256 principalClaim,
        uint256 principalEff,
        uint256 lockDurationSec
    ) internal returns (FurnaceGuardHelper.BonusAmmFrame memory f) {
        if (furnaceQuoter == address(0)) revert Errors.ZeroAddress();

        f.user = user;
        f.principalClaim = principalClaim;
        f.principalEff = principalEff;
        f.lockDurationSec = lockDurationSec;

        uint256 reserveBefore = furnaceReserve;
        f.reserveBefore = reserveBefore;
        if (reserveBefore == 0) return f;

        uint256 lockedSupply = ve.totalLockedClaim();
        uint256 elapsed = FurnaceGuardHelper(_guardHelper).timeSinceLaunch(mineCore, deploymentTime);
        uint256 totalSupply = claim.totalSupply();

        uint256 userSpotBps =
            IFurnaceQuoter(furnaceQuoter).userSpotBonusBps(lockedSupply, totalSupply, reserveBefore, elapsed);
        f.userSpotBps = userSpotBps;

        // Reserve-aware LP scaling (down-only).
        uint256 lpScaleBps = IFurnaceQuoter(furnaceQuoter).lpScaleBps(lockedSupply, totalSupply, reserveBefore, elapsed);
        uint256 virtualDepthEffective;
        FurnaceGuardHelper gh = FurnaceGuardHelper(_guardHelper);
        (f.lpRateBps, f.grossSpotBps, f.virtualDepthBefore, virtualDepthEffective) = gh.computeBonusAmmRates(
            lpRewardsVault != address(0),
            reserveBefore,
            bonusVirtualDepth,
            lastBonusUpdate,
            userSpotBps,
            lpScaleBps,
            block.timestamp
        );
        (f.grossBonus, f.quoteUserBps, f.quoteLpBps) = gh.computeBonusAmmPayout(
            reserveBefore,
            principalEff,
            userSpotBps,
            f.lpRateBps,
            f.grossSpotBps,
            f.virtualDepthBefore,
            virtualDepthEffective
        );

        if (f.grossSpotBps == 0) return f;

        if (reserveBefore < f.grossBonus) revert Errors.InvariantViolation();
        lastBonusUpdate = block.timestamp;
        furnaceReserve = reserveBefore - f.grossBonus;
        bonusVirtualDepth = virtualDepthEffective + principalEff;
    }

    function _bonusAmmSplitAndRoute(FurnaceGuardHelper.BonusAmmFrame memory f) internal {
        (f.userBonus, f.lpBonus) = FurnaceGuardHelper(_guardHelper).splitBonusAmm(f.grossBonus, f.lpRateBps);

        if (f.lpBonus != 0) {
            _fundLpStreamInternal(f.lpBonus, false);
        }
    }

    /// @dev emitBonusPaid MUST remain stateless (events only); delegatecall runs in Furnace storage context.
    function _bonusAmmEmit(FurnaceGuardHelper.BonusAmmFrame memory f) internal {
        if (f.grossBonus == 0) return;

        if (_guardHelper.code.length == 0) revert Errors.InvariantViolation();

        // nosemgrep: sol-arbitrary-delegatecall
        // slither-disable-next-line controlled-delegatecall
        (bool ok,) = _guardHelper.delegatecall(
            abi.encodeCall(FurnaceGuardHelper.emitBonusPaid, (f, furnaceReserve, bonusVirtualDepth))
        );
        if (!ok) revert Errors.InvariantViolation();
    }

    /// @dev Applies the AMM bonus and updates (R, V). Returns (grossBonus, userBonus, lpBonus).
    function _applyBonusAmm(address user, uint256 principalClaim, uint256 principalEff, uint256 lockDurationSec)
        internal
        returns (uint256 grossBonus, uint256 userBonus, uint256 lpBonus)
    {
        // First, accrue the LP overflow drip (time-based) so reserve is up to date.
        _accrueLpOverflowDrip();

        // P_eff == 0: do NOT mutate lastBonusUpdate or V.
        if (principalEff == 0) return (0, 0, 0);

        FurnaceGuardHelper.BonusAmmFrame memory f =
            _bonusAmmComputeAndUpdate(user, principalClaim, principalEff, lockDurationSec);
        if (f.grossSpotBps == 0) return (0, 0, 0);

        _bonusAmmSplitAndRoute(f);
        _bonusAmmEmit(f);

        return (f.grossBonus, f.userBonus, f.lpBonus);
    }

    // LP rewards stream (smoothing)

    /// @notice View helper: remaining CLAIM scheduled for the LP rewards stream (future-only).
    /// @dev Defined as `(finish > now) ? (finish-now) * rate : 0`.
    ///      NOTE: This excludes `lpStreamCarry` (rounding dust from schedule divisions, bounded to
    ///      < LP_STREAM_WINDOW wei per funding). For precise solvency accounting that includes carry
    ///      and matured-but-unpaid amounts, use `FurnaceGuardHelper.lpStreamLiability(...)`.
    function getLpStreamRemaining() external view returns (uint256) {
        uint256 finish = lpStreamPeriodFinish;
        if (finish <= block.timestamp) return 0;
        return (finish - block.timestamp) * lpStreamRatePerSec;
    }

    /// @dev LP rewards economically owed to the currently configured vault but still parked in Furnace.
    ///      Used to fail closed on vault rewires until all already-earned value has been accrued.
    function _lpRewardsVaultLiability() internal view returns (uint256 liability) {
        liability = FurnaceGuardHelper(_guardHelper)
            .lpRewardsVaultLiability(
                lpRewardsVault,
                mineCore,
                deploymentTime,
                furnaceReserve,
                lpStreamCarry,
                lpStreamPeriodFinish,
                lpStreamRatePerSec,
                lastLpOverflowDripUpdate,
                lpStreamLastUpdate
            );
    }

    /// @notice View helper: full LP stream state tuple for UI/analytics.
    function getLpStreamState()
        external
        view
        returns (uint256 ratePerSec, uint256 periodFinish, uint256 lastUpdate, uint256 remaining)
    {
        ratePerSec = lpStreamRatePerSec;
        periodFinish = lpStreamPeriodFinish;
        lastUpdate = lpStreamLastUpdate;
        if (periodFinish > block.timestamp) {
            remaining = (periodFinish - block.timestamp) * ratePerSec;
        }
    }

    function _notifyLpRewardsVaultBestEffort(address vault, uint256 amountClaim) internal {
        // Call vault.notifyRewards directly so msg.sender == furnace, which
        // LpStakingVault7D.onlyRewardNotifier requires.
        try ILpStakingVault7D(vault).notifyRewards{gas: 200_000}(amountClaim) {}
        catch {
            emit Events.LpRewardsNotifyFailed(vault, amountClaim, bytes(""));
        }
    }

    function _settleMaturedLpCarry(address vault) internal {
        uint256 carry = lpStreamCarry;
        if (vault == address(0) || carry == 0) return;
        if (lpStreamRatePerSec != 0 || lpStreamPeriodFinish != 0) return;

        // Best-effort settlement — don't let a broken old vault block vault rewiring.
        lpStreamCarry = 0;
        if (SafeTransfer.callTransfer(IERC20(address(claim)), vault, carry)) {
            _notifyLpRewardsVaultBestEffort(vault, carry);
        } else {
            lpStreamCarry = carry;
            emit Events.CarrySettlementFailed(vault, carry);
        }
    }

    /// @dev Accrues the LP rewards stream by transferring any currently owed amount to the LP vault.
    ///      No-op when LP rewards are disabled.
    function _accrueLpStream() internal returns (uint256 streamed) {
        address vault = lpRewardsVault;
        if (vault == address(0)) return 0;

        uint256 finish = lpStreamPeriodFinish;
        uint256 rate = lpStreamRatePerSec;
        uint256 last = lpStreamLastUpdate;

        // Nothing scheduled.
        if (rate == 0 || finish == 0) {
            lpStreamLastUpdate = block.timestamp;
            return 0;
        }

        if (block.timestamp <= last) return 0;

        uint256 t = block.timestamp < finish ? block.timestamp : finish;
        if (t <= last) return 0;

        uint256 dt = t - last;
        streamed = dt * rate;

        // Update cursor first. Token transfer failures revert; LP vault notify is best-effort.
        lpStreamLastUpdate = t;

        if (streamed != 0) {
            // slither-disable-next-line reentrancy-no-eth
            IERC20(address(claim)).safeTransfer(vault, streamed);
            _notifyLpRewardsVaultBestEffort(vault, streamed);
        }

        // If the period ended, clear the schedule (prevents stale remaining computations).
        if (t >= finish) {
            lpStreamRatePerSec = 0;
            lpStreamPeriodFinish = 0;
        }
    }

    /// @dev Funds the LP stream by folding `amount` into a fresh `LP_STREAM_WINDOW` schedule.
    ///      MUST accrue first to avoid retroactive schedule inflation (unless caller just accrued).
    /// @param doAccrue If false, skip prior accrual (caller must have accrued; used by _accrueLpOverflowDrip).
    function _fundLpStreamInternal(uint256 amount, bool doAccrue) internal {
        if (amount == 0 && lpStreamCarry == 0) return;
        if (lpRewardsVault == address(0)) return;
        if (doAccrue) _accrueLpStream();

        (uint256 newRate, uint256 newFinish, uint256 newCarry) = FurnaceGuardHelper(_guardHelper)
            .computeStreamSchedule(amount, lpStreamPeriodFinish, lpStreamRatePerSec, lpStreamCarry, block.timestamp);

        lpStreamCarry = newCarry;
        lpStreamRatePerSec = newRate;
        lpStreamPeriodFinish = newFinish;
        lpStreamLastUpdate = block.timestamp;

        emit Events.LpStreamFunded(amount, newRate, newFinish);
    }

    // LP sellback cap (volume-driven)

    function _trackLpSaleRewardFunding(uint256 amount) internal {
        if (amount == 0) return;
        uint256 day = block.timestamp / 1 days;
        if (lpSaleFundedDay != day) {
            lpSaleFundedDay = day;
            lpSaleFundedToday = 0;
        }
        lpSaleFundedToday += amount;
    }

    /// @notice View helper: current LP sellback reward cap/day.
    function getLpSaleRewardCapPerDay() external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).lpSaleRewardCapPerDay(mineCore);
    }

    /// @notice View helper: CLAIM funded to LP stream from sellbacks today.
    function getLpSaleRewardFundedToday() external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).lpSaleRewardFundedToday(lpSaleFundedDay, lpSaleFundedToday);
    }

    /// @notice View helper: remaining LP sellback reward cap for the current day.
    function getLpSaleRewardCapRemaining() external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).lpSaleRewardCapRemaining(mineCore, lpSaleFundedDay, lpSaleFundedToday);
    }

    // LP overflow drip (time-based, excess reserve above target)

    /// @return streamed Amount transferred to LP vault by stream accrual.
    /// @return dripped Amount added to stream from overflow drip.
    function _accrueLpOverflowDrip() internal returns (uint256 streamed, uint256 dripped) {
        streamed = _accrueLpStream();
        uint256 last = lastLpOverflowDripUpdate;
        if (block.timestamp <= last) return (streamed, 0);

        // Always advance the cursor to prevent retroactive dripping when the drip is disabled/paused.
        lastLpOverflowDripUpdate = block.timestamp;

        address vault = lpRewardsVault;
        if (vault == address(0)) return (streamed, 0);

        uint256 reserveBefore = furnaceReserve;
        uint256 reserveTarget = Constants.RESERVE_TARGET_FINAL;

        // Nothing to drip if we're already at/below target.
        if (reserveBefore <= reserveTarget) return (streamed, 0);

        uint256 dt = block.timestamp - last;
        FurnaceGuardHelper.OverflowDripPreview memory p =
            FurnaceGuardHelper(_guardHelper).previewOverflowDrip(mineCore, deploymentTime, reserveBefore);
        uint256 perDay = p.perDay;
        if (perDay == 0) return (streamed, 0);

        dripped = (perDay * dt) / 1 days;
        if (dripped == 0) return (streamed, 0);

        // Clamp so we never drip below the final target.
        uint256 maxSpend = reserveBefore - reserveTarget;
        if (dripped > maxSpend) dripped = maxSpend;

        // Update reserve and fund the LP rewards stream (smoothed over `LP_STREAM_WINDOW`).
        furnaceReserve = reserveBefore - dripped;

        _fundLpStreamInternal(dripped, false); // already accrued at start of this function

        {
            // nosemgrep: sol-arbitrary-delegatecall
            // slither-disable-next-line controlled-delegatecall
            (bool ok,) = _guardHelper.delegatecall(
                abi.encodeCall(
                    FurnaceGuardHelper.emitLpOverflowDripPaid,
                    (
                        dripped,
                        reserveBefore,
                        reserveBefore - dripped,
                        p.alphaBps,
                        p.gateBps,
                        p.capInflowPerDay,
                        Constants.LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY,
                        reserveTarget,
                        maxSpend
                    )
                )
            );
            if (!ok) revert Errors.InvariantViolation();
        }
    }

    /// @notice Permissionless tick to:
    ///         1) accrue the LP rewards stream (transfers any owed amount to `lpRewardsVault`), and
    ///         2) accrue the overflow drip proportional to elapsed time (capped per day by `perDay`).
    /// @return streamed CLAIM wei transferred to `lpRewardsVault` by the LP stream in this call.
    function tick() external nonReentrant returns (uint256 streamed) {
        (streamed,) = _accrueLpOverflowDrip();

        // Settle stranded carry when no active schedule exists.
        if (lpStreamCarry > 0 && lpStreamRatePerSec == 0 && lpRewardsVault != address(0)) {
            _fundLpStreamInternal(0, false);
        }

        // Keep reserve accounting bounded to the contract's actual CLAIM balance.
        _syncFurnaceReserve();
    }

    /// @notice View helper: current inflow/day used by the drip cap.
    function getFurnaceInflowPerDay() external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).getFurnaceInflowPerDay(mineCore);
    }

    /// @notice View helper: current inflow-share cap/day (10% of inflow/day).
    function getCapInflowPerDay() external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).getCapInflowPerDay(mineCore);
    }

    /// @notice View helper: current LP overflow drip/day (after schedule + gate + caps).
    function getLpOverflowDripPerDay() external view override(IFurnace, IFurnaceDripLens) returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).getLpOverflowDripPerDay(mineCore, deploymentTime, furnaceReserve);
    }

    /// @dev Accrues the sell impact volume by `addAmount` (in CLAIM units) after applying decay.
    function _accrueSellImpactVolume(uint256 addAmount) internal returns (uint256 volAfter) {
        volAfter = FurnaceGuardHelper(_guardHelper)
            .computeAccruedSellImpactVolume(sellImpactVolume, lastSellImpactUpdate, addAmount);
        sellImpactVolume = volAfter;
        lastSellImpactUpdate = block.timestamp;
    }

    // Delegation

    function _emitDelegationSession(address user, uint8 actionType, uint256 perm, uint256 tokenId) internal {
        emit Events.DelegationSessionUsed(user, msg.sender, actionType, perm, tokenId, block.timestamp);
    }

    function _requireDelegated(address user, uint256 requiredPerms) internal view {
        address hub = delegationHub;
        FurnaceGuardHelper(_guardHelper)
            .requireCanonicalDelegationHub(address(this), address(claim), address(ve), hub, mineCore);
        if (!IDelegationHub(hub).isAuthorized(user, msg.sender, requiredPerms)) revert Errors.NotAuthorized();
    }
}
