// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Errors} from "./lib/Errors.sol";
import {SafeApprove} from "./lib/SafeApprove.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {SafeERC20View} from "./lib/SafeERC20View.sol";
import {Events} from "./lib/Events.sol";
import {Constants} from "./lib/Constants.sol";
import {IClaimToken} from "./interfaces/IClaimToken.sol";
import {IMineCore} from "./interfaces/IMineCore.sol";
import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IShareholderRoyalties} from "./interfaces/IShareholderRoyalties.sol";
import {IFurnace} from "./interfaces/IFurnace.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IDelegationHub} from "./interfaces/IDelegationHub.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "./lib/DelegationActionTypes.sol";
import {MineCoreHelper} from "./MineCoreHelper.sol";
import {UpgradeableProtocolBase} from "./lib/UpgradeableProtocolBase.sol";

interface IClaimAllHelperWiringView {
    function mineCore() external view returns (address);
    function royalties() external view returns (address);
}

interface IShareholderRoyaltiesClaimAllHelperView {
    function claimAllHelper() external view returns (address);
}

/// @notice Main game engine (reigns, takeovers, emissions).
/// @dev Spec: docs/spec/spec-v1.0.0.md (takeover pricing, takeover sequence, emissions, pause/clamp).
contract MineCore is UpgradeableProtocolBase, IMineCore {
    using SafeERC20 for IERC20;

    IClaimToken public immutable claim;
    IVeClaimNFT public immutable ve;
    IShareholderRoyalties public immutable royalties;
    IFurnace public furnace;

    /// @dev Self-deployed helper used to keep MineCore runtime bytecode under EIP-170.
    address internal immutable _helper;

    // Canonical external allowlist + routing config (EntryTokenRegistry)
    address public entryTokenRegistry;

    // Freeze (one-way config lock for core game-rule wiring)
    bool public configFrozen;

    // Pause / config
    address public guardian; // long-term pause role; LaunchController exception during genesis
    address public claimAllHelper;
    address public delegationHub; // optional: enables session delegation flows
    bool public takeoversPaused;

    // Current reign state
    address public currentKing;
    uint256 public currentReignId;
    uint256 public currentReignStartTime;
    uint256 public currentReignLastAccrualTime; // clamped on pause transitions (SPEC §5.6.1)
    uint256 public referencePrice;

    // Emission schedule anchor (SPEC §5.4.3)
    uint256 public emissionStartTime;

    // Genesis King-stream bucket (LaunchController finalization)
    // Window: 10 days on Base mainnet; 1 day on testnets/local (chain-gated).
    uint256 public GENESIS_ACCRUAL_DURATION;

    // Gas guard for ve checkpoint loops during takeovers (SPEC §2.7).
    // Leaves headroom for accrual, ETH splits, and storage writes.
    uint256 internal constant CHECKPOINT_GAS_GUARD = 500_000;

    // Best-effort king payout gas stipend during takeover.
    // Prevents a malicious/nontrivial King receiver from exhausting takeover gas; failures fall back to kingEthBalance.
    uint256 internal constant KING_PAYOUT_GAS_STIPEND = 30_000;
    /// @dev Gas stipend for best-effort refunds during takeovers (failure falls back to refundEthBalance).
    uint256 internal constant REFUND_GAS_STIPEND = 30_000;
    bool public genesisKingClaimCollected;
    uint256 public genesisKingClaimMinted;

    // ETH owed to dethroned kings when best-effort in-tx payout fails (withdraw pattern fallback).
    mapping(address => uint256) public kingEthBalance;
    uint256 public totalKingEthOwed;

    mapping(address => uint256) public pendingKingClaim;

    uint256 public totalPendingKingClaim;

    // Optional per-reign routing: where to send the dethroned king's 75% ETH share and mined CLAIM.
    // If unset (0), defaults to the king identity for that reign.
    mapping(uint256 => address) public reignEthRecipient;
    mapping(uint256 => address) public reignClaimRecipient;

    // Hybrid refund fallback bucket (SPEC §5.4.2 step 7)
    mapping(address => uint256) public refundEthBalance;
    uint256 public totalRefundEthOwed;

    /// @dev Shareholder ETH that failed to reach royalties during takeover (best-effort).
    ///      Retry via retryPushShareholderEth() when royalties/ve are healthy.
    uint256 public shareholderEthPending;

    /// @notice Cooldown timestamp for retryPushShareholderEth (anti-grief).
    uint256 public lastShareholderRetryTs;

    // Snapshot of total ve at reign finalization (SPEC §5.4.2 step 4)
    mapping(uint256 => uint256) internal totalVeForReign;

    mapping(uint256 => ReignInfo) internal reignInfo;
    mapping(address => uint256[]) internal kingReigns;

    // King auto-lock (optional): route King-stream CLAIM through the Furnace

    /// @notice Per-king opt-in configuration for auto-locking King-stream mined CLAIM into the Furnace.
    /// @dev Off by default. When enabled, MineCore will attempt to route the dethroned King's mined
    ///      CLAIM through `Furnace.enterWithClaimFor(...)` at reign finalization.
    ///
    /// Design notes:
    /// - `targetTokenId == 0` selects "create-once" mode:
    ///   - the first successful auto-lock creates a new veNFT and stores its id in `pinnedTokenId`.
    ///   - subsequent auto-locks top up that pinned lock (no new veNFTs).
    /// - `targetTokenId != 0` selects "existing lock" mode and `pinnedTokenId` is unused (but preserved).
    struct KingAutoLockConfig {
        bool enabled;
        bool createAutoMax; // only meaningful when `targetTokenId == 0` (create-once)
        uint32 durationSeconds; // 0 allowed only when `targetTokenId != 0` ("use remaining")
        uint256 targetTokenId;
        uint256 pinnedTokenId;
        uint256 minVeOut;
    }

    mapping(address => KingAutoLockConfig) internal kingAutoLockConfig;

    modifier whenNotFrozen() {
        if (configFrozen) revert Errors.ConfigFrozen();
        _;
    }

    modifier onlyGuardian() {
        address sender = msg.sender;
        if (sender != guardian) revert Errors.OnlyGuardian();
        // Defense-in-depth: a previously-clean human guardian seat may install an
        // EIP-7702 delegation designator after the rotation. `setGuardian` rejects
        // 7702 designators on the seat itself; the runtime check here closes the
        // post-seating install vector.
        _rejectDelegatedEOA(sender);
        _;
    }

    modifier onlyClaimAllHelper() {
        if (msg.sender != claimAllHelper) revert Errors.OnlyClaimAllHelper();
        _;
    }

    constructor(address _claim, address _ve, address _royalties, address initialOwner) {
        if (_claim == address(0) || _ve == address(0) || _royalties == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (_claim.code.length == 0 || _ve.code.length == 0 || _royalties.code.length == 0) {
            revert Errors.NotAContract();
        }

        address helper_ = address(new MineCoreHelper());
        MineCoreHelper(helper_).requireCanonicalCoreRoots(address(0), _claim, _ve, _royalties);

        claim = IClaimToken(_claim);
        ve = IVeClaimNFT(_ve);
        royalties = IShareholderRoyalties(_royalties);
        _helper = helper_;

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
        // The runtime guardian seat rejects EIP-7702 delegated EOAs via
        // `setGuardian()`. The initializer applies the same rule so a delegated
        // `initialOwner` cannot ship as the genesis guardian.
        _rejectDelegatedEOA(initialOwner);
        __UpgradeableProtocolBase_init(initialOwner);

        // Initialization-time split-brain hardening: require the proxied/direct runtime address to
        // match ClaimToken.mineCore() once ClaimToken has been wired, while still allowing new
        // implementation deployments to reuse the same immutable asset roots.
        MineCoreHelper(_helper)
            .requireCanonicalCoreRoots(address(this), address(claim), address(ve), address(royalties));

        guardian = initialOwner;
        // Launch-safe default: keep takeovers closed until genesis finalization explicitly opens them.
        takeoversPaused = true;
        emissionStartTime = block.timestamp;
        GENESIS_ACCRUAL_DURATION = block.chainid == 8453 ? 10 days : 1 days;

        // Defensive initialization; first takeover uses the floor anyway when currentKing == address(0).
        referencePrice = Constants.TAKEOVER_PRICE_FLOOR;
    }

    function renounceOwnership() public pure {
        revert Errors.NotAuthorized();
    }

    /// @notice Accept native ETH only from the configured wrapped-native (WETH) token.
    /// @dev The `takeoverWithToken*` family ends token-entry flows with
    ///      `IWETH(wrappedNative).withdraw(...)`, which sends ETH to this contract via
    ///      a plain `call{value:}("")` → `receive()`. A permissive `receive()` also
    ///      accepts unsolicited donations that accrue into untracked balance the owner
    ///      must later `rescueEth`. Restricting the allowed sender to the configured
    ///      WETH preserves the unwrap path while rejecting any other inbound ETH.
    ///      Pre-wiring (before `entryTokenRegistry` is set) any direct ETH send also
    ///      reverts, which is fine because the unwrap path is only reachable once the
    ///      registry has been configured.
    receive() external payable {
        address regAddr = entryTokenRegistry;
        if (regAddr != address(0) && regAddr.code.length != 0) {
            try IEntryTokenRegistry(regAddr).getRouterConfig() returns (address, address, address weth, address) {
                if (msg.sender == weth && weth != address(0)) return;
            } catch {}
        }
        revert Errors.NotAuthorized();
    }

    /// @notice Owner-only rescue for ETH accidentally sent to MineCore that is not tracked by any
    ///         accounting bucket (kingEthBalance, refundEthBalance, shareholderEthPending).
    function rescueEth(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert Errors.ZeroAddress();

        uint256 tracked = shareholderEthPending + totalKingEthOwed + totalRefundEthOwed;
        uint256 balance = address(this).balance;
        if (balance <= tracked) return;

        uint256 rescuable = balance - tracked;
        bool ok = _callWithValueNoReturndata(to, rescuable, gasleft());
        if (!ok) revert Errors.EthTransferFailed();
    }

    /// @notice Owner-only rescue for CLAIM accidentally sent to MineCore that is not tracked by
    ///         pendingKingClaim accounting.
    function rescueClaim(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert Errors.ZeroAddress();

        uint256 tracked = totalPendingKingClaim;
        uint256 balance = IERC20(address(claim)).balanceOf(address(this));
        if (balance <= tracked) return;

        uint256 rescuable = balance - tracked;
        IERC20(address(claim)).safeTransfer(to, rescuable);
    }

    /// @dev True only for the LaunchController-like guardian accepted during genesis.
    ///      This is narrower than "any contract guardian": split-key deployments may deliberately
    ///      start with a contract owner/guardian (e.g. Safe/timelock), and that must not trigger
    ///      the MineCore genesis lock before the first validated LaunchController handoff.
    function _isCanonicalGenesisGuardian(address candidate) internal view returns (bool) {
        return MineCoreHelper(_helper).isCanonicalGenesisGuardian(address(this), address(claim), candidate);
    }

    /// @dev Best-effort verification that `f` is the canonically wired Furnace for MineCore king auto-locking.
    function _isReciprocallyWiredFurnace(address f) internal view returns (bool) {
        return MineCoreHelper(_helper)
            .isReciprocallyWiredFurnace(address(this), address(claim), address(ve), address(royalties), f);
    }

    /// @dev Resolve the canonical DelegationHub for MineCore-owned delegated actions.
    ///      Fail closed unless the live Furnace surface still agrees on the same hub and roots.
    ///      Without this, a single-surface MineCore hub drift can authorize delegated takeovers,
    ///      reign-recipient reroutes, or king auto-lock config changes under a foreign hub even
    ///      while the rest of the protocol still treats the Furnace-backed hub as canonical.
    function _resolveCanonicalDelegationHub() internal view returns (address hub) {
        hub = delegationHub;
        MineCoreHelper(_helper)
            .requireCanonicalDelegationHub(
                address(this), address(claim), address(ve), address(royalties), address(furnace), hub
            );
    }

    /// @dev Reject EIP-7702 delegated EOAs (Pectra). A 7702 designator is exactly 23 bytes
    ///      shaped as `0xEF 0x01 0x00 || 20-byte target`. `code.length > 0` does not exclude
    ///      this pattern, so a delegated EOA can pass a vanilla `NotAContract` gate while the
    ///      underlying signer retains the ability to revoke the delegation and silently change
    ///      the effective code that runs at the address. We therefore enforce the same
    ///      defense-in-depth check used by `MaintenanceHub`, `FurnaceGuardHelper`,
    ///      `MineCoreQuoter`, `DexAdapter`, and `ClaimToken*` on every canonical-role setter.
    ///      Bare EOAs are still rejected by the existing `code.length == 0` check at each call
    ///      site; this helper only adds the 7702 case on top.
    function _rejectDelegatedEOA(address a) internal view {
        if (a.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(a, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.NotAContract();
    }

    // Wiring / admin

    function setGuardian(address _guardian) external {
        address sender = msg.sender;
        if (!genesisKingClaimCollected) {
            // Pre-genesis the LaunchController-style guardian gains one additional
            // economic privilege: it can materialize the one-shot genesis King-stream CLAIM bucket.
            // Only owner may install that contract guardian; the current human guardian must not be
            // able to promote itself into this stronger role.
            if (sender != owner()) revert Errors.NotAuthorized();
            // Runtime 7702 reject on the caller seat. The owner branch does not
            // route through `onlyOwner`, so apply the same guard `_checkOwner`
            // runs for owner-only entry points.
            _validateNewOwner(sender);
        } else if (sender == owner()) {
            // Runtime 7702 reject on the caller seat. The owner branch does not
            // route through `onlyOwner`, so apply the same guard `_checkOwner`
            // runs for owner-only entry points.
            _validateNewOwner(sender);
        } else if (sender == guardian) {
            // guardian self-rotation path: re-run the runtime delegate guard so a
            // post-seating 7702 install cannot route a self-rotation through the
            // guardian role. The seat-side check on `_guardian` covers the new seat.
            _rejectDelegatedEOA(sender);
        } else {
            revert Errors.NotAuthorized();
        }
        if (_guardian == address(0)) revert Errors.ZeroAddress();
        // Defense-in-depth: an EIP-7702 delegated EOA passes a vanilla `code.length > 0`
        // gate but lets the underlying signer revoke the delegation and silently change
        // the effective code that runs at the address. Reject it on every nonzero
        // guardian assignment, including the post-genesis branch where guardian may
        // be a bare EOA.
        _rejectDelegatedEOA(_guardian);

        address oldGuardian = guardian;
        if (!genesisKingClaimCollected) {
            // Genesis authority model: once the canonical LaunchController-like guardian is installed,
            // it must remain the MineCore guardian for the rest of the genesis window.
            // A split-key deployment may begin with a contract owner/guardian (e.g. Safe/timelock);
            // that pre-existing contract must not trip GenesisGuardianLocked before the owner performs
            // the first validated handoff into the LaunchController-style role.
            if (_isCanonicalGenesisGuardian(oldGuardian)) revert Errors.GenesisGuardianLocked();
            if (_guardian.code.length == 0) revert Errors.NotAContract();
            if (!_isCanonicalGenesisGuardian(_guardian)) revert Errors.WiringMismatch();
        }

        guardian = _guardian;
        emit Events.GuardianChanged(oldGuardian, _guardian);
    }

    function setFurnace(address _furnace) external onlyOwner whenNotFrozen nonReentrant {
        if (_furnace == address(0)) revert Errors.ZeroAddress();
        if (_furnace.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_furnace);
        if (_furnace == address(this)) revert Errors.WiringMismatch();

        // MineCore and Furnace MUST use different EntryTokenRegistry instances.
        if (
            entryTokenRegistry != address(0)
                && MineCoreHelper(_helper).sharesEntryTokenRegistry(_furnace, entryTokenRegistry)
        ) {
            revert Errors.WiringMismatch();
        }

        // Validate reciprocal wiring — the new Furnace must point back at this MineCore.
        // mineCore() is intentionally omitted from IFurnace; use raw selector.
        // address(0) is allowed during initial wiring (setMineCore on Furnace may not
        // have been called yet). A non-zero address that differs from this MineCore
        // is rejected to prevent cross-bundle mis-configuration.
        (bool ok, bytes memory ret) = _furnace.staticcall(abi.encodeWithSignature("mineCore()"));
        if (ok && ret.length >= 32) {
            address furnaceMineCore = abi.decode(ret, (address));
            if (furnaceMineCore != address(0) && furnaceMineCore != address(this)) {
                revert Errors.WiringMismatch();
            }
        }

        address oldFurnace = address(furnace);
        furnace = IFurnace(_furnace);
        emit Events.FurnaceChanged(oldFurnace, _furnace);
    }

    /// @notice Permanently lock the canonical Furnace pointer, ClaimAllHelper, and DelegationHub trust root.
    /// @dev After freeze, only operational peripherals (entryTokenRegistry, guardian) remain
    ///      owner-configurable. DelegationHub is the delegation trust root; post-freeze migration
    ///      requires a coordinated fresh deploy of MineCore and Furnace and is therefore gated
    ///      behind `whenNotFrozen` on `setDelegationHub`.
    function freezeConfig() external onlyOwner whenNotFrozen {
        address furnaceAddr = address(furnace);
        if (furnaceAddr == address(0)) revert Errors.ZeroAddress();
        if (furnaceAddr.code.length == 0) revert Errors.NotAContract();
        if (claimAllHelper == address(0)) revert Errors.ZeroAddress();
        if (claimAllHelper.code.length == 0) revert Errors.NotAContract();
        if (IClaimAllHelperWiringView(claimAllHelper).mineCore() != address(this)) revert Errors.WiringMismatch();
        if (IClaimAllHelperWiringView(claimAllHelper).royalties() != address(royalties)) {
            revert Errors.WiringMismatch();
        }
        if (IShareholderRoyaltiesClaimAllHelperView(address(royalties)).claimAllHelper() != claimAllHelper) {
            revert Errors.WiringMismatch();
        }
        if (!_isReciprocallyWiredFurnace(furnaceAddr)) revert Errors.WiringMismatch();

        configFrozen = true;
        emit Events.ConfigFrozen();
    }

    function setEntryTokenRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert Errors.ZeroAddress();
        if (_registry.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_registry);

        // MineCore and Furnace MUST use different EntryTokenRegistry instances.
        // Wiring scripts already reject shared registries; enforce the same invariant
        // here so a live owner reconfiguration cannot silently widen the takeover token surface.
        if (MineCoreHelper(_helper).sharesEntryTokenRegistry(address(furnace), _registry)) {
            revert Errors.WiringMismatch();
        }

        entryTokenRegistry = _registry;
        emit Events.EntryTokenRegistrySet(_registry);
    }

    function setClaimAllHelper(address _claimAllHelper) external onlyOwner whenNotFrozen {
        if (_claimAllHelper == address(0)) revert Errors.ZeroAddress();
        if (_claimAllHelper.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_claimAllHelper);
        address oldHelper = claimAllHelper;
        claimAllHelper = _claimAllHelper;
        emit Events.ClaimAllHelperChanged(oldHelper, _claimAllHelper);
    }

    function setDelegationHub(address _delegationHub) external onlyOwner whenNotFrozen {
        if (_delegationHub == address(0)) revert Errors.ZeroAddress();
        if (_delegationHub.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_delegationHub);
        address old = delegationHub;
        delegationHub = _delegationHub;
        emit Events.DelegationHubChanged(old, _delegationHub);
    }

    // Views (pricing + history)

    /// @notice Price to takeover at an arbitrary timestamp.
    /// @dev MUST match SPEC §5.3 exactly (linear decay from referencePrice toward 0, clamped at floor).
    function getTakeoverPrice(uint256 timestamp) public view returns (uint256 price) {
        return MineCoreHelper(_helper).takeoverPrice(currentKing, currentReignStartTime, referencePrice, timestamp);
    }

    function getCurrentTakeoverPrice() external view returns (uint256 price) {
        return getTakeoverPrice(block.timestamp);
    }

    function getReignInfo(uint256 reignId) external view returns (ReignInfo memory info) {
        return reignInfo[reignId];
    }

    function getKingReigns(address king, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory reignIds)
    {
        uint256[] storage arr = kingReigns[king];
        uint256 len = arr.length;

        // Caller-controlled pagination: clamp limit to a hard per-call cap.
        if (limit > Constants.MAX_KING_REIGNS_PER_CALL) limit = Constants.MAX_KING_REIGNS_PER_CALL;

        if (cursor >= len || limit == 0) return new uint256[](0);

        uint256 end = cursor + limit;
        if (end > len) end = len;

        uint256 outLen = end - cursor;
        reignIds = new uint256[](outLen);
        for (uint256 i = 0; i < outLen; ++i) {
            reignIds[i] = arr[cursor + i];
        }
    }

    // Pause controls

    /// @notice Pause/unpause takeovers.
    /// @dev MUST clamp currentReignLastAccrualTime on both transitions (SPEC §5.6.1).
    ///      NOTE: Price decay is intentionally NOT frozen during pause. After a pause > 1 hour
    ///      the first takeover on unpause will execute at the floor price (0.001 ETH).
    function setTakeoversPaused(bool paused) external onlyGuardian {
        if (paused == takeoversPaused) return;
        if (!paused && !genesisKingClaimCollected) revert Errors.GenesisKingClaimNotCollected();

        takeoversPaused = paused;

        // Clamp accrual cursor so paused time is never mined later.
        if (currentKing != address(0)) {
            currentReignLastAccrualTime = block.timestamp;
        }

        emit Events.TakeoversPausedChanged(paused);
    }

    /// @notice Single pause surface for locking by forwarding to Furnace.
    /// @dev Furnace.guardian MUST be set to MineCore before freezing configs (SPEC §5.6.2).
    ///      Pre-checks reciprocal wiring AND that this MineCore is the Furnace's guardian,
    ///      so callers get a clear WiringMismatch instead of an opaque Furnace-side auth revert.
    function setLockingPaused(bool paused) external onlyGuardian nonReentrant {
        address furnaceAddr = address(furnace);
        if (furnaceAddr == address(0)) revert Errors.ZeroAddress();

        // Single pause surface hardening: fail closed unless the live Furnace pointer still belongs
        // to the canonical MineCore / Ve / ShareholderRoyalties bundle. Otherwise this call can
        // succeed against a foreign contract while the real Furnace remains unpaused.
        if (!_isReciprocallyWiredFurnace(furnaceAddr)) revert Errors.WiringMismatch();

        // Fail-closed guardian check — surface a clear WiringMismatch before the
        // Furnace's own onlyGuardian modifier produces a confusing auth error.
        {
            (bool success, bytes memory ret) = furnaceAddr.staticcall(abi.encodeWithSignature("guardian()"));
            if (!success || ret.length < 32) revert Errors.WiringMismatch();
            address furnaceGuardian = abi.decode(ret, (address));
            if (furnaceGuardian != address(this)) revert Errors.WiringMismatch();
        }

        furnace.setLockingPaused(paused);
    }

    // Genesis (LaunchController)

    /// @notice Materialize the genesis King-stream CLAIM bucket into `to`.
    /// @dev One-shot. MUST revert before emissionStartTime + GENESIS_ACCRUAL_DURATION.
    ///      Restricted to the canonical LaunchController-like guardian for this exact MineCore + CLAIM
    ///      pair; unrelated contract guardians and EOAs are rejected.
    function collectGenesisKingClaim(address to) external onlyGuardian nonReentrant returns (uint256 claimMinted) {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (msg.sender.code.length == 0) revert Errors.NotAContract();
        // Split-key deployments may deliberately start with a contract owner/guardian (e.g. Safe/timelock),
        // but that pre-existing contract must not be able to bypass the canonical LaunchController
        // bootstrap flow and materialize the genesis bucket directly.
        if (!_isCanonicalGenesisGuardian(msg.sender)) revert Errors.WiringMismatch();
        if (genesisKingClaimCollected) revert Errors.GenesisKingClaimAlreadyCollected();

        uint256 end = emissionStartTime + GENESIS_ACCRUAL_DURATION;
        if (block.timestamp < end) revert Errors.GenesisWindowNotEnded();

        // CEI: set one-shot flag before minting
        genesisKingClaimCollected = true;

        // Deterministic amount: integral of the King emission schedule over the genesis window.
        claimMinted = _kingEmitted(emissionStartTime, end);
        genesisKingClaimMinted = claimMinted;

        claim.mint(to, claimMinted);
    }

    // Core mechanics

    function takeover(uint256 maxPrice) external payable nonReentrant {
        if (takeoversPaused) revert Errors.TakeoversPaused();

        // A king may not takeover themselves.
        if (msg.sender == currentKing && currentKing != address(0)) revert Errors.NotAuthorized();

        uint256 price = getTakeoverPrice(block.timestamp);
        if (price > maxPrice) revert Errors.PriceExceeded();
        _executeTakeover(msg.value, price, msg.sender, msg.sender, msg.sender, msg.sender);
    }

    /// @notice Token takeover using an allowlisted entry token swapped to ETH via DEX.
    /// @dev Uses `block.timestamp + SWAP_DEADLINE_SECONDS` as the DEX swap deadline
    ///      (still no strong MEV protection because the base time is block-derived).
    ///      For MEV-sensitive txns, prefer `takeoverWithTokenAndDeadline()`.
    function takeoverWithToken(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 maxPrice)
        external
        nonReentrant
    {
        if (takeoversPaused) revert Errors.TakeoversPaused();

        // A king may not takeover themselves.
        if (msg.sender == currentKing && currentKing != address(0)) revert Errors.NotAuthorized();

        uint256 price = getTakeoverPrice(block.timestamp);
        if (price > maxPrice) revert Errors.PriceExceeded();
        uint256 ethOut =
            _swapTokenToEth(tokenIn, amountIn, minEthOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS);
        _executeTakeover(ethOut, price, msg.sender, msg.sender, msg.sender, msg.sender);
    }

    /// @notice Token takeover with a caller-supplied swap deadline (MEV protection).
    function takeoverWithTokenAndDeadline(
        address tokenIn,
        uint256 amountIn,
        uint256 minEthOut,
        uint256 maxPrice,
        uint256 deadline
    ) external nonReentrant {
        if (takeoversPaused) revert Errors.TakeoversPaused();
        if (msg.sender == currentKing && currentKing != address(0)) revert Errors.NotAuthorized();
        if (block.timestamp > deadline) revert Errors.DeadlineExpired();
        uint256 price = getTakeoverPrice(block.timestamp);
        if (price > maxPrice) revert Errors.PriceExceeded();

        uint256 ethOut = _swapTokenToEth(tokenIn, amountIn, minEthOut, deadline);
        _executeTakeover(ethOut, price, msg.sender, msg.sender, msg.sender, msg.sender);
    }

    /// @notice Delegated takeover: `msg.sender` pays ETH, but `newKing` becomes the king identity.
    /// @dev Requires an active DelegationHub session authorizing `msg.sender` for `P_TAKEOVER_FOR`.
    ///      The new reign's default routing is:
    ///      - ETH recipient: `msg.sender` (bot), so it can keep looping without pulling user ETH.
    ///      - CLAIM recipient: `newKing` (user), unless the session also grants
    ///        `P_ROUTE_REIGN_CLAIM_TO_CALLER`, in which case CLAIM is routed to the bot.
    function takeoverFor(address newKing, uint256 maxPrice) external payable nonReentrant {
        if (takeoversPaused) revert Errors.TakeoversPaused();
        if (newKing == address(0)) revert Errors.ZeroAddress();

        // A king may not takeover themselves (identity-based).
        if (newKing == currentKing && currentKing != address(0)) revert Errors.NotAuthorized();

        uint256 price = getTakeoverPrice(block.timestamp);
        if (price > maxPrice) revert Errors.PriceExceeded();

        address hub = _resolveCanonicalDelegationHub();

        // Require base takeover permission.
        if (!IDelegationHub(hub).isAuthorized(newKing, msg.sender, DelegationPermissions.P_TAKEOVER_FOR)) {
            revert Errors.NotAuthorized();
        }

        // Default recipients for the new reign.
        address ethRecipient = msg.sender;
        address claimRecipient = newKing;

        // Optional: route reign-claim to the delegate (bot) instead of the king identity.
        if (IDelegationHub(hub).isAuthorized(newKing, msg.sender, DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER))
        {
            claimRecipient = msg.sender;
        }

        _executeTakeover(msg.value, price, newKing, ethRecipient, claimRecipient, msg.sender);
    }

    function withdrawKingBalance() external nonReentrant {
        _withdrawKingBalanceTo(msg.sender, msg.sender);
    }

    /// @notice Withdraw the king payout bucket to an arbitrary destination.
    /// @dev This exists because the bucket is only populated when the direct payout to the configured
    ///      recipient failed. Some recipients (smart contracts) may not be able to receive ETH directly
    ///      but can still forward it to a destination they control.
    function withdrawKingBalanceTo(address to) external nonReentrant {
        _withdrawKingBalanceTo(msg.sender, to);
    }

    /// @notice Withdraw on behalf of `user` (helper-only entrypoint).
    /// @dev Used by ClaimAllHelper so EOAs can call ClaimAllHelper directly and still withdraw their bucket.
    function withdrawKingBalanceFor(address user) external nonReentrant onlyClaimAllHelper {
        _withdrawKingBalanceTo(user, user);
    }

    function _withdrawKingBalanceTo(address user, address to) internal {
        if (user == address(0) || to == address(0)) revert Errors.ZeroAddress();

        uint256 amount = kingEthBalance[user];
        if (amount == 0) return;

        // CEI
        kingEthBalance[user] = 0;
        totalKingEthOwed -= amount;

        // Avoid "return bomb" griefing by not copying returndata.
        // If the requested `to` rejects ETH and differs from `user`, retry
        // with `user` as a liveness fallback before reverting.
        bool ok = _callWithValueNoReturndata(to, amount, gasleft());
        bool sentToOriginal = ok;
        if (!ok && to != user) {
            ok = _callWithValueNoReturndata(user, amount, gasleft());
        }
        if (!ok) revert Errors.EthTransferFailed();

        emit Events.KingWithdrawal(user, amount);
        if (sentToOriginal && to != user) {
            emit Events.KingWithdrawalTo(user, to, amount);
        }
    }

    /// @notice Withdraw any ETH owed due to a failed takeover refund.
    /// @dev Pull-payment path for the hybrid refund fallback bucket.
    function withdrawRefundBalance(address to) external nonReentrant {
        if (to == address(0)) revert Errors.ZeroAddress();

        uint256 amount = refundEthBalance[msg.sender];
        if (amount == 0) return;

        // CEI
        refundEthBalance[msg.sender] = 0;
        totalRefundEthOwed -= amount;

        // Avoid "return bomb" griefing by not copying returndata.
        bool ok = _callWithValueNoReturndata(to, amount, gasleft());
        if (!ok) revert Errors.EthTransferFailed();

        emit Events.RefundWithdrawn(msg.sender, to, amount);
    }

    function withdrawPendingClaim() external nonReentrant {
        _withdrawPendingClaimTo(msg.sender, msg.sender);
    }

    /// @notice Withdraw pending CLAIM to an arbitrary destination.
    function withdrawPendingClaimTo(address to) external nonReentrant {
        _withdrawPendingClaimTo(msg.sender, to);
    }

    function _withdrawPendingClaimTo(address user, address to) internal {
        if (to == address(0)) revert Errors.ZeroAddress();
        uint256 amount = pendingKingClaim[user];
        if (amount == 0) return;
        pendingKingClaim[user] = 0;
        totalPendingKingClaim -= amount;
        IERC20(address(claim)).safeTransfer(to, amount);
        emit Events.PendingClaimWithdrawn(user, to, amount);
    }

    // King auto-lock configuration (opt-in)

    /// @notice Configure optional auto-locking of King-stream mined CLAIM into the Furnace.
    /// @dev Off by default. When enabled, MineCore will attempt to route the dethroned King's mined CLAIM
    ///      through the Furnace (best-effort) during reign finalization.
    ///
    /// Configuration modes:
    /// - targetTokenId == 0: create-once mode. The first successful auto-lock creates a new veNFT and pins it.
    /// - targetTokenId != 0: existing lock mode. Auto-lock always tops up the chosen tokenId.
    ///
    /// @param enabled Whether the feature is enabled.
    /// @param targetTokenId Destination lock id, or 0 for create-once.
    /// @param durationSeconds Desired lock duration. When targetTokenId == 0 this MUST be within protocol bounds.
    ///        When targetTokenId != 0, 0 means "use current remaining"; otherwise it is treated as a minimum.
    /// @param createAutoMax Only meaningful when targetTokenId == 0. If true, durationSeconds MUST equal MAX_LOCK_DURATION.
    /// @param minVeOut Slippage guard passed through to Furnace. If the Furnace call would revert (e.g. veOut < minVeOut),
    ///        MineCore falls back to minting liquid CLAIM.
    function setKingAutoLockConfig(
        bool enabled,
        uint256 targetTokenId,
        uint32 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external {
        _setKingAutoLockConfig(msg.sender, enabled, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    /// @notice Delegation-gated config setter (safe, non-custodial).
    /// @dev Requires `P_SET_KING_AUTO_LOCK_CONFIG_FOR`.
    function setKingAutoLockConfigForUser(
        address user,
        bool enabled,
        uint256 targetTokenId,
        uint32 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external {
        if (user == address(0)) revert Errors.ZeroAddress();

        address hub = _resolveCanonicalDelegationHub();

        uint256 perms = DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR;
        if (!IDelegationHub(hub).isAuthorized(user, msg.sender, perms)) revert Errors.NotAuthorized();

        uint256 refId = _setKingAutoLockConfig(user, enabled, targetTokenId, durationSeconds, createAutoMax, minVeOut);
        emit Events.DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR,
            perms,
            refId,
            block.timestamp
        );
    }

    function _setKingAutoLockConfig(
        address user,
        bool enabled,
        uint256 targetTokenId,
        uint32 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) internal returns (uint256 refId) {
        KingAutoLockConfig storage cfg = kingAutoLockConfig[user];

        if (!enabled) {
            cfg.enabled = false;
            cfg.createAutoMax = false;
            cfg.durationSeconds = 0;
            cfg.targetTokenId = 0;
            cfg.pinnedTokenId = 0;
            cfg.minVeOut = 0;

            emit Events.KingAutoLockConfigured(user, false, 0, 0, 0, false, 0);
            return 0;
        }

        // Create-once mode (targetTokenId == 0)
        if (targetTokenId == 0) {
            if (durationSeconds < Constants.MIN_LOCK_DURATION || durationSeconds > Constants.MAX_LOCK_DURATION) {
                revert Errors.InvalidDuration();
            }
            if (createAutoMax && durationSeconds != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();

            cfg.enabled = true;
            cfg.targetTokenId = 0;
            cfg.durationSeconds = durationSeconds;
            cfg.createAutoMax = createAutoMax;
            // cfg.pinnedTokenId is intentionally NOT cleared in this mode.
            cfg.minVeOut = minVeOut;

            emit Events.KingAutoLockConfigured(
                user, true, 0, cfg.pinnedTokenId, durationSeconds, createAutoMax, minVeOut
            );
            return cfg.pinnedTokenId;
        }

        // Existing lock mode (targetTokenId != 0)
        if (createAutoMax) revert Errors.AutoMaxMismatch();
        if (durationSeconds != 0) {
            if (durationSeconds < Constants.MIN_LOCK_DURATION || durationSeconds > Constants.MAX_LOCK_DURATION) {
                revert Errors.InvalidDuration();
            }
        }
        MineCoreHelper(_helper).validateKingAutoLockExistingTarget(address(ve), user, targetTokenId, durationSeconds);

        cfg.enabled = true;
        cfg.targetTokenId = targetTokenId;
        // NOTE: cfg.pinnedTokenId is preserved even in existing-lock mode so users can switch back to create-once
        // without creating extra veNFTs.
        cfg.durationSeconds = durationSeconds;
        cfg.createAutoMax = false;
        cfg.minVeOut = minVeOut;

        emit Events.KingAutoLockConfigured(
            user, true, targetTokenId, cfg.pinnedTokenId, durationSeconds, false, minVeOut
        );
        return targetTokenId;
    }

    /// @notice View helper: read a user's King auto-lock config.
    function getKingAutoLockConfig(address user)
        external
        view
        returns (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        )
    {
        KingAutoLockConfig storage cfg = kingAutoLockConfig[user];
        enabled = cfg.enabled;
        targetTokenId = cfg.targetTokenId;
        pinnedTokenId = cfg.pinnedTokenId;
        durationSeconds = cfg.durationSeconds;
        createAutoMax = cfg.createAutoMax;
        minVeOut = cfg.minVeOut;
    }

    // Reign indexing

    function _appendKingReign(address king, uint256 reignId) internal {
        kingReigns[king].push(reignId);
    }

    // --- King auto-lock execution (opt-in, best-effort) ---

    // Minimum gasleft() required to enter the auto-lock branch. Below this threshold we
    // short-circuit to the liquid-CLAIM path so the catch block and the rest of
    // _executeTakeover are guaranteed enough budget to finalize.
    //
    // Sized above the measured cost of the full auto-lock branch
    // (Furnace.enterWithClaimFor + veNFT mint + _pinShareholderObservedMin hook +
    // _tryRoyaltiesTakeover tail + new-reign SSTOREs) plus a 10% headroom margin
    // pinned by `MineCore_GasEstimationTrap.t.sol::testMeasuredEnterBudgetRetainsTenPercentHeadroom`.
    uint256 internal constant SETTLE_CLAIM_MIN_GAS = 1_300_000;

    // Gas retained for the `catch` block and the remainder of _executeTakeover (new-reign
    // state writes, ReignRecipientsSet / Takeover / DelegationSessionUsed events, _hybridRefund).
    // Subtracted from gasleft() when forwarding to Furnace.enterWithClaimFor so the outer
    // takeover always has budget to finalize regardless of sub-call outcome.
    uint256 internal constant SETTLE_CLAIM_ENTER_RESERVE_GAS = 500_000;

    function _settlePrevKingClaim(uint256 reignId, address king, uint256 claimAmount) internal {
        if (claimAmount == 0) return;

        KingAutoLockConfig storage cfg = kingAutoLockConfig[king];

        // Gas pre-check — ensure the catch block will have adequate budget for cleanup.
        if (cfg.enabled && gasleft() < SETTLE_CLAIM_MIN_GAS) {
            _mintClaimToKingOrCredit(king, claimAmount);
            emit Events.KingAutoLockSkipped(reignId, king, claimAmount, 0xFF);
            return;
        }

        // Default (disabled) path: mint liquid CLAIM to the dethroned king.
        if (!cfg.enabled) {
            _mintClaimToKingOrCredit(king, claimAmount);
            return;
        }

        // Resolve destination (including pinned lock) and compute an effective duration for existing locks.
        uint256 preResolvedTokenId = cfg.targetTokenId;
        if (preResolvedTokenId == 0 && cfg.pinnedTokenId != 0) preResolvedTokenId = cfg.pinnedTokenId;
        (bool ok, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint8 reasonCode) = MineCoreHelper(
                _helper
            )
            .resolveKingAutoLockDestination(
                address(ve), king, preResolvedTokenId, cfg.durationSeconds, cfg.createAutoMax
            );

        // If destination is invalid/unusable, do NOT create extra veNFTs. Fall back to liquid CLAIM.
        if (!ok) {
            // slither-disable-next-line reentrancy-no-eth
            _mintClaimToKingOrCredit(king, claimAmount);
            // Clear stale pinnedTokenId when the pinned lock is no longer usable.
            // All failure reason codes (NOT_OWNER, LISTED, EXPIRED, INVALID_TOKEN_ID)
            // indicate the pin is unusable — clear unconditionally.
            if (cfg.targetTokenId == 0 && cfg.pinnedTokenId != 0) {
                cfg.pinnedTokenId = 0;
            }
            emit Events.KingAutoLockSkipped(reignId, king, claimAmount, reasonCode);
            return;
        }

        IFurnace f = furnace;
        address furnaceAddr = address(f);

        // Defensive: keep king auto-lock fail-closed before touching any CLAIM if the live Furnace
        // wiring is stale or foreign during the pre-freeze window. Otherwise MineCore can mint
        // CLAIM to itself, approve a wrong Furnace, and let that contract pull the dethroned king
        // payout without minting the intended ve lock.
        if (furnaceAddr == address(0)) {
            _mintClaimToKingOrCredit(king, claimAmount);
            emit Events.KingAutoLockFailed(
                reignId, king, claimAmount, abi.encodeWithSelector(Errors.ZeroAddress.selector)
            );
            return;
        }
        if (!_isReciprocallyWiredFurnace(furnaceAddr)) {
            _mintClaimToKingOrCredit(king, claimAmount);
            emit Events.KingAutoLockFailed(
                reignId, king, claimAmount, abi.encodeWithSelector(Errors.WiringMismatch.selector)
            );
            return;
        }

        // Mint CLAIM to MineCore and route through the canonical Furnace entry flow.
        // slither-disable-next-line reentrancy-no-eth
        claim.mint(address(this), claimAmount);
        _forceApprove(IERC20(address(claim)), furnaceAddr, claimAmount);

        // `Furnace.enter*` requires `minVeOut > 0`. Treat 0 as a sentinel meaning "no floor" and clamp
        // to 1 to preserve best-effort auto-lock behavior without allowing dust locks that mint 0 ve.
        uint256 minVeOut = cfg.minVeOut;
        if (minVeOut == 0) minVeOut = 1;

        // Forward gasleft() minus SETTLE_CLAIM_ENTER_RESERVE_GAS to Furnace.enterWithClaimFor
        // so the catch block and the remainder of _executeTakeover (new-reign SSTOREs, events,
        // hybrid refund) always have budget to finalize.
        uint256 _gasLeft = gasleft();
        uint256 gasForEnter = _gasLeft > SETTLE_CLAIM_ENTER_RESERVE_GAS ? _gasLeft - SETTLE_CLAIM_ENTER_RESERVE_GAS : 0;

        try f.enterWithClaimFor{gas: gasForEnter}(
            king, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut
        ) returns (
            uint256 tokenIdUsed
        ) {
            // Best-effort reset: must not revert so the successful lock is not lost.
            _bestEffortResetApproval(IERC20(address(claim)), furnaceAddr);

            // In create-once mode, pin the first successfully created veNFT.
            if (cfg.targetTokenId == 0 && cfg.pinnedTokenId == 0) {
                cfg.pinnedTokenId = tokenIdUsed;
            }

            emit Events.KingAutoLockExecuted(reignId, king, claimAmount, tokenIdUsed);
        } catch {
            // In create-once mode, clear a stale pin so the next reign doesn't reuse
            // a lock that may no longer be owned or usable by the new king.
            if (cfg.targetTokenId == 0) {
                cfg.pinnedTokenId = 0;
            }

            bytes memory bounded = _boundedRevertData();

            // Best-effort reset: must not revert so takeover is not bricked by approve failure.
            _bestEffortResetApproval(IERC20(address(claim)), furnaceAddr);

            // Use hardened SafeTransfer.callTransfer (return-data-bomb safe) instead
            // of raw IERC20.transfer inside try/catch. Handles non-standard ERC20
            // returns (no-return, bool, short) consistently with the rest of the
            // codebase and avoids the subtle difference between transfer-returns-false
            // and transfer-reverts in the fallback accounting.
            if (!SafeTransfer.callTransfer(IERC20(address(claim)), king, claimAmount)) {
                pendingKingClaim[king] += claimAmount;
                totalPendingKingClaim += claimAmount;
                emit Events.KingClaimCredited(king, claimAmount);
            }

            emit Events.KingAutoLockFailed(reignId, king, claimAmount, bounded);
        }
    }

    /// @dev Mint CLAIM to self, then try transfer to recipient.
    ///      On failure, credit pendingKingClaim for pull-payment withdrawal.
    ///      Ensures a reverting recipient can never brick takeovers.
    function _mintClaimToKingOrCredit(address recipient, uint256 amount) internal {
        claim.mint(address(this), amount);
        if (!SafeTransfer.callTransfer(IERC20(address(claim)), recipient, amount)) {
            pendingKingClaim[recipient] += amount;
            totalPendingKingClaim += amount;
            emit Events.KingClaimCredited(recipient, amount);
        }
    }

    /// @notice Permissionless ve global checkpoint advancement.
    /// @dev Decouples ve catchup from takeover liveness. If the ve system accumulates too many
    ///      pending slope changes during a long pause, anyone may advance the ve checkpoint across
    ///      transactions until `globalLastTs` reaches `block.timestamp`; otherwise takeovers can
    ///      brick once the slope-change backlog exceeds single-block gas capacity.
    ///
    ///      MineCore uses the same checkpointing helper before reign finalization (SPEC §5.4.2 and §2.7).
    ///      Do not add a fixed per-takeover iteration cap here: VeClaimNFT already caps work per
    ///      `checkpointGlobalState()` call, so MineCore should keep advancing until caught up,
    ///      gas is low, or the ve contract stops making forward progress.
    function advanceVeCheckpoint() external nonReentrant {
        uint256 nowTs = block.timestamp;
        uint256 before = ve.globalLastTs();

        _checkpointVeForTakeover(nowTs);

        if (ve.globalLastTs() <= before && before != nowTs) {
            revert Errors.VeCheckpointStale();
        }
    }

    function _checkpointVeForTakeover(uint256 nowTs) internal {
        uint256 last = ve.globalLastTs();

        while (true) {
            // Stop when caught up or gas is low.
            if (last == nowTs) break;
            if (gasleft() < CHECKPOINT_GAS_GUARD) break;

            ve.checkpointGlobalState();

            uint256 afterTs = ve.globalLastTs();

            // Stop if no forward progress was made, or if the ve contract reported
            // an invalid future timestamp. _requireFreshVeCheckpoint() will fail closed.
            if (afterTs <= last || afterTs > nowTs) break;
            last = afterTs;
        }

        // NOTE: checkpointGlobalState() and checkpointTotalVe() share the same
        // internal implementation (_checkpointGlobalStateInternal) which always
        // ends with _syncTotalVeCached().  No separate checkpointTotalVe() call
        // is needed -- the loop above already synced the cache on every iteration.
    }

    /// @dev Fail closed when the ve system is still pinned behind the current block timestamp.
    ///      ShareholderRoyalties defers indexing in that state, which would otherwise let later
    ///      entrants dilute takeover ETH that was generated before they became shareholders.
    function _requireFreshVeCheckpoint(uint256 nowTs) internal view {
        if (ve.globalLastTs() != nowTs) revert Errors.VeCheckpointStale();
    }

    /// @dev Deterministic takeover sequence per SPEC §5.4.2.
    function _executeTakeover(
        uint256 creditedEth,
        uint256 pricePaid,
        address newKing,
        address newReignEthRecipient,
        address newReignClaimRecipient,
        address refundTo
    ) internal {
        // Defensive: reject any attempt to install a protocol-owned address as king
        // or payout recipient. Without this, a user typo that points a recipient at
        // one of the protocol's own helper / registry contracts would permanently
        // strand the associated ETH (no `receive()` and/or no withdrawal path for
        // those addresses). Consolidated here so the eight protocol addresses
        // (this, claim, ve, royalties, furnace, _helper, claimAllHelper,
        // delegationHub) are always kept in sync with every takeover entrypoint.
        _rejectProtocolAddressAsRecipient(newKing);
        _rejectProtocolAddressAsRecipient(newReignEthRecipient);
        _rejectProtocolAddressAsRecipient(newReignClaimRecipient);
        _rejectProtocolAddressAsRecipient(refundTo);

        // slither-disable-start reentrancy-eth
        // Public takeover entrypoints are `nonReentrant`. Ordering follows SPEC §5.4.2: external calls
        // to VeClaimNFT / ClaimToken / royalties settle the prior reign before writing new reign state.
        // Snapshot prior state.
        address prevKing = currentKing;
        uint256 prevReignId = currentReignId;
        uint256 nowTs = block.timestamp;

        if (newKing == address(0) || newReignEthRecipient == address(0) || newReignClaimRecipient == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (refundTo == address(0)) revert Errors.ZeroAddress();
        if (creditedEth == 0) revert Errors.AmountZero();

        // 1) Gas-guarded ve checkpointing.
        _checkpointVeForTakeover(nowTs);
        _requireFreshVeCheckpoint(nowTs);

        // 2) Validate price (already computed by caller; reuse to avoid redundant external call).
        if (creditedEth < pricePaid) revert Errors.InsufficientEthBalance();

        // No economic cap — theoretically unbounded but decays to floor in 1h.
        // 3) Accrue emissions since last accrual.
        uint256 claimMinedToPrevKing = 0;
        {
            IFurnace f = furnace;
            address furnaceAddr = address(f);
            if (furnaceAddr == address(0)) revert Errors.ZeroAddress();
            if (!_isReciprocallyWiredFurnace(furnaceAddr)) revert Errors.WiringMismatch();

            uint256 accrualStart = currentReignLastAccrualTime;

            if (prevKing != address(0)) {
                claimMinedToPrevKing = _kingEmitted(accrualStart, nowTs);
            }

            uint256 furnaceMined = _furnaceEmitted(accrualStart, nowTs);
            if (furnaceMined != 0) {
                claim.mint(address(f), furnaceMined);

                // Fail closed: direct CLAIM transfers to Furnace MUST NOT become live reserve.
                // If the reserve credit cannot be recorded atomically with the mint, revert the
                // takeover so the minted CLAIM is rolled back instead of becoming a permanently
                // unaccounted Furnace surplus.
                try f.creditReserve(furnaceMined) {}
                catch {
                    revert Errors.InvariantViolation();
                }
            }
        }

        // 4) Finalize previous reign (or apply genesis allocation).
        if (prevKing != address(0)) {
            // Snapshot total ve for historical accounting (not a distribution divisor).
            // Freshness: _checkpointVeForTakeover() (step 1) already caught up globalLastTs
            // via checkpointGlobalState(), which shares the same internal implementation as
            // checkpointTotalVe() and always ends with _syncTotalVeCached().
            // Nothing between step 1 and here mutates VeClaimNFT state.
            totalVeForReign[prevReignId] = ve.totalVeCached();

            // Split ETH: 75% to dethroned king, 25% to shareholders.
            uint256 kingShare = (pricePaid * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
            uint256 shareholderShare = pricePaid - kingShare;

            // Resolve recipients for the previous reign (fallback to king identity if unset).
            address prevEthRecipient = reignEthRecipient[prevReignId];
            if (prevEthRecipient == address(0)) prevEthRecipient = prevKing;

            address prevClaimRecipient = reignClaimRecipient[prevReignId];
            if (prevClaimRecipient == address(0)) prevClaimRecipient = prevKing;

            // Persist reign finalization metadata.
            ReignInfo storage prev = reignInfo[prevReignId];
            prev.endTime = nowTs;
            prev.totalClaimMined = claimMinedToPrevKing;
            prev.totalEthToKing = kingShare;

            // Best-effort push payout to the previous King's configured ETH recipient.
            // Failure MUST NOT revert takeover; instead, credit a withdrawable balance bucket
            // keyed by prevEthRecipient (NOT prevKing).
            bool paid = _callWithValueNoReturndata(prevEthRecipient, kingShare, KING_PAYOUT_GAS_STIPEND);
            if (paid) {
                emit Events.KingEthPaid(prevEthRecipient, kingShare);
            } else {
                kingEthBalance[prevEthRecipient] += kingShare;
                totalKingEthOwed += kingShare;
                emit Events.KingEthCredited(prevEthRecipient, kingShare);
            }

            _tryRoyaltiesTakeover(prevReignId, shareholderShare);

            emit Events.ReignFinalized(prevReignId, prevKing, prev.startTime, nowTs, claimMinedToPrevKing, kingShare);

            // Settle King-stream CLAIM:
            // - If claim recipient is the king identity, apply the king's auto-lock config (best-effort).
            // - Otherwise, bypass auto-lock and mint liquid CLAIM to the configured recipient.
            if (prevClaimRecipient == prevKing) {
                _settlePrevKingClaim(prevReignId, prevKing, claimMinedToPrevKing);
            } else if (claimMinedToPrevKing != 0) {
                _mintClaimToKingOrCredit(prevClaimRecipient, claimMinedToPrevKing);
            }
        } else {
            // Genesis rule: 100% of takeover ETH to shareholders, and onTakeover uses reignId=0.
            _tryRoyaltiesTakeover(0, pricePaid);
        }

        // 5) Start new reign.
        uint256 newReignId = prevReignId + 1;
        // Reference price = 2x price paid. Next takeover decays from this to TAKEOVER_PRICE_FLOOR over 1 hour.
        uint256 newReferencePrice = pricePaid <= type(uint256).max / 2 ? pricePaid * 2 : type(uint256).max;

        currentReignId = newReignId;
        currentKing = newKing;
        currentReignStartTime = nowTs;
        currentReignLastAccrualTime = nowTs;
        referencePrice = newReferencePrice;

        // Persist routing configuration for this reign.
        reignEthRecipient[newReignId] = newReignEthRecipient;
        reignClaimRecipient[newReignId] = newReignClaimRecipient;
        emit Events.ReignRecipientsSet(newReignId, newKing, newReignEthRecipient, newReignClaimRecipient);

        ReignInfo storage r = reignInfo[newReignId];
        r.king = newKing;
        r.startTime = nowTs;
        r.endTime = 0;
        r.pricePaid = pricePaid;
        r.referencePrice = newReferencePrice;
        r.totalClaimMined = 0;
        r.totalEthToKing = 0;

        _appendKingReign(newKing, newReignId);

        emit Events.Takeover(newReignId, prevKing, newKing, pricePaid, newReferencePrice, nowTs);

        // Delegation session usage tracking.
        // If the king identity differs from the payer/refund address, this takeover was executed via the
        // delegated `takeoverFor` entrypoint.
        if (newKing != refundTo) {
            uint256 permsUsed = DelegationPermissions.P_TAKEOVER_FOR;
            if (newReignClaimRecipient == refundTo) {
                permsUsed |= DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER;
            }

            emit Events.DelegationSessionUsed(
                newKing, refundTo, DelegationActionTypes.TAKEOVER_FOR, permsUsed, newReignId, nowTs
            );
        }

        // 6) Hybrid refund: try to send refund, else credit refund bucket.
        _hybridRefund(refundTo, creditedEth - pricePaid);
        // slither-disable-end reentrancy-eth
    }

    /// @dev Reject any of MineCore's protocol-owned addresses as a king / recipient / refundTo.
    ///      The eight protocol contracts covered are:
    ///        - `address(this)`       — MineCore self (would lock funds inside MineCore)
    ///        - `address(claim)`      — ClaimToken (would mix ERC20 balance with king balance)
    ///        - `address(ve)`         — VeClaimNFT (would mix NFT contract state with king)
    ///        - `address(royalties)`  — ShareholderRoyalties (would confuse shareholder flows)
    ///        - `address(furnace)`    — Furnace (rejected by its own `validateReceiveEth` guard)
    ///        - `_helper`             — MineCoreHelper stateless view contract (no receive, no withdraw path)
    ///        - `claimAllHelper`      — ClaimAllHelper privileged batcher (no forward-ETH logic)
    ///        - `delegationHub`       — DelegationHub session registry (no receive, no withdraw path)
    function _rejectProtocolAddressAsRecipient(address a) internal view {
        if (
            a == address(this) || a == address(claim) || a == address(ve) || a == address(royalties)
                || a == address(furnace) || a == _helper || a == claimAllHelper || a == delegationHub
        ) {
            revert Errors.NotAuthorized();
        }
    }

    /// @dev Best-effort royalties: wrap onTakeover + flush in try/catch so takeover never reverts on royalty failure.
    function _tryRoyaltiesTakeover(uint256 reignId, uint256 amountEth) internal {
        if (amountEth == 0) return;

        try royalties.onTakeover{value: amountEth}(reignId) {
            try royalties.flushPendingShareholderETH() {
            // success
            }
            catch {
                emit Events.ShareholderRoyaltiesFlushFailed(_boundedRevertData());
            }
        } catch {
            bytes memory bounded = _boundedRevertData();
            shareholderEthPending += amountEth;
            emit Events.ShareholderRoyaltiesTakeoverFailed(reignId, amountEth, bounded);
        }
    }

    /// @notice Retry pushing shareholder ETH from the pending bucket to royalties.
    /// @dev Call when royalties/ve are healthy and the ve checkpoint has caught up after a
    ///      ShareholderRoyaltiesTakeoverFailed event.
    ///      Uses reignId=0 because the pending bucket aggregates across multiple
    ///      failed takeovers — individual reign association is intentionally lost on aggregation.
    function retryPushShareholderEth() external nonReentrant {
        if (takeoversPaused) revert Errors.TakeoversPaused();
        if (block.timestamp < lastShareholderRetryTs + 300) revert Errors.CadenceNotMet();
        uint256 pending = shareholderEthPending;
        if (pending == 0) return;

        uint256 nowTs = block.timestamp;
        lastShareholderRetryTs = nowTs;
        // slither-disable-next-line reentrancy-no-eth
        _checkpointVeForTakeover(nowTs);
        _requireFreshVeCheckpoint(nowTs);

        // CEI: clear before interaction; restore on failure.
        shareholderEthPending = 0;

        // Slither false-positive: function is nonReentrant and restores pending state on failure.
        // slither-disable-next-line reentrancy-eth
        try royalties.addPendingShareholderETH{value: pending}(0) {
            try royalties.flushPendingShareholderETH() {
            // success
            }
            catch {
                emit Events.ShareholderRoyaltiesFlushFailed(_boundedRevertData());
            }
        } catch {
            bytes memory bounded = _boundedRevertData();
            shareholderEthPending = pending;
            emit Events.ShareholderRoyaltiesTakeoverFailed(0, pending, bounded);
        }
    }

    /// @notice Update the active reign's payout recipients.
    /// @dev Callable by the current king identity.
    ///      Delegates require an active DelegationHub session with:
    ///      - one of {P_SET_REIGN_ETH_RECIPIENT, P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY} to change `ethRecipient`
    ///      - one of {P_SET_REIGN_CLAIM_RECIPIENT, P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY} to change `claimRecipient`
    function setCurrentReignRecipients(address ethRecipient, address claimRecipient) external nonReentrant {
        address king = currentKing;
        if (king == address(0)) revert Errors.NotAuthorized();
        if (ethRecipient == address(0) || claimRecipient == address(0)) revert Errors.ZeroAddress();
        _rejectProtocolAddressAsRecipient(ethRecipient);
        _rejectProtocolAddressAsRecipient(claimRecipient);

        uint256 reignId = currentReignId;
        uint256 delegatedPermsUsed = 0;

        address currentEth = reignEthRecipient[reignId];
        address currentClaim = reignClaimRecipient[reignId];

        // Authorization runs before the no-op short-circuit so a non-king
        // caller passing the current pair cannot succeed without proving
        // authority. The auth outcome (`delegatedPermsUsed`) drives the
        // `DelegationSessionUsed` emission for indexers when the call is
        // delegated.
        if (msg.sender != king) {
            address hub = _resolveCanonicalDelegationHub();

            if (ethRecipient != currentEth) {
                uint256 broadPerm = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT;
                if (IDelegationHub(hub).isAuthorized(king, msg.sender, broadPerm)) {
                    delegatedPermsUsed |= broadPerm;
                } else {
                    uint256 scopedPerm = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY;
                    if (ethRecipient != msg.sender || !IDelegationHub(hub).isAuthorized(king, msg.sender, scopedPerm)) {
                        revert Errors.NotAuthorized();
                    }
                    delegatedPermsUsed |= scopedPerm;
                }
            }

            if (claimRecipient != currentClaim) {
                uint256 broadPerm = DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT;
                if (IDelegationHub(hub).isAuthorized(king, msg.sender, broadPerm)) {
                    delegatedPermsUsed |= broadPerm;
                } else {
                    uint256 scopedPerm = DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;
                    if (claimRecipient != king || !IDelegationHub(hub).isAuthorized(king, msg.sender, scopedPerm)) {
                        revert Errors.NotAuthorized();
                    }
                    delegatedPermsUsed |= scopedPerm;
                }
            }

            // Both sides equal current: require at least one delegated
            // authority bit so a successful return implies recipient-control
            // rights. A non-king caller passing the current pair without any
            // active session reverts here instead of silently succeeding.
            if (delegatedPermsUsed == 0) revert Errors.NotAuthorized();
        }

        // No-op guard runs AFTER authorization so an unauthorized caller cannot
        // use the current-pair short-circuit to dodge the auth branch above.
        if (ethRecipient == currentEth && claimRecipient == currentClaim) return;

        reignEthRecipient[reignId] = ethRecipient;
        reignClaimRecipient[reignId] = claimRecipient;

        emit Events.ReignRecipientsSet(reignId, king, ethRecipient, claimRecipient);

        if (delegatedPermsUsed != 0) {
            emit Events.DelegationSessionUsed(
                king,
                msg.sender,
                DelegationActionTypes.MINECORE_SET_REIGN_RECIPIENTS,
                delegatedPermsUsed,
                reignId,
                block.timestamp
            );
        }
    }

    /// @dev Low-level ETH call that does not copy returndata (prevents "return bomb" griefing).
    function _callWithValueNoReturndata(address to, uint256 value, uint256 gasAmount) internal returns (bool ok) {
        if (value == 0) return true;
        // buffer. Never copies returndata into Solidity memory.
        assembly ("memory-safe") {
            ok := call(gasAmount, to, value, 0, 0, 0, 0)
        }
    }

    /// @dev Capture up to 128 bytes of the most recent revert data without expanding
    ///      arbitrary returndata into Solidity memory (MemoryOOG-safe).
    ///      MUST be called inside a catch block before any subsequent external call
    ///      overwrites the returndata buffer.
    function _boundedRevertData() internal pure returns (bytes memory bounded) {
        assembly ("memory-safe") {
            let rdSize := returndatasize()
            let copyLen := rdSize
            if gt(copyLen, 128) { copyLen := 128 }
            bounded := mload(0x40)
            mstore(bounded, copyLen)
            returndatacopy(add(bounded, 0x20), 0, copyLen)
            mstore(0x40, add(add(bounded, 0x20), and(add(copyLen, 31), not(31))))
        }
    }

    function _hybridRefund(address to, uint256 amount) internal {
        if (amount == 0) return;

        // CEI: credit the pull-payment bucket first so state is consistent
        // before any external interaction.
        refundEthBalance[to] += amount;
        totalRefundEthOwed += amount;

        bool ok = _callWithValueNoReturndata(to, amount, REFUND_GAS_STIPEND);
        if (ok) {
            refundEthBalance[to] -= amount;
            totalRefundEthOwed -= amount;
        } else {
            emit Events.RefundCredited(to, amount);
        }
    }

    /// @dev Resolve and validate the EntryTokenRegistry router config used for token takeovers.
    ///      This hardens against freezing/miswiring a registry that has not been initialized.
    function _requireRegistryAndRouterConfig()
        internal
        view
        returns (IEntryTokenRegistry reg, address router, address factory, address wrappedNative)
    {
        address regAddr = entryTokenRegistry;
        (router, factory, wrappedNative) = MineCoreHelper(_helper).getValidatedRouterConfig(regAddr, address(claim));
        reg = IEntryTokenRegistry(regAddr);
    }

    /// @dev Swap a takeover entry token into native ETH via the allowlisted token->WETH pool.
    function _swapTokenToEth(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 deadline)
        internal
        returns (uint256 ethOut)
    {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (amountIn == 0) revert Errors.AmountZero();
        if (minEthOut == 0) revert Errors.AmountZero();
        if (tokenIn == address(claim)) revert Errors.InvalidToken();

        (IEntryTokenRegistry reg, address router, address factory, address wrappedNative) =
            _requireRegistryAndRouterConfig();

        // Special-case: tokenIn is wrapped native (WETH). No registry route is required.
        // Unwrap 1:1 and treat the result as native ETH.
        if (tokenIn == wrappedNative) {
            if (!SafeTransfer.callTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn)) {
                revert Errors.TransferFailed();
            }

            uint256 ethBalBefore = address(this).balance;
            IWETH(wrappedNative).withdraw(amountIn);
            ethOut = address(this).balance - ethBalBefore;
            if (ethOut < minEthOut) revert Errors.MinEthOutNotMet();
            return ethOut;
        }

        IEntryTokenRegistry.RegistryRoute[] memory regRoutes = reg.resolveTakeoverRoute(tokenIn);
        if (regRoutes.length != 1) revert Errors.InvalidToken();

        IEntryTokenRegistry.RegistryRoute memory r = regRoutes[0];
        if (r.tokenIn != tokenIn || r.tokenOut != wrappedNative) revert Errors.InvalidToken();

        if (IDexAdapter(router).poolFor(r.tokenIn, r.tokenOut, r.stable, factory) != r.pool) {
            revert Errors.InvalidPool();
        }

        _pullTokenWithFoTCheck(tokenIn, amountIn);
        _forceApprove(IERC20(tokenIn), router, amountIn);

        IDexAdapter.Route[] memory dexRoutes = new IDexAdapter.Route[](1);
        dexRoutes[0] = IDexAdapter.Route({from: r.tokenIn, to: r.tokenOut, stable: r.stable, factory: factory});

        uint256 wethReceived = _swapAndMeasureWeth(wrappedNative, router, amountIn, minEthOut, dexRoutes, deadline);
        _clearRouterApproval(tokenIn, router);

        // Unwrap WETH to native ETH — verify actual balance change for defense-in-depth.
        uint256 ethBefore = address(this).balance;
        IWETH(wrappedNative).withdraw(wethReceived);
        ethOut = address(this).balance - ethBefore;
        if (ethOut < minEthOut) revert Errors.MinEthOutNotMet();
    }

    /// @dev Clear router approval (helper to avoid stack-too-deep in _swapTokenToEth).
    function _clearRouterApproval(address token, address router) internal {
        _forceApprove(IERC20(token), router, 0);
    }

    /// @dev Pull tokens from sender and revert if fee-on-transfer reduces the amount.
    function _pullTokenWithFoTCheck(address tokenIn, uint256 amountIn) internal {
        (uint256 balBefore, bool ok1) = SafeERC20View.callBalanceOf(IERC20(tokenIn), address(this));
        if (!ok1) revert Errors.TransferFailed();
        if (!SafeTransfer.callTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn)) {
            revert Errors.TransferFailed();
        }
        (uint256 balAfter, bool ok2) = SafeERC20View.callBalanceOf(IERC20(tokenIn), address(this));
        if (!ok2) revert Errors.TransferFailed();
        if (balAfter - balBefore < amountIn) revert Errors.TransferFailed();
    }

    /// @dev Measure WETH received from a DEX swap (helper to avoid stack-too-deep).
    function _swapAndMeasureWeth(
        address weth,
        address router,
        uint256 amountIn,
        uint256 minOut,
        IDexAdapter.Route[] memory routes,
        uint256 deadline
    ) internal returns (uint256) {
        (uint256 before, bool ok1) = SafeERC20View.callBalanceOf(IERC20(weth), address(this));
        if (!ok1) revert Errors.TransferFailed();
        IDexAdapter(router).swapExactTokensForTokens(amountIn, minOut, routes, address(this), deadline);
        (uint256 after_, bool ok2) = SafeERC20View.callBalanceOf(IERC20(weth), address(this));
        if (!ok2) revert Errors.TransferFailed();
        if (after_ < before) revert Errors.InvariantViolation();
        return after_ - before;
    }

    // Equivalent in intent to OZ `forceApprove`, implemented via `SafeApprove`
    // + allowance read helper to avoid return-data bomb vectors.
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

    /// @dev Best-effort approval reset that never reverts.  Used inside _settlePrevKingClaim
    ///      success/catch paths where a revert would cascade and brick takeovers.
    function _bestEffortResetApproval(IERC20 token, address spender) internal {
        // SafeApprove.callApprove returns false on failure but does not revert.
        // Intentionally ignoring the return value: defense-in-depth cleanup only.
        SafeApprove.callApprove(token, spender, 0);
    }

    /// @notice Current Furnace emission rate (CLAIM/sec) at `block.timestamp`.
    function getCurrentFurnaceEmissionRate() external view returns (uint256) {
        return getFurnaceEmissionRateAt(block.timestamp);
    }

    /// @notice Deterministic Furnace emission rate (CLAIM/sec) at an arbitrary timestamp.
    /// @dev Mirrors the King emission decay schedule with Furnace-specific rates.
    function getFurnaceEmissionRateAt(uint256 timestamp) public view returns (uint256 rate) {
        return MineCoreHelper(_helper).getFurnaceEmissionRateAt(emissionStartTime, timestamp);
    }

    /// @dev Deterministic integral per SPEC §5.4.3 (linear decay to floor).
    function _kingEmitted(uint256 ts0, uint256 ts1) internal view returns (uint256 emitted) {
        return MineCoreHelper(_helper).kingEmitted(emissionStartTime, ts0, ts1);
    }

    /// @dev Deterministic integral per SPEC §5.4.3 (linear decay to floor) for the Furnace stream.
    function _furnaceEmitted(uint256 ts0, uint256 ts1) internal view returns (uint256 emitted) {
        return MineCoreHelper(_helper).furnaceEmitted(emissionStartTime, ts0, ts1);
    }
}
