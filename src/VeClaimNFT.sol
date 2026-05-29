// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {Constants} from "./lib/Constants.sol";
import {IShareholderRoyalties} from "./interfaces/IShareholderRoyalties.sol";
import {IDelegationHub} from "./interfaces/IDelegationHub.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "./lib/DelegationActionTypes.sol";

/// @notice veCLAIM ERC721 locks with 1-year max duration, linear decay.
/// @dev Fully implemented lock storage, ve math, checkpointing, and guarded transfer semantics per SPEC.
///      INVARIANT: claimToken MUST be a standard ERC-20 without fee-on-transfer, rebasing,
///      or transfer-hook side-effects.  Violation breaks _totalLockedClaim accounting permanently.
contract VeClaimNFT is ERC721, ReentrancyGuard, Ownable2Step, IVeClaimNFT {
    using SafeERC20 for IERC20;

    address public immutable claimToken;

    // Freeze (one-way config lock for core game-rule wiring)
    bool public configFrozen;

    /// @notice Optional one-way freeze for NFT metadata URIs.
    /// @dev Independent of `configFrozen`: metadata setters remain owner-callable after a config
    ///      freeze so URIs can still track indexer/CDN moves. Calling `freezeMetadata()` is the
    ///      separate, permanent lockdown of `setBaseURI` and `setContractURI`.
    bool public metadataFrozen;

    // Wiring (locked after freeze)
    address public mineMarket; // the only allowed transferer (besides mint/burn)
    address public furnace; // only allowed caller for createLockFor, addToLockFor, extendLockToFor, mergeLocksFor, and furnaceBurnAndWithdraw
    // ERC-721 metadata URIs (settable by owner post-deploy)
    string private _baseTokenURI;
    string private _contractTokenURI;

    // Aggregate caches updated by lock mutations and global checkpointing
    uint256 internal _totalLockedClaim;
    uint256 internal _totalVeCached;

    // ---- ve math + lock storage (SPEC §4) ----

    /// @dev Global slope/bias use a fixed-point slopeScale so global aggregates remain conservative.
    ///      See the math and rounding appendix.
    uint256 internal constant SLOPE_SCALE = 1e18;

    struct Lock {
        uint256 amount; // CLAIM principal (and locked bonus) for this token
        uint256 lockStart; // last mutation timestamp (metadata + AutoMax accrual floor)
        uint256 lockEnd; // unlock timestamp
        bool autoMax;
        bool listed;
    }

    mapping(uint256 => Lock) internal _locks;

    // Token id generation (starts at 1)
    uint256 internal _nextTokenId = 1;

    // Owner enumeration (O(1) add/remove) used by veBalanceOf
    mapping(address => uint256[]) internal _ownedTokens;
    mapping(uint256 => uint256) internal _ownedTokensIndex;

    // Global checkpointing state
    uint256 internal _globalSlopeScaled;
    uint256 internal _globalBiasScaled;
    uint256 internal _globalLastTs;

    // Scheduled slope removals at lockEnd (scaled).
    mapping(uint256 => uint256) internal _slopeChanges;

    // Min-heap of timestamps that have non-zero _slopeChanges (ascending).
    // 1-indexed heap: index 0 is unused.
    uint256[] internal _slopeTimeHeap;
    mapping(uint256 => uint256) internal _slopeTimeIndex;

    modifier whenNotFrozen() {
        if (configFrozen) revert Errors.ConfigFrozen();
        _;
    }

    modifier whenMetadataNotFrozen() {
        if (metadataFrozen) revert Errors.MetadataFrozen();
        _;
    }

    modifier onlyFurnace() {
        _requireCanonicalFurnaceCaller();
        _;
    }

    /// @dev Resolve the canonical MineCore through the live Furnace surface.
    ///      This MUST NOT be optional on hot mutation paths: a foreign Furnace-like contract can
    ///      simply omit `mineCore()` to bypass "optional" reciprocal checks while still spoofing
    ///      the direct `ve()/claim()/mineMarket()` getters. Require the live Furnace to expose a
    ///      real MineCore root that points back to this exact Furnace + ve + CLAIM bundle.
    function _requireCanonicalMineCoreThroughFurnace(address f) internal view returns (address core) {
        core = _staticcallAddress(f, _SEL_MINE_CORE);
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();
        if (_staticcallAddress(claimToken, _SEL_MINE_CORE) != core) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(core, _SEL_VE) != address(this) || _staticcallAddress(core, _SEL_CLAIM) != claimToken
                || _staticcallAddress(core, _SEL_FURNACE) != f
        ) {
            revert Errors.WiringMismatch();
        }
    }

    /// @dev Furnace-only ve mutators must not trust the raw `furnace` pointer in isolation.
    ///      If `VeClaimNFT.furnace` drifts stale pre-freeze, a foreign Furnace-like contract can:
    ///      - extend an existing user lock at zero cost,
    ///      - create a new lock for a victim, or
    ///      - top up an existing user lock,
    ///      using only its own CLAIM balance. Require the live Furnace surface to still belong to
    ///      the same canonical MineCore/Market/royalties roots before allowing those mutations.
    function _requireCanonicalFurnaceCaller() internal view {
        address f = furnace;
        if (msg.sender != f) revert Errors.NotAuthorized();
        if (f == address(0) || f.code.length == 0) revert Errors.WiringMismatch();

        if (_staticcallAddress(f, _SEL_VE) != address(this) || _staticcallAddress(f, _SEL_CLAIM) != claimToken) {
            revert Errors.WiringMismatch();
        }

        address core = _requireCanonicalMineCoreThroughFurnace(f);

        address mm = mineMarket;
        if (mm != address(0)) {
            if (mm.code.length == 0) revert Errors.WiringMismatch();
            if (
                _staticcallAddress(f, _SEL_MINE_MARKET) != mm || _staticcallAddress(mm, _SEL_VE) != address(this)
                    || _staticcallAddress(mm, _SEL_CLAIM) != claimToken
            ) {
                revert Errors.WiringMismatch();
            }
        }

        address sr = _resolveShareholderRoyalties();
        if (sr != address(0)) {
            if (sr.code.length == 0) revert Errors.WiringMismatch();
            if (_staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES) != sr) revert Errors.WiringMismatch();
            if (_staticcallAddress(core, _SEL_ROYALTIES) != sr) revert Errors.WiringMismatch();

            address srVe = _staticcallAddress(sr, _SEL_VE);
            if (srVe != address(0) && srVe != address(this)) revert Errors.WiringMismatch();

            address srFurnace = _staticcallAddress(sr, _SEL_FURNACE);
            if (srFurnace != address(0) && srFurnace != f) revert Errors.WiringMismatch();

            if (mm != address(0)) {
                if (_staticcallAddress(mm, _SEL_ROYALTIES) != sr) revert Errors.WiringMismatch();

                address srMarket = _staticcallAddress(sr, _SEL_MINE_MARKET);
                if (srMarket != address(0) && srMarket != mm) revert Errors.WiringMismatch();
            }
        }
    }

    /// @dev Market-only ve surfaces must not trust the raw `mineMarket` pointer in isolation.
    ///      If `VeClaimNFT.mineMarket` drifts stale pre-freeze, a foreign MarketRouter-like
    ///      contract can list arbitrary active user locks and freeze unlock / maintenance paths,
    ///      or attempt custody transfers under a split-brain market/furnace/royalties surface.
    ///      Require the live market caller to still agree with the canonical furnace/core/
    ///      royalties roots before allowing those mutations.
    function _requireCanonicalMineMarketCaller() internal view {
        address mm = mineMarket;
        if (msg.sender != mm) revert Errors.OnlyMineMarket();
        if (mm == address(0) || mm.code.length == 0) revert Errors.WiringMismatch();

        if (_staticcallAddress(mm, _SEL_VE) != address(this) || _staticcallAddress(mm, _SEL_CLAIM) != claimToken) {
            revert Errors.WiringMismatch();
        }

        address f = furnace;
        if (f == address(0) || f.code.length == 0) revert Errors.WiringMismatch();
        if (
            _staticcallAddress(f, _SEL_MINE_MARKET) != mm || _staticcallAddress(f, _SEL_VE) != address(this)
                || _staticcallAddress(f, _SEL_CLAIM) != claimToken
        ) {
            revert Errors.WiringMismatch();
        }

        address core = _requireCanonicalMineCoreThroughFurnace(f);

        address sr = _resolveShareholderRoyalties();
        if (sr != address(0)) {
            if (sr.code.length == 0) revert Errors.WiringMismatch();
            if (_staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES) != sr) revert Errors.WiringMismatch();
            if (_staticcallAddress(mm, _SEL_ROYALTIES) != sr) revert Errors.WiringMismatch();
            if (_staticcallAddress(core, _SEL_ROYALTIES) != sr) revert Errors.WiringMismatch();

            address srVe = _staticcallAddress(sr, _SEL_VE);
            if (srVe != address(0) && srVe != address(this)) revert Errors.WiringMismatch();

            address srFurnace = _staticcallAddress(sr, _SEL_FURNACE);
            if (srFurnace != address(0) && srFurnace != f) revert Errors.WiringMismatch();

            address srMarket = _staticcallAddress(sr, _SEL_MINE_MARKET);
            if (srMarket != address(0) && srMarket != mm) revert Errors.WiringMismatch();
        }
    }

    // checkpoint royalties for the owner — veCLAIM weight is never attributed to the delegate.
    // No double-counting risk from delegation interactions.
    function _requireDelegated(address user, uint256 requiredPerms) internal view {
        if (user == address(0)) revert Errors.ZeroAddress();

        address hub = _resolveCanonicalDelegationHub();

        if (!IDelegationHub(hub).isAuthorized(user, msg.sender, requiredPerms)) revert Errors.NotAuthorized();
    }

    /// @dev Delegated ve maintenance must authorize against the same canonical delegation hub
    ///      that the live MineCore surface exposes through the same shared Furnace root.
    ///      Otherwise a stale or foreign Furnace-like contract can return an attacker-controlled
    ///      hub and bypass the intended auth model after `MineCore.furnace()` drift.
    function _resolveCanonicalDelegationHub() internal view returns (address hub) {
        address f = furnace;
        address mm = mineMarket;

        if (f == address(0) || mm == address(0)) revert Errors.WiringMismatch();
        if (f.code.length == 0 || mm.code.length == 0) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(f, _SEL_VE) != address(this) || _staticcallAddress(f, _SEL_CLAIM) != claimToken
                || _staticcallAddress(f, _SEL_MINE_MARKET) != mm || _staticcallAddress(mm, _SEL_VE) != address(this)
                || _staticcallAddress(mm, _SEL_CLAIM) != claimToken
        ) {
            revert Errors.WiringMismatch();
        }

        address core = _requireCanonicalMineCoreThroughFurnace(f);

        hub = _staticcallAddress(f, _SEL_DELEGATION_HUB);
        if (hub == address(0) || hub.code.length == 0) revert Errors.WiringMismatch();
        if (_staticcallAddress(core, _SEL_DELEGATION_HUB) != hub) revert Errors.WiringMismatch();
    }

    // ------------------------------------------------------------
    // ShareholderRoyalties integration
    // ------------------------------------------------------------

    // Selector constants used by bounded staticcalls.
    bytes4 internal constant _SEL_SHAREHOLDER_ROYALTIES = bytes4(keccak256("shareholderRoyalties()"));
    bytes4 internal constant _SEL_ROYALTIES = bytes4(keccak256("royalties()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_MINE_MARKET = bytes4(keccak256("mineMarket()"));

    /// @dev Reject EIP-7702-delegated EOAs as candidate wiring roots.
    ///      A 7702 delegation designator is exactly 23 bytes: `0xEF 0x01 0x00 || 20-byte target`.
    ///      Installing such an EOA as a wiring root lets the EOA signer revoke delegation at any
    ///      time and permanently brick every wiring-gated mutator. EIP-3541 bans 0xEF-prefixed
    ///      legacy runtime bytecode, and EOF v1 magic is `0xEF 0x00 0x01` (different byte order),
    ///      so this 3-byte prefix check does not collide with legitimate contract bytecode.
    function _rejectDelegatedEOA(address addr) internal view {
        if (addr.code.length != 23) return;
        bytes32 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(addr, ptr, 0, 3)
            head := mload(ptr)
        }
        if (uint256(head) >> 232 == 0xEF0100) revert Errors.DelegatedEOA();
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory (prevents "return data bomb" griefing).
    ///      Gas-bounded: forwards at most 100 000 gas to prevent untrusted callees from consuming
    ///      the caller's entire gas budget during wiring checks.
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

    /// @dev Resolve ShareholderRoyalties from the supplied wiring roots.
    ///      If both Furnace and MineMarket expose a non-zero royalties surface, they MUST agree.
    ///      Otherwise a stale Furnace pointer can silently override the canonical market-wired
    ///      royalties contract and skip the checkpoint that prevents retroactive royalty capture.
    function _resolveShareholderRoyaltiesFor(address f, address mm) internal view returns (address sr) {
        address srFromFurnace = address(0);
        address srFromMarket = address(0);

        // Preferred source: Furnace.shareholderRoyalties()
        if (f != address(0) && f.code.length != 0) {
            srFromFurnace = _staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES);
        }

        // Fallback: MineMarket(MarketRouter).royalties()
        if (mm != address(0) && mm.code.length != 0) {
            srFromMarket = _staticcallAddress(mm, _SEL_ROYALTIES);
        }

        if (srFromFurnace != address(0) && srFromMarket != address(0) && srFromFurnace != srFromMarket) {
            revert Errors.WiringMismatch();
        }

        if (srFromFurnace != address(0)) return srFromFurnace;
        return srFromMarket;
    }

    /// @dev Resolve ShareholderRoyalties from the live VeClaimNFT storage roots.
    function _resolveShareholderRoyalties() internal view returns (address sr) {
        return _resolveShareholderRoyaltiesFor(furnace, mineMarket);
    }

    /// @dev Non-reverting resolver for best-effort callers. Mirrors
    ///      `_resolveShareholderRoyaltiesFor` but returns `address(0)` on the
    ///      Furnace/MarketRouter disagreement case instead of reverting with
    ///      `WiringMismatch`. Best-effort surfaces (post-burn watermark pin,
    ///      Furnace/system checkpoint) MUST NOT brick the outer lock mutation
    ///      on transient or stale reciprocal wiring.
    function _tryResolveShareholderRoyalties() internal view returns (address sr) {
        address f = furnace;
        address mm = mineMarket;
        address srFromFurnace = address(0);
        address srFromMarket = address(0);

        if (f != address(0) && f.code.length != 0) {
            srFromFurnace = _staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES);
        }
        if (mm != address(0) && mm.code.length != 0) {
            srFromMarket = _staticcallAddress(mm, _SEL_ROYALTIES);
        }

        if (srFromFurnace != address(0) && srFromMarket != address(0) && srFromFurnace != srFromMarket) {
            return address(0);
        }
        if (srFromFurnace != address(0)) return srFromFurnace;
        return srFromMarket;
    }

    /// @dev Setter-time hardening: reject candidate Furnace / MarketRouter roots that already
    ///      conflict with the live CLAIM / MineCore / ShareholderRoyalties bundle. This keeps
    ///      owner-managed rewires fail-closed instead of letting VeClaimNFT enter a split-brain
    ///      state that only surfaces later when users try to lock, list, merge, or unlock.
    ///      Partial deployment sequencing is still allowed: zero/unwired reciprocal getters are
    ///      tolerated, but any non-zero root that is already exposed MUST agree.
    function _requireCanonicalSetterBundle(address f, address mm) internal view {
        address core = address(0);

        if (mm != address(0)) {
            if (mm.code.length == 0) revert Errors.WiringMismatch();
            if (_staticcallAddress(mm, _SEL_VE) != address(this) || _staticcallAddress(mm, _SEL_CLAIM) != claimToken) {
                revert Errors.WiringMismatch();
            }
        }

        if (f != address(0)) {
            if (f.code.length == 0) revert Errors.WiringMismatch();
            if (_staticcallAddress(f, _SEL_VE) != address(this) || _staticcallAddress(f, _SEL_CLAIM) != claimToken) {
                revert Errors.WiringMismatch();
            }

            core = _requireCanonicalMineCoreThroughFurnace(f);

            if (mm != address(0)) {
                address mmFromFurnace = _staticcallAddress(f, _SEL_MINE_MARKET);
                if (mmFromFurnace != address(0) && mmFromFurnace != mm) revert Errors.WiringMismatch();
            }
        }

        address sr = _resolveShareholderRoyaltiesFor(f, mm);
        if (sr == address(0)) return;
        if (sr.code.length == 0) revert Errors.WiringMismatch();

        if (f != address(0)) {
            address srFromFurnace = _staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES);
            if (srFromFurnace != address(0) && srFromFurnace != sr) revert Errors.WiringMismatch();
        }

        if (mm != address(0)) {
            address srFromMarket = _staticcallAddress(mm, _SEL_ROYALTIES);
            if (srFromMarket != address(0) && srFromMarket != sr) revert Errors.WiringMismatch();
        }

        if (core != address(0)) {
            address coreSr = _staticcallAddress(core, _SEL_ROYALTIES);
            if (coreSr != address(0) && coreSr != sr) revert Errors.WiringMismatch();
        }

        address srVe = _staticcallAddress(sr, _SEL_VE);
        if (srVe != address(0) && srVe != address(this)) revert Errors.WiringMismatch();

        if (f != address(0)) {
            address srFurnace = _staticcallAddress(sr, _SEL_FURNACE);
            if (srFurnace != address(0) && srFurnace != f) revert Errors.WiringMismatch();
        }

        if (mm != address(0)) {
            address srMineMarket = _staticcallAddress(sr, _SEL_MINE_MARKET);
            if (srMineMarket != address(0) && srMineMarket != mm) revert Errors.WiringMismatch();
        }

        if (core != address(0)) {
            address srMineCore = _staticcallAddress(sr, _SEL_MINE_CORE);
            if (srMineCore != address(0) && srMineCore != core) revert Errors.WiringMismatch();
        }
    }

    /// @dev Must be called BEFORE any change to a user's ve balance to prevent retroactive royalty capture.
    function _checkpointShareholderRoyalties(address user) internal {
        _checkpointShareholderRoyaltiesInternal(user, false);
    }

    /// @dev Best-effort checkpoint for Furnace/system paths (e.g. `furnaceBurnAndWithdraw`)
    ///      where `ShareholderRoyalties.checkpointUser` must not brick the outer call.
    ///      Silently swallows revert if the royalties contract is unhealthy.
    function _checkpointShareholderRoyaltiesBestEffort(address user) internal {
        _checkpointShareholderRoyaltiesInternal(user, true);
    }

    /// @dev Refresh the per-user observed-min on `ShareholderRoyalties` after a
    ///      lock-set change (create / extend / addToLock / autoMax flip /
    ///      decrease). The pin walks the live `getShareholderLockParams`
    ///      output and narrows the global watermark when the new lock set
    ///      reveals a tighter non-AutoMax floor — without this hook a fresh
    ///      shorter non-AutoMax lock stays absent from the watermark until a
    ///      reward delta lands. Best-effort: a missing or unhealthy royalties
    ///      contract leaves the observed-min unchanged so the outer
    ///      lock-mutation path keeps its invariants.
    function _pinShareholderObservedMin(address user) internal {
        if (user == address(0)) return;
        // Non-reverting resolve: a transient `WiringMismatch` between the
        // Furnace and MarketRouter royalties pointers must NOT brick the
        // outer lock mutation. The pin is best-effort by contract.
        address sr = _tryResolveShareholderRoyalties();
        if (sr == address(0) || sr.code.length == 0) return;
        try IShareholderRoyalties(sr).pinUserObservedMin(user) {}
            catch {
            // best-effort
        }
    }

    function _checkpointShareholderRoyaltiesInternal(address user, bool bestEffort) internal {
        if (user == address(0)) return;

        if (bestEffort) {
            // Best-effort path used by Furnace/system surfaces such as
            // `furnaceBurnAndWithdraw`. Every revert source is suppressed so a
            // transient or stale reciprocal-wiring drift cannot brick the outer
            // call: the resolver is the non-reverting variant, the wiring
            // asserts are skipped (the checkpoint call itself reverts loudly
            // when the SR is genuinely malformed and is caught below), and the
            // checkpoint call is wrapped in try/catch.
            address srBest = _tryResolveShareholderRoyalties();
            if (srBest == address(0) || srBest.code.length == 0) return;
            try IShareholderRoyalties(srBest).checkpointUser(user) {}
            catch {
                emit Events.ShareholderCheckpointFailed(user, srBest);
            }
            return;
        }

        address sr = _resolveShareholderRoyalties();
        if (sr == address(0)) revert Errors.ShareholderRoyaltiesNotSet();
        if (sr.code.length == 0) revert Errors.NotAContract();

        address srVe = _staticcallAddress(sr, _SEL_VE);
        if (srVe != address(0) && srVe != address(this)) revert Errors.WiringMismatch();

        address f = furnace;
        if (f != address(0) && f.code.length != 0) {
            address core = _requireCanonicalMineCoreThroughFurnace(f);

            address srFromFurnace = _staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES);
            if (srFromFurnace != address(0) && srFromFurnace != sr) revert Errors.WiringMismatch();

            address coreSr = _staticcallAddress(core, _SEL_ROYALTIES);
            if (coreSr != address(0) && coreSr != sr) revert Errors.WiringMismatch();

            address srFurnace = _staticcallAddress(sr, _SEL_FURNACE);
            if (srFurnace != address(0) && srFurnace != f) revert Errors.WiringMismatch();
        }

        address mm = mineMarket;
        if (mm != address(0) && mm.code.length != 0) {
            address srFromMarket = _staticcallAddress(mm, _SEL_ROYALTIES);
            if (srFromMarket != address(0) && srFromMarket != sr) revert Errors.WiringMismatch();

            address srMineMarket = _staticcallAddress(sr, _SEL_MINE_MARKET);
            if (srMineMarket != address(0) && srMineMarket != mm) revert Errors.WiringMismatch();
        }

        IShareholderRoyalties(sr).checkpointUser(user);
    }

    constructor(address _claimToken, address initialOwner) ERC721("Locked CLAIM", "veCLAIM") Ownable(initialOwner) {
        if (_claimToken == address(0) || initialOwner == address(0)) revert Errors.ZeroAddress();

        // The runtime `transferOwnership` surface rejects EIP-7702 delegated EOAs.
        // The constructor enforces the same rule on `initialOwner` so the genesis
        // owner cannot exercise wiring (`setMineMarket`, `setFurnace`,
        // `freezeConfig`) and metadata-baseURI surfaces through public executor
        // code before the first hardened transfer.
        _rejectDelegatedEOA(initialOwner);

        // Immutable core root: this token is pulled on every lock create/top-up path.
        // If it is miswired to an EOA or malformed address, the deployment is permanently doomed
        // and lock entry will only fail later at runtime after surrounding contracts have already
        // been wired against this ve instance.
        if (_claimToken.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_claimToken);

        claimToken = _claimToken;

        // Initialize global checkpoint time to deployment timestamp.
        _globalLastTs = block.timestamp;

        // 1-indexed min-heap sentinel for slope times (index 0 unused).
        _slopeTimeHeap.push(0);
    }

    // ---- Wiring (onlyOwner) ----

    function setMineMarket(address _mineMarket) external onlyOwner whenNotFrozen {
        if (_mineMarket == address(0)) revert Errors.ZeroAddress();
        if (_mineMarket.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_mineMarket);
        _requireCanonicalSetterBundle(furnace, _mineMarket);
        address oldMineMarket = mineMarket;
        mineMarket = _mineMarket;
        emit Events.MineMarketChanged(oldMineMarket, _mineMarket);
    }

    function setFurnace(address _furnace) external onlyOwner whenNotFrozen {
        if (_furnace == address(0)) revert Errors.ZeroAddress();
        if (_furnace.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_furnace);
        _requireCanonicalSetterBundle(_furnace, mineMarket);
        address oldFurnace = furnace;
        furnace = _furnace;
        emit Events.FurnaceChanged(oldFurnace, _furnace);
    }

    /// @notice Permanently lock core game-rule wiring (furnace, mineMarket).
    /// @dev After freeze, only metadata (baseURI, contractURI) remains owner-configurable.
    function freezeConfig() external onlyOwner whenNotFrozen {
        address f = furnace;
        address mm = mineMarket;
        if (f == address(0)) revert Errors.ZeroAddress();
        if (mm == address(0)) revert Errors.ZeroAddress();

        _requireCanonicalSetterBundle(f, mm);

        // Final freeze is stricter than staged setter-time validation: once both roots are set,
        // runtime mutators require exact reciprocal agreement rather than "zero means not yet wired."
        if (_staticcallAddress(f, _SEL_MINE_MARKET) != mm) revert Errors.WiringMismatch();

        address sr = _resolveShareholderRoyaltiesFor(f, mm);
        if (sr != address(0)) {
            if (_staticcallAddress(f, _SEL_SHAREHOLDER_ROYALTIES) != sr) revert Errors.WiringMismatch();
            if (_staticcallAddress(mm, _SEL_ROYALTIES) != sr) revert Errors.WiringMismatch();
        }

        configFrozen = true;
        emit Events.ConfigFrozen();
    }

    // ---- Metadata (ERC-721 + ERC-4906 + ERC-7572) ----

    uint256 private constant _MAX_URI_LENGTH = 512;

    /// @notice Set the base URI used by tokenURI(). Wallets fetch `baseURI + tokenId`
    ///         to resolve per-token JSON metadata (name, image, attributes).
    /// @dev Reverts with `Errors.URITooLong()` if `uri` exceeds `_MAX_URI_LENGTH` (512 bytes).
    ///      Reverts with `Errors.MetadataFrozen()` after `freezeMetadata()` has been called.
    /// @param uri The new base URI (must include trailing slash if path-based).
    function setBaseURI(string calldata uri) external onlyOwner whenMetadataNotFrozen {
        if (bytes(uri).length > _MAX_URI_LENGTH) revert Errors.URITooLong();
        string memory oldURI = _baseTokenURI;
        _baseTokenURI = uri;
        emit Events.BaseURISet(oldURI, uri);
        emit Events.BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Set the collection-level metadata URI (ERC-7572 contractURI).
    /// @dev Reverts with `Errors.URITooLong()` if `uri` exceeds `_MAX_URI_LENGTH` (512 bytes).
    ///      Reverts with `Errors.MetadataFrozen()` after `freezeMetadata()` has been called.
    /// @param uri The new collection metadata URI (should return JSON per ERC-7572).
    function setContractURI(string calldata uri) external onlyOwner whenMetadataNotFrozen {
        if (bytes(uri).length > _MAX_URI_LENGTH) revert Errors.URITooLong();
        string memory oldURI = _contractTokenURI;
        _contractTokenURI = uri;
        emit Events.ContractURISet(oldURI, uri);
        emit Events.ContractURIUpdated();
    }

    /// @notice One-way freeze of NFT metadata setters. After this call, `setBaseURI` and
    ///         `setContractURI` permanently revert with `Errors.MetadataFrozen()`.
    /// @dev Orthogonal to `freezeConfig()`. Callable by the current owner (Admin Safe or, after
    ///      handoff, the Timelock) once the final metadata endpoint is confirmed stable.
    function freezeMetadata() external onlyOwner whenMetadataNotFrozen {
        metadataFrozen = true;
        emit Events.MetadataFrozen();
    }

    /// @notice Collection-level metadata (ERC-7572). Wallets and marketplaces
    ///         fetch this to display collection name, description, and image.
    function contractURI() external view returns (string memory) {
        return _contractTokenURI;
    }

    /// @notice Returns the current base URI used by tokenURI().
    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /// @dev Returns _baseTokenURI set via setBaseURI(). OpenZeppelin's tokenURI()
    ///      concatenates this with the token ID.
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /// @dev Pending-mint tokenURI window. `tokenURI(id)` returns the indexer-friendly
    ///      placeholder URI (`baseURI + id`) for the next `_PENDING_MINT_WINDOW` tokenIds
    ///      starting at `_nextTokenId`, instead of reverting with `ERC721NonexistentToken`.
    ///      Chosen to cover multicall/batched mint previews (e.g. wallet signing-preview
    ///      flows that call `tokenURI(nextTokenId)` right before the mint tx lands in the
    ///      same block) without unbounding the range of ids that read as "maybe alive".
    ///      The off-chain `tokenURI` resolver (claimru.sh) mirrors this same window so
    ///      preview reads stay consistent across onchain and indexer sources.
    uint256 private constant _PENDING_MINT_WINDOW = 4;

    /// @notice ERC-721 tokenURI with pending-mint window placeholder.
    /// @dev For minted tokens, defers to OpenZeppelin's default (`_baseURI() + tokenId`).
    ///      For the next `_PENDING_MINT_WINDOW` unminted tokenIds starting at
    ///      `_nextTokenId`, returns the same `baseURI + tokenId` placeholder so that
    ///      wallet signing previews and batched multicalls resolve to indexer-generated
    ///      metadata rather than a revert. For any other unminted tokenId (either well
    ///      past the pending window, or below `_nextTokenId` implying a never-minted
    ///      gap) reverts with `ERC721NonexistentToken` as the spec expects.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) != address(0)) {
            return super.tokenURI(tokenId);
        }
        uint256 next = _nextTokenId;
        if (tokenId >= next && tokenId < next + _PENDING_MINT_WINDOW) {
            string memory base = _baseURI();
            return bytes(base).length > 0 ? string.concat(base, Strings.toString(tokenId)) : "";
        }
        revert ERC721NonexistentToken(tokenId);
    }

    /// @dev ERC-4906 (0x49064906) + ERC-7572 (0xe8a3d485) interface detection.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == bytes4(0x49064906) || interfaceId == bytes4(0xe8a3d485)
                || super.supportsInterface(interfaceId);
    }

    // ---- Views ----

    /// @notice Returns the ID that will be assigned to the next minted lock.
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    function getLockInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint256 lockEnd, bool autoMax, bool listed)
    {
        Lock storage l = _locks[tokenId];

        // AutoMax: treat the lock as continuously extended to max duration — effective remaining
        // time is always MAX_LOCK_DURATION and the lock does not expire while autoMax is true.
        uint256 effectiveEnd = l.lockEnd;
        if (l.autoMax && l.amount != 0) {
            effectiveEnd = block.timestamp + Constants.MAX_LOCK_DURATION;
        }

        return (l.amount, effectiveEnd, l.autoMax, l.listed);
    }

    /// @notice Returns the lock's last mutation timestamp.
    /// @dev Furnace AutoMax bonus accrual uses this as a floor so newly added principal
    ///      or autoMax mode changes cannot inherit an older accrual window.
    function lockStartOf(uint256 tokenId) external view returns (uint256) {
        return _locks[tokenId].lockStart;
    }

    function veBalanceOf(address user) external view returns (uint256) {
        uint256 nowTs = block.timestamp;
        uint256[] storage ids = _ownedTokens[user];
        uint256 ve = 0;
        uint256 len = ids.length;
        for (uint256 i = 0; i < len;) {
            uint256 tokenId = ids[i];
            Lock storage l = _locks[tokenId];

            uint256 amt = l.amount;
            if (amt == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // AutoMax = keep me at max ve forever.
            if (l.autoMax) {
                ve += amt;
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 end = l.lockEnd;
            if (end <= nowTs) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 remaining = end - nowTs;
            ve += Math.mulDiv(amt, remaining, Constants.MAX_LOCK_DURATION, Math.Rounding.Floor);
            unchecked {
                ++i;
            }
        }
        return ve;
    }

    function totalLockedClaim() external view returns (uint256) {
        return _totalLockedClaim;
    }

    function totalVeCached() external view returns (uint256) {
        return _totalVeCached;
    }

    /// @notice Returns the number of pending slope change timestamps in the heap.
    /// @dev Keepers should monitor this value and call checkpointGlobalState()
    ///      proactively when it exceeds ~250 (`Constants.MAX_SLOPE_CHANGES_PER_CALL`) to prevent takeover gas exhaustion.
    function getSlopeChangeCount() external view returns (uint256) {
        return _slopeTimeHeap.length > 1 ? _slopeTimeHeap.length - 1 : 0;
    }

    /// @notice Current processed total ve-bias used by ShareholderRoyalties.
    /// @dev Units are "ve * 1e18". Freshness is bounded by `globalLastTs()`.
    function totalVeBiasScaled() external view returns (uint256) {
        return _globalBiasScaled;
    }

    /// @notice Current total ve (same formula as checkpointTotalVe) for read-only use (e.g. UI share-of-total).
    /// @dev View-only: does NOT run a checkpoint. Value is only as fresh as the last time _globalBiasScaled
    ///      was updated (e.g. by lock mutations, checkpointGlobalState(), or checkpointTotalVe()).
    ///      Call globalLastTs() to know the timestamp of that last update. UI/tooling using this as
    ///      a denominator for share-of-total should treat it as "at most as fresh as globalLastTs".
    ///      IMPORTANT: If global state has not been checkpointed recently, this returns a STALE value
    ///      (typically too high, since decay is not applied). For critical quoting or share-of-total
    ///      math, have the user or a relayer call checkpointTotalVe() first, then use totalVeCached().
    ///      NOTE: This uses ceiling division (conservative / slightly high), while per-user
    ///      veBalanceOf() uses floor rounding. As a result, sum(veBalanceOf) <= totalVeCurrent().
    ///      The dominant integer gap is the per-lock floor term on non-AutoMax balances
    ///      (<= active non-AutoMax locks - 1). Conservative slope rounding and residual dust add
    ///      only a tiny extra tail bounded by active non-AutoMax locks plus pending early-removal
    ///      buckets. Negligible for UI share math, but not strictly "1 wei per active lock."
    function totalVeCurrent() external view returns (uint256) {
        return Math.ceilDiv(_globalBiasScaled, SLOPE_SCALE);
    }

    /// @notice Current lock parameters used by ShareholderRoyalties to reconstruct delayed rewards.
    /// @dev Arrays are parallel and intentionally include expired-but-not-yet-unlocked locks.
    ///      IMPORTANT: `lockEnds[i]` returns the RAW stored `lockEnd`, NOT the effective end.
    ///      For AutoMax locks (`autoMaxFlags[i] == true`), callers MUST treat ve as equal to
    ///      `amounts[i]` (no decay) and MUST NOT use `lockEnds[i]` for ve math.
    ///      This differs from `getLockInfo(tokenId)` which returns the effective end
    ///      (`block.timestamp + MAX_LOCK_DURATION`) for AutoMax locks.
    ///      ShareholderRoyalties uses the `autoMaxFlags` array to distinguish these from decaying locks.
    function getShareholderLockParams(address user)
        external
        view
        returns (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags)
    {
        uint256[] storage ids = _ownedTokens[user];
        uint256 len = ids.length;
        amounts = new uint256[](len);
        lockEnds = new uint256[](len);
        autoMaxFlags = new bool[](len);

        for (uint256 i = 0; i < len;) {
            Lock storage l = _locks[ids[i]];
            amounts[i] = l.amount;
            lockEnds[i] = l.lockEnd;
            autoMaxFlags[i] = l.autoMax;
            unchecked {
                ++i;
            }
        }
    }

    // ---- Checkpointing ----

    /// @notice Advance global slope/bias state to the current block timestamp.
    /// @dev Decays `_globalBiasScaled` by processing pending slope changes and
    ///      syncs `_totalVeCached` (via `_checkpointGlobalStateInternal`).
    ///      Functionally equivalent to `checkpointTotalVe()`.
    function checkpointGlobalState() external nonReentrant {
        _checkpointGlobalStateInternal();
    }

    /// @notice Advance global slope/bias and guarantee a fresh `_totalVeCached` denominator.
    /// @dev Identical to checkpointGlobalState(). Both are retained for caller-intent clarity.
    function checkpointTotalVe() external nonReentrant {
        _checkpointGlobalStateInternal();
    }

    function globalLastTs() external view returns (uint256) {
        return _globalLastTs;
    }

    // ---- Furnace-only lock lifecycle ----

    /// @notice Furnace-only merge sibling of `extendLockToFor` / `addToLockFor`.
    /// @dev User-facing merge is `Furnace.mergeLocksWithBonus(...)`, which routes through this
    ///      function so the bonus engine and lock math share a single ownership/auth path.
    ///      Furnace performs the AutoMax-mismatch + delegation gates ahead of this call via
    ///      `FurnaceGuardHelper.resolveMergeWithBonus(...)`; no further session check here.
    function mergeLocksFor(address user, uint256 fromTokenId, uint256 intoTokenId)
        external
        nonReentrant
        onlyFurnace
        returns (uint256 fromAmt, uint256 newAmt, uint256 newEnd, bool newAutoMax)
    {
        return _mergeLocksInternal(user, fromTokenId, intoTokenId);
    }

    function _mergeLocksInternal(address user, uint256 fromTokenId, uint256 intoTokenId)
        internal
        returns (uint256 fromAmtRet, uint256 newAmtRet, uint256 newEndRet, bool newAutoMaxRet)
    {
        // If fromEnd > intoEnd, the "into" lock's principal is re-locked beyond its original
        // end. Global ve math is updated (old contributions removed, new combined
        // contribution added with the longer remaining time) so no extra veCLAIM is created
        // beyond what the longer lock already provided. The user's capital from the shorter
        // lock is silently extended to the longer end.
        if (fromTokenId == intoTokenId) revert Errors.NotAuthorized();

        Lock storage fromL = _requireOwnedLock(fromTokenId, user);
        Lock storage intoL = _requireOwnedLock(intoTokenId, user);
        _requireMutable(fromL);
        _requireMutable(intoL);

        _checkpointGlobalStateInternal();
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyalties(user);
        uint256 t = _globalLastTs;

        if (t != block.timestamp) revert Errors.CheckpointStale();

        // Keep merge math stack-light (avoid "stack too deep"). Compute and apply deltas
        // incrementally and reuse locals in sub-scopes.
        uint256 fromAmt = fromL.amount;
        uint256 fromEnd = fromL.lockEnd;
        uint256 intoAmt = intoL.amount;
        uint256 intoEnd = intoL.lockEnd;

        uint256 newAmt = intoAmt + fromAmt;
        bool newAutoMax = intoL.autoMax || fromL.autoMax;

        // AutoMax merged locks are treated as perpetually max-duration.
        uint256 newEnd =
            newAutoMax ? (block.timestamp + Constants.MAX_LOCK_DURATION) : (intoEnd >= fromEnd ? intoEnd : fromEnd);

        int256 deltaSlope = 0;
        int256 deltaBias = 0;

        // Remove old "from" lock contribution.
        {
            if (fromL.autoMax) {
                deltaBias -= SafeCast.toInt256(fromAmt * SLOPE_SCALE);
            } else {
                uint256 slope = _slopeScaledRemove(fromAmt);
                int256 slopeI = SafeCast.toInt256(slope);
                deltaSlope -= slopeI;
                deltaBias -= SafeCast.toInt256(slope * _remainingAt(fromEnd, t));
                _applySlopeChangeDelta(fromEnd, -slopeI);
            }
        }

        // Remove old "into" lock contribution.
        {
            if (intoL.autoMax) {
                deltaBias -= SafeCast.toInt256(intoAmt * SLOPE_SCALE);
            } else {
                uint256 slope = _slopeScaledRemove(intoAmt);
                int256 slopeI = SafeCast.toInt256(slope);
                deltaSlope -= slopeI;
                deltaBias -= SafeCast.toInt256(slope * _remainingAt(intoEnd, t));
                _applySlopeChangeDelta(intoEnd, -slopeI);
            }
        }

        // Add new merged lock contribution.
        {
            if (newAutoMax) {
                deltaBias += SafeCast.toInt256(newAmt * SLOPE_SCALE);
            } else {
                uint256 slope = _slopeScaledAdd(newAmt); // Ceil rounding — consistent with create/add/extend paths
                int256 slopeI = SafeCast.toInt256(slope);
                deltaSlope += slopeI;
                deltaBias += SafeCast.toInt256(slope * _remainingAt(newEnd, t));
                _applySlopeChangeDelta(newEnd, slopeI);
            }
        }

        _applyGlobalDelta(deltaSlope, deltaBias);

        // Update destination lock.
        intoL.amount = newAmt;
        intoL.lockEnd = newEnd;
        intoL.lockStart = block.timestamp;
        intoL.autoMax = newAutoMax;

        // Burn first so _update sees non-zero lock data if future hooks read it.
        _burn(fromTokenId);
        delete _locks[fromTokenId];

        emit Events.LockMerged(user, fromTokenId, intoTokenId, fromAmt);
        emit Events.MetadataUpdate(intoTokenId);

        // Pin observed-min: a merge replaces two locks with one combined lock
        // whose end may differ from either input (e.g. AutoMax flip-on extends
        // to MAX_LOCK_DURATION; non-AutoMax merge picks the longer end). The
        // per-user non-AutoMax floor and the AutoMax bit can both shift, so
        // refresh the watermark inputs to keep ShareholderRoyalties consistent
        // with live ve state.
        _pinShareholderObservedMin(user);

        fromAmtRet = fromAmt;
        newAmtRet = newAmt;
        newEndRet = newEnd;
        newAutoMaxRet = newAutoMax;
    }

    /// @notice Toggle auto-max on a lock. Owner-only — no delegated variant by design.
    function setAutoMax(uint256 tokenId, bool enabled) external nonReentrant {
        Lock storage l = _requireOwnedLock(tokenId, msg.sender);
        _requireMutable(l);

        bool old = l.autoMax;
        if (old == enabled) {
            if (enabled) {
                // When refreshing an already-enabled AutoMax lock, mutating lockStart
                // (Furnace accrual floor) requires a ShareholderRoyalties checkpoint
                // so the royalties contract captures the pre-mutation state.
                uint256 ts = block.timestamp;

                _checkpointGlobalStateInternal();
                _checkpointShareholderRoyalties(msg.sender);

                if (_globalLastTs != ts) revert Errors.CheckpointStale();

                l.lockEnd = ts + Constants.MAX_LOCK_DURATION;
                l.lockStart = ts;

                emit Events.AutoMaxSet(msg.sender, tokenId, enabled);
                return;
            }
            // Already disabled — pure no-op. Skip event to prevent
            // off-chain indexers from recording a phantom toggle.
            return;
        }

        _checkpointGlobalStateInternal();
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyalties(msg.sender);
        uint256 t = _globalLastTs;

        if (t != block.timestamp) revert Errors.CheckpointStale();

        uint256 amt = l.amount;
        uint256 oldEnd = l.lockEnd;

        int256 deltaSlope = 0;
        int256 deltaBias = 0;

        // Remove previous contribution.
        if (old) {
            deltaBias -= SafeCast.toInt256(amt * SLOPE_SCALE);
        } else {
            uint256 slope = _slopeScaledRemove(amt);
            int256 slopeI = SafeCast.toInt256(slope);
            deltaSlope -= slopeI;
            deltaBias -= SafeCast.toInt256(slope * _remainingAt(oldEnd, t));
            _applySlopeChangeDelta(oldEnd, -slopeI);
        }

        uint256 nowTs = block.timestamp;
        uint256 newEnd = nowTs + Constants.MAX_LOCK_DURATION;

        // Add new contribution.
        if (enabled) {
            deltaBias += SafeCast.toInt256(amt * SLOPE_SCALE);
        } else {
            uint256 slope = _slopeScaledAdd(amt);
            int256 slopeI = SafeCast.toInt256(slope);
            deltaSlope += slopeI;
            deltaBias += SafeCast.toInt256(slope * _remainingAt(newEnd, t));
            _applySlopeChangeDelta(newEnd, slopeI);
        }

        _applyGlobalDelta(deltaSlope, deltaBias);

        l.autoMax = enabled;
        l.lockEnd = newEnd;
        l.lockStart = nowTs;

        emit Events.AutoMaxSet(msg.sender, tokenId, enabled);
        emit Events.MetadataUpdate(tokenId);

        // Pin observed-min: flipping AutoMax on widens the per-user floor (the
        // lock leaves the non-AutoMax set); flipping off narrows it. Keep the
        // global watermark consistent with the live ve state.
        _pinShareholderObservedMin(msg.sender);
    }

    function unlock(uint256 tokenId) external nonReentrant {
        _unlockTo(msg.sender, tokenId, msg.sender);
    }

    /// @notice Delegation-gated lock maintenance (safe, non-custodial).
    /// @dev Requires `P_VE_UNLOCK_EXPIRED_FOR`. CLAIM is returned to `user`.
    function unlockExpiredForUser(address user, uint256 tokenId) external nonReentrant {
        uint256 perms = DelegationPermissions.P_VE_UNLOCK_EXPIRED_FOR;
        _requireDelegated(user, perms);

        _unlockTo(user, tokenId, user);
        emit Events.DelegationSessionUsed(
            user, msg.sender, DelegationActionTypes.VE_UNLOCK_EXPIRED_FOR, perms, tokenId, block.timestamp
        );
    }

    function _unlockTo(address tokenOwner, uint256 tokenId, address recipient) internal returns (uint256 amt) {
        if (recipient == address(0)) revert Errors.ZeroAddress();

        Lock storage l = _requireOwnedLock(tokenId, tokenOwner);
        if (l.listed) revert Errors.LockListedOrFrozen();

        // AutoMax = perpetual max-duration. Users must disable AutoMax before unlocking.
        if (l.autoMax) revert Errors.InvalidDuration();

        uint256 nowTs = block.timestamp;
        if (nowTs < l.lockEnd) revert Errors.InvalidDuration();

        _checkpointGlobalStateInternal();
        // Fail-closed: user-initiated unlocks MUST checkpoint shareholder royalties before
        // the lock is burned. ShareholderRoyalties reconstructs delayed rewards from
        // getShareholderLockParams(user), which relies on expired-but-not-yet-unlocked locks
        // remaining visible. If checkpointUser reverts (e.g. transient wiring transition),
        // the user retries once wiring settles — their lock + accrued rewards stay intact.
        // furnaceBurnAndWithdraw keeps best-effort because system operations must not be
        // blockable by ShareholderRoyalties state.
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyalties(tokenOwner);
        uint256 t = _globalLastTs;

        amt = l.amount;
        if (amt == 0) revert Errors.InvalidToken();
        uint256 end = l.lockEnd;

        // If global state is still behind the expiry, the position is still included in slope/bias at t.
        if (end > t) {
            uint256 slope = _slopeScaledRemove(amt);
            int256 slopeI = SafeCast.toInt256(slope);
            uint256 bias = slope * (end - t);
            _applyGlobalDelta(-slopeI, -SafeCast.toInt256(bias));
            _applySlopeChangeDelta(end, -slopeI);
        }

        _totalLockedClaim -= amt;

        _burn(tokenId);
        delete _locks[tokenId];

        // Pin the user's observed-min after the burn so the eviction-floor
        // watermark on `ShareholderRoyalties` cannot retain a stale per-user /
        // global non-AutoMax floor for a lock that no longer exists. Best-effort
        // by contract; a non-reverting resolve covers transient or stale
        // reciprocal wiring.
        _pinShareholderObservedMin(tokenOwner);

        emit Events.LockUnlocked(tokenOwner, tokenId, amt);

        // CEI: external interaction last.
        IERC20(claimToken).safeTransfer(recipient, amt);
        return amt;
    }

    // ---- Furnace routing helpers ----

    function addToLockFor(address user, uint256 tokenId, uint256 amount) external nonReentrant onlyFurnace {
        _addToLock(msg.sender, user, tokenId, amount);
    }

    function createLockFor(address user, uint256 amount, uint256 duration, bool autoMax)
        external
        nonReentrant
        onlyFurnace
        returns (uint256 tokenId)
    {
        return _createLock(msg.sender, user, amount, duration, autoMax);
    }

    function extendLockToFor(address user, uint256 tokenId, uint256 newEnd) external nonReentrant onlyFurnace {
        // Furnace-only helper (SPEC §4.2.3): owner must match + extension-only.
        if (user == address(0)) revert Errors.ZeroAddress();
        if (_ownerOf(tokenId) != user) revert Errors.NotAuthorized();
        Lock storage l = _locks[tokenId];
        _requireMutable(l);

        uint256 nowTs = block.timestamp;
        uint256 oldEnd = l.lockEnd;

        // AutoMax locks: ignore the passed newEnd and refresh to now + MAX.
        // Do not enforce extension-only semantics for the passed value.
        if (l.autoMax) {
            // NOTE: CheckpointStale guard intentionally omitted here.
            // AutoMax locks contribute flat bias (amount * SLOPE_SCALE) with zero slope.
            // Refreshing lockEnd/lockStart is a storage-only operation that does not touch
            // the global slope/bias aggregates, so stale global state is harmless.
            _checkpointGlobalStateInternal();
            // slither-disable-next-line reentrancy-no-eth
            _checkpointShareholderRoyalties(user);
            uint256 targetEnd = nowTs + Constants.MAX_LOCK_DURATION;
            l.lockEnd = targetEnd;
            l.lockStart = nowTs;
            emit Events.LockExtended(user, tokenId, oldEnd, targetEnd);
            return;
        }

        // Extension-only check.
        if (newEnd <= oldEnd) revert Errors.InvalidDuration();
        if (newEnd > nowTs + Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();

        _extendLockToInternal(user, tokenId, l, newEnd);
    }

    /// @notice Furnace-only: burn a lock held in Furnace custody and withdraw the underlying principal.
    /// @dev Used by the Furnace sellback primitive.
    function furnaceBurnAndWithdraw(uint256 tokenId, address to)
        external
        nonReentrant
        onlyFurnace
        returns (uint256 amount)
    {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (_ownerOf(tokenId) != furnace) revert Errors.NotAuthorized();

        Lock storage l = _locks[tokenId];
        if (l.listed) revert Errors.LockListedOrFrozen();

        _checkpointGlobalStateInternal();
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyaltiesBestEffort(furnace);
        uint256 t = _globalLastTs;

        amount = l.amount;
        if (amount == 0) revert Errors.InvalidToken();

        int256 deltaSlope = 0;
        int256 deltaBias = 0;

        if (l.autoMax) {
            deltaBias = -SafeCast.toInt256(amount * SLOPE_SCALE);
        } else {
            uint256 end = l.lockEnd;

            // If the lock is still active relative to the global checkpoint time, remove its contribution.
            if (end > t) {
                uint256 slope = _slopeScaledRemove(amount);
                int256 slopeI = SafeCast.toInt256(slope);

                deltaSlope = -slopeI;
                deltaBias = -SafeCast.toInt256(slope * _remainingAt(end, t));

                // Remove scheduled slope change at end.
                _applySlopeChangeDelta(end, -slopeI);
            }
        }

        _applyGlobalDelta(deltaSlope, deltaBias);

        _totalLockedClaim -= amount;

        _burn(tokenId);
        delete _locks[tokenId];

        // Pin Furnace's observed-min after the burn so the eviction-floor
        // watermark on `ShareholderRoyalties` cannot retain a stale per-user /
        // global non-AutoMax floor for a lock that no longer exists. Best-effort
        // by contract; a non-reverting resolve covers transient or stale
        // reciprocal wiring.
        _pinShareholderObservedMin(furnace);

        emit Events.LockUnlocked(furnace, tokenId, amount);

        // CEI: external interaction last.
        IERC20(claimToken).safeTransfer(to, amount);
    }

    // ---- MarketRouter coordination ----

    function setListed(uint256 tokenId, bool listed) external nonReentrant {
        _requireCanonicalMineMarketCaller();
        if (_ownerOf(tokenId) == address(0)) revert Errors.InvalidToken();

        Lock storage l = _locks[tokenId];
        if (listed) {
            // Listing is only valid for non-expired locks. AutoMax locks are never treated as expired.
            if (!l.autoMax && block.timestamp >= l.lockEnd) revert Errors.LockExpired();
            if (l.listed) revert Errors.LockListedOrFrozen();
            l.listed = true;
            emit Events.MetadataUpdate(tokenId);
        } else {
            // Delist must always be allowed (even if expired). Emit the
            // MetadataUpdate unconditionally so indexers always have a
            // reconciliation signal for a redundant delist (the state write
            // itself is still gated on l.listed so the state transition is
            // idempotent).
            if (l.listed) {
                l.listed = false;
            }
            emit Events.MetadataUpdate(tokenId);
        }
    }

    // ---- Transfer restriction (OZ v5) ----

    // OZ v5's 3-arg safeTransferFrom delegates to the 4-arg override below,
    // which is already guarded by nonReentrant. No separate override needed.

    /// @dev Wrap all external ERC721 transfer entrypoints in `nonReentrant`.
    ///      MineMarket transfers into Furnace custody invoke an external receiver hook on Furnace,
    ///      and `_update()` itself checkpoints ShareholderRoyalties before state changes. Guard the
    ///      whole transfer surface so a receiver callback cannot reenter Furnace-only ve mutators
    ///      (for example `furnaceBurnAndWithdraw`) against half-completed custody state.
    function transferFrom(address from, address to, uint256 tokenId) public override nonReentrant {
        _transferRestricted(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data)
        public
        override
        nonReentrant
    {
        _safeTransferRestrictedInternal(from, to, tokenId, data);
    }

    function _transferRestricted(address from, address to, uint256 tokenId) internal {
        if (to == address(0)) revert ERC721InvalidReceiver(address(0));

        address previousOwner = _update(to, tokenId, _msgSender());
        if (previousOwner != from) revert ERC721IncorrectOwner(from, tokenId, previousOwner);
    }

    /// @dev Shared body for both 3-arg and 4-arg safeTransferFrom.
    function _safeTransferRestrictedInternal(address from, address to, uint256 tokenId, bytes memory data) internal {
        _transferRestricted(from, to, tokenId);
        _checkOnERC721ReceivedRestricted(from, to, tokenId, data);
    }

    function _checkOnERC721ReceivedRestricted(address from, address to, uint256 tokenId, bytes memory data) internal {
        if (to.code.length == 0) return;

        try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, data) returns (bytes4 retval) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert ERC721InvalidReceiver(to);
        } catch (bytes memory reason) {
            if (reason.length == 0) revert ERC721InvalidReceiver(to);
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        // Pre-transfer checks (transfer path only: from != 0 && to != 0).
        // Performed BEFORE super._update() so the royalty checkpoint reads fully
        // consistent pre-transfer state (both OZ ownership and custom enumeration
        // still reflect the current owner).
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != address(0) && to != address(0)) {
            _checkpointGlobalStateInternal();

            if (_globalLastTs != block.timestamp) revert Errors.CheckpointStale();

            // slither-disable-next-line reentrancy-no-eth
            _checkpointShareholderRoyalties(currentOwner);
            // slither-disable-next-line reentrancy-no-eth
            _checkpointShareholderRoyalties(to);
            _requireCanonicalMineMarketCaller();
            if (to != furnace) revert Errors.MarketMustTransferToFurnace();
            if (_locks[tokenId].listed) revert Errors.LockListedOrFrozen();

            // Custom auth complete — bypass OZ's _checkAuthorized (which would
            // revert because approve() and setApprovalForAll() are disabled,
            // so MineMarket can never hold a token approval or operator grant).
            auth = address(0);
        }

        from = super._update(to, tokenId, auth);

        // Enforce the per-address veNFT cap on every receive path (mint + transfer; burns excluded).
        // This keeps all onchain owner enumeration and shareholder checkpointing gas-bounded,
        // including transient MarketRouter -> Furnace custody transfers.
        if (to != address(0)) {
            if (balanceOf(to) > Constants.MAX_VE_NFTS_PER_USER) revert Errors.TooManyVeNFTs();
        }

        // Owner enumeration.
        if (from != address(0)) _removeTokenFromOwnerEnumeration(from, tokenId);
        if (to != address(0)) _addTokenToOwnerEnumeration(to, tokenId);

        // Pin observed-min on transfer endpoints so the per-user non-AutoMax
        // floor reflects the live ownership state after the move. The
        // mint/burn endpoints pin via their callers (`createLock`,
        // `mergeLocks*`, `_unlockTo`); transfers are the only path that
        // changes lock-set membership for two addresses without going through
        // those entry points.
        if (from != address(0) && to != address(0)) {
            _pinShareholderObservedMin(from);
            _pinShareholderObservedMin(to);
        }
    }

    /// @dev Approvals are disabled: transfers are restricted to MineMarket -> Furnace only.
    function approve(address, uint256) public pure override {
        revert Errors.TransfersRestricted();
    }

    /// @dev Operator approvals are disabled: transfers are restricted to MineMarket -> Furnace only.
    function setApprovalForAll(address, bool) public pure override {
        revert Errors.TransfersRestricted();
    }

    function ownerOf(uint256 tokenId) public view override(ERC721, IVeClaimNFT) returns (address) {
        return super.ownerOf(tokenId);
    }

    /// @dev Disable renounceOwnership to prevent permanent bricking of
    ///      owner-only configuration (wiring, freeze, metadata).
    function renounceOwnership() public pure override {
        revert Errors.NotAuthorized();
    }

    /// @dev Reject EIP-7702 delegated EOAs from acquiring the owner role. A delegated
    ///      owner can let arbitrary callers exercise wiring + freeze and the metadata
    ///      surface after acceptance.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        _rejectDelegatedEOA(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Acceptance-time re-validation. A nominee that installs a 7702 delegation
    ///      designator between nomination and acceptance is rejected here so the owner
    ///      seat never lands on a delegated EOA.
    function acceptOwnership() public override {
        _rejectDelegatedEOA(msg.sender);
        super.acceptOwnership();
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _requireOwnedLock(uint256 tokenId, address user) internal view returns (Lock storage l) {
        if (_ownerOf(tokenId) != user) revert Errors.NotAuthorized();
        l = _locks[tokenId];
    }

    function _requireMutable(Lock storage l) internal view {
        if (l.listed) revert Errors.LockListedOrFrozen();

        // AutoMax locks never expire while autoMax is true.
        if (!l.autoMax && block.timestamp >= l.lockEnd) revert Errors.LockExpired();
    }

    // MAX_VE_NFTS_PER_USER is enforced both here (pre-mint fast-fail) and in _update()
    // post-mint (balanceOf(to) > MAX_VE_NFTS_PER_USER). The pre-check is a gas
    // optimization; the _update() check is the authoritative guard for transfers.
    function _createLock(address payer, address user, uint256 amount, uint256 duration, bool autoMax)
        internal
        returns (uint256 tokenId)
    {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.AmountZero();
        if (amount < Constants.MIN_LOCK_AMOUNT) revert Errors.MinLockAmountNotMet();
        if (duration < Constants.MIN_LOCK_DURATION || duration > Constants.MAX_LOCK_DURATION) {
            revert Errors.InvalidDuration();
        }
        if (autoMax && duration != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
        // Per SPEC v1.0.0: enforce per-address veNFT ownership cap to keep onchain veBalanceOf gas-bounded.
        if (balanceOf(user) >= Constants.MAX_VE_NFTS_PER_USER) revert Errors.TooManyVeNFTs();

        uint256 nowTs = block.timestamp;
        uint256 lockEnd = nowTs + (autoMax ? Constants.MAX_LOCK_DURATION : duration);

        _checkpointGlobalStateInternal();
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyalties(user);
        uint256 t = _globalLastTs;

        if (t != block.timestamp) revert Errors.CheckpointStale();

        int256 deltaSlope = 0;
        int256 deltaBias = 0;

        if (autoMax) {
            deltaBias = SafeCast.toInt256(amount * SLOPE_SCALE);
        } else {
            uint256 slope = _slopeScaledAdd(amount);
            uint256 bias = slope * _remainingAt(lockEnd, t);
            int256 slopeI = SafeCast.toInt256(slope);
            deltaSlope = slopeI;
            deltaBias = SafeCast.toInt256(bias);
            _applySlopeChangeDelta(lockEnd, slopeI);
        }

        _applyGlobalDelta(deltaSlope, deltaBias);

        _totalLockedClaim += amount;

        tokenId = _allocateTokenId();
        // _mint is used instead of _safeMint to avoid invoking onERC721Received, which
        // would open a reentrancy vector. `user` is expected to be an EOA by deployment
        // policy (not enforced on-chain).
        _mint(user, tokenId);
        _locks[tokenId] = Lock({amount: amount, lockStart: nowTs, lockEnd: lockEnd, autoMax: autoMax, listed: false});

        emit Events.LockCreated(user, tokenId, amount, lockEnd, autoMax);

        // CEI: pull CLAIM after all effects so any transfer callback sees consistent state.
        IERC20(claimToken).safeTransferFrom(payer, address(this), amount);

        // Pin the per-user observed-min against the live lock set so a fresh
        // non-AutoMax lock with a shorter `lockEnd` than the prior per-user
        // minimum narrows the global overflow watermark before the next
        // reward delta. Runs after the CLAIM pull so the lock set reflects the
        // newly-minted entry.
        _pinShareholderObservedMin(user);
    }

    function _addToLock(address payer, address user, uint256 tokenId, uint256 amount) internal {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.AmountZero();
        if (amount < Constants.MIN_TOPUP_AMOUNT) revert Errors.MinLockAmountNotMet();
        if (_ownerOf(tokenId) != user) revert Errors.NotAuthorized();

        Lock storage l = _locks[tokenId];
        _requireMutable(l);

        _checkpointGlobalStateInternal();
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyalties(user);
        uint256 t = _globalLastTs;

        if (t != block.timestamp) revert Errors.CheckpointStale();

        uint256 oldAmt = l.amount;
        uint256 newAmt = oldAmt + amount;

        int256 deltaSlope = 0;
        int256 deltaBias = 0;

        if (l.autoMax) {
            // AutoMax: ve increases 1:1 with principal, and never decays.
            deltaBias = SafeCast.toInt256(amount * SLOPE_SCALE);

            // `autoMax` stays true and ve stays proportional to `amount`; only `lockEnd` is refreshed.
            l.lockEnd = block.timestamp + Constants.MAX_LOCK_DURATION;
        } else {
            uint256 end = l.lockEnd;

            uint256 oldSlope = _slopeScaledAdd(oldAmt);
            uint256 newSlope = _slopeScaledAdd(newAmt);
            uint256 dSlope = newSlope - oldSlope;

            uint256 remaining = _remainingAt(end, t);
            uint256 dBias = dSlope * remaining;

            int256 dSlopeI = SafeCast.toInt256(dSlope);
            deltaSlope = dSlopeI;
            deltaBias = SafeCast.toInt256(dBias);
            _applySlopeChangeDelta(end, dSlopeI);
        }

        _applyGlobalDelta(deltaSlope, deltaBias);

        _totalLockedClaim += amount;

        l.amount = newAmt;
        l.lockStart = block.timestamp;

        emit Events.LockAmountIncreased(user, tokenId, amount);
        emit Events.MetadataUpdate(tokenId);

        // CEI: pull CLAIM after all effects so any transfer callback sees consistent state.
        IERC20(claimToken).safeTransferFrom(payer, address(this), amount);

        // Pin observed-min: an `addToLock` against an autoMax lock refreshes
        // `lockEnd` to MAX, but the lock still does not enter the non-AutoMax
        // set. A non-AutoMax `addToLock` does not move `lockEnd`, so this is
        // a no-op narrow when the lock set is unchanged. Either way, the pin
        // keeps the per-user observed-min in sync with the live ve state.
        _pinShareholderObservedMin(user);
    }

    // portion (newRem - oldRem). No decay reset — existing bias preserved, only extension added.
    function _extendLockToInternal(address user, uint256 tokenId, Lock storage l, uint256 newEnd) internal {
        uint256 oldEnd = l.lockEnd;
        if (newEnd <= oldEnd) revert Errors.InvalidDuration();

        _checkpointGlobalStateInternal();
        // slither-disable-next-line reentrancy-no-eth
        _checkpointShareholderRoyalties(user);
        uint256 t = _globalLastTs;

        if (t != block.timestamp) revert Errors.CheckpointStale();

        uint256 amt = l.amount;
        uint256 slope = _slopeScaledAdd(amt);

        uint256 oldRem = _remainingAt(oldEnd, t);
        uint256 newRem = _remainingAt(newEnd, t);
        uint256 deltaBias = slope * (newRem - oldRem);

        _applyGlobalDelta(0, SafeCast.toInt256(deltaBias));
        int256 slopeI = SafeCast.toInt256(slope);
        _applySlopeChangeDelta(oldEnd, -slopeI);
        _applySlopeChangeDelta(newEnd, slopeI);

        l.lockEnd = newEnd;
        l.lockStart = block.timestamp;

        emit Events.LockExtended(user, tokenId, oldEnd, newEnd);
        emit Events.MetadataUpdate(tokenId);

        // Extending a lock can widen the per-user observed-min when the
        // extended lock was the prior tightest non-AutoMax floor. Pin so the
        // global watermark sees the wider per-user value on the next
        // exhaustive aggregate sweep.
        _pinShareholderObservedMin(user);
    }

    function _checkpointGlobalStateInternal() internal {
        uint256 nowTs = block.timestamp;
        uint256 t = _globalLastTs;
        if (t == 0) t = nowTs;

        // When many slope changes are pending (e.g., many locks expired during a long period
        // without checkpoint), _globalLastTs stays pinned at the last processed timestamp.
        // Subsequent lock mutations will operate against stale global state until the backlog
        // is cleared by repeated calls to checkpointGlobalState() or checkpointTotalVe().
        // The MineCore gas-guarded loop uses globalLastTs() to detect staleness.
        uint256 i = 0;
        while (i < Constants.MAX_SLOPE_CHANGES_PER_CALL) {
            uint256 nextTime = _heapMin();
            if (nextTime == 0 || nextTime > nowTs) break;

            // Decay bias to nextTime. Overflow-safe: avoid raw slope*dt when it could overflow.
            uint256 dt = nextTime - t;
            if (dt > 0) {
                _applyDecayToBias(dt);
            }

            t = nextTime;

            // Apply scheduled slope removal.
            uint256 sc = _slopeChanges[nextTime];
            if (sc != 0) {
                if (sc >= _globalSlopeScaled) {
                    emit Events.SlopeDriftClamped(nextTime, sc, _globalSlopeScaled);
                    _globalSlopeScaled = 0;
                } else {
                    _globalSlopeScaled -= sc;
                }
                delete _slopeChanges[nextTime];
            }

            _heapPopMin();
            unchecked {
                ++i;
            }
        }

        // If caught up (no pending slope changes in the past), decay to now.
        uint256 head = _heapMin();
        if (head == 0 || head > nowTs) {
            uint256 dt2 = nowTs - t;
            if (dt2 > 0) {
                _applyDecayToBias(dt2);
            }
            _globalLastTs = nowTs;
        } else {
            // Backlog remains; keep time pinned to last fully-processed timestamp.
            _globalLastTs = t;
        }

        _syncTotalVeCached();
    }

    /// @dev Overflow-safe decay: if dt >= ceilDiv(bias, slope) then bias = 0; else bias -= slope*dt.
    ///      Avoids slope*dt overflow by checking in division space first.
    function _applyDecayToBias(uint256 dt) internal {
        uint256 slope = _globalSlopeScaled;
        uint256 bias = _globalBiasScaled;
        if (slope == 0) return;

        uint256 dtToZero = Math.ceilDiv(bias, slope);
        if (dt >= dtToZero) {
            _globalBiasScaled = 0;
            return;
        }
        // dt < dtToZero implies slope*dt < bias. Guard against mul overflow (dt huge).
        if (dt > type(uint256).max / slope) {
            _globalBiasScaled = 0;
            return;
        }
        uint256 decay = slope * dt;
        _globalBiasScaled = decay >= bias ? 0 : bias - decay;
    }

    /// @dev Allocate a new token id.
    ///      Token ids MUST be monotonic and never reused (even after burn) because offchain indexers
    ///      and UIs commonly use tokenId as a stable primary key.
    function _allocateTokenId() internal returns (uint256 tokenId) {
        tokenId = _nextTokenId;
        _nextTokenId = tokenId + 1;
    }

    // amount * SLOPE_SCALE / MAX_LOCK_DURATION. The ceil-on-add / floor-on-remove convention
    // leaves two conservative dust sources in _globalSlopeScaled:
    //   1. Up to 1 scaled unit per active non-AutoMax lock from the per-lock ceil/floor gap.
    //   2. Up to 1 scaled unit per pending early-removal event parked in _slopeChanges[lockEnd]
    //      until the checkpoint loop drains that bucket.
    // This keeps total ve slightly overstated (safe for ShareholderRoyalties denominator use)
    // and means _globalSlopeScaled may never reach exactly 0 after all locks expire.
    // _applyDecayToBias() handles the residual tail gracefully by clamping to 0 when bias
    // would otherwise underflow, so no revert risk exists.
    /// @dev Scaled slope for ADD paths (lock creation, top-up, merge destination, extend).
    ///      Rounds UP so the global aggregate is conservative (overestimates total ve).
    function _slopeScaledAdd(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Ceil);
    }

    /// @dev Scaled slope for REMOVE paths (unlock, merge source, burn).
    ///      Rounds DOWN so we never subtract more slope than was added.
    ///      NOTE: This can leave up to 1 wei of residual slope in
    ///      _slopeChanges[lockEnd] (and a corresponding phantom heap entry)
    ///      when the add-path used Ceil rounding. The checkpoint loop
    ///      processes these harmlessly; see _applyDecayToBias clamp logic.
    function _slopeScaledRemove(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Floor);
    }

    function _remainingAt(uint256 end, uint256 t) internal pure returns (uint256) {
        return end > t ? (end - t) : 0;
    }

    /// @dev Sync the cached total ve to the current scaled global bias.
    ///
    /// Why this matters:
    /// - `totalVeCached()` is used as a **denominator** (e.g. ShareholderRoyalties).
    /// - If it is stale and **too low** after a lock mutation, pro-rata math can
    ///   over-credit indices and create insolvency/reverts.
    ///
    /// This helper keeps `totalVeCached` conservative by rounding **UP**.
    function _syncTotalVeCached() internal {
        _totalVeCached = Math.ceilDiv(_globalBiasScaled, SLOPE_SCALE);
    }

    /// @dev Apply a signed delta to the global slope/bias aggregates.
    ///      Reverts with InvariantViolation on underflow (invariant break).
    function _applyGlobalDelta(int256 dSlope, int256 dBias) internal {
        if (dSlope != 0) {
            if (dSlope > 0) {
                _globalSlopeScaled += SafeCast.toUint256(dSlope);
            } else {
                // dSlope cannot be int256.min in this system (it originates from SafeCast'ed uint256 slopes),
                // but guard anyway to avoid unary negation overflow.
                if (dSlope == type(int256).min) revert Errors.InvariantViolation();
                uint256 sub = SafeCast.toUint256(-dSlope);
                if (sub > _globalSlopeScaled) revert Errors.InvariantViolation();
                _globalSlopeScaled -= sub;
            }
        }

        if (dBias != 0) {
            if (dBias > 0) {
                _globalBiasScaled += SafeCast.toUint256(dBias);
            } else {
                // dBias cannot be int256.min in this system (it originates from SafeCast'ed uint256 biases),
                // but guard anyway to avoid unary negation overflow.
                if (dBias == type(int256).min) revert Errors.InvariantViolation();
                uint256 sub = SafeCast.toUint256(-dBias);
                if (sub > _globalBiasScaled) revert Errors.InvariantViolation();
                _globalBiasScaled -= sub;
            }

            // Keep cached denom conservative and in sync after any bias mutation.
            _syncTotalVeCached();
        }
    }

    function _applySlopeChangeDelta(uint256 when, int256 deltaSlope) internal {
        if (deltaSlope == 0) return;
        uint256 t = when;

        uint256 cur = _slopeChanges[t];
        uint256 next;
        if (deltaSlope > 0) {
            next = cur + SafeCast.toUint256(deltaSlope);
        } else {
            if (deltaSlope == type(int256).min) revert Errors.InvariantViolation();
            uint256 sub = SafeCast.toUint256(-deltaSlope);
            if (sub > cur) revert Errors.InvariantViolation();
            next = cur - sub;
        }

        if (next == 0) {
            delete _slopeChanges[t];
            if (_slopeTimeIndex[t] != 0) _heapRemove(t);
        } else {
            _slopeChanges[t] = next;
            if (_slopeTimeIndex[t] == 0) _heapInsert(t);
        }
    }

    function _heapMin() internal view returns (uint256) {
        if (_slopeTimeHeap.length <= 1) return 0;
        return _slopeTimeHeap[1];
    }

    // duplicate inserts are no-ops. Shared lockEnd times aggregate slopes in
    // _slopeChanges[lockEnd] — the heap entry is shared. No timestamp-collision attack vector.
    function _heapInsert(uint256 t) internal {
        // t == 0 would collide with the sentinel and is invalid for real slope times.
        if (t == 0) revert Errors.InvariantViolation();
        if (_slopeTimeIndex[t] != 0) return;

        _slopeTimeHeap.push(t);
        uint256 idx = _slopeTimeHeap.length - 1;
        _slopeTimeIndex[t] = idx;
        _heapifyUp(idx);
    }

    function _heapPopMin() internal returns (uint256 minTime) {
        if (_slopeTimeHeap.length <= 1) return 0;
        minTime = _slopeTimeHeap[1];
        _heapRemove(minTime);
    }

    function _heapRemove(uint256 t) internal {
        uint256 idx = _slopeTimeIndex[t];
        if (idx == 0) return;

        uint256 lastIdx = _slopeTimeHeap.length - 1;
        uint256 lastVal = _slopeTimeHeap[lastIdx];

        // Remove element t.
        _slopeTimeIndex[t] = 0;

        if (idx == lastIdx) {
            _slopeTimeHeap.pop();
            return;
        }

        _slopeTimeHeap[idx] = lastVal;
        _slopeTimeIndex[lastVal] = idx;
        _slopeTimeHeap.pop();

        // Restore heap property.
        uint256 parent = idx / 2;
        if (idx > 1 && _slopeTimeHeap[idx] < _slopeTimeHeap[parent]) {
            _heapifyUp(idx);
        } else {
            _heapifyDown(idx);
        }
    }

    function _heapifyUp(uint256 idx) internal {
        uint256 val = _slopeTimeHeap[idx];
        while (idx > 1) {
            uint256 parent = idx / 2;
            uint256 parentVal = _slopeTimeHeap[parent];
            if (parentVal <= val) break;

            _slopeTimeHeap[idx] = parentVal;
            _slopeTimeIndex[parentVal] = idx;
            idx = parent;
        }
        _slopeTimeHeap[idx] = val;
        _slopeTimeIndex[val] = idx;
    }

    function _heapifyDown(uint256 idx) internal {
        uint256 size = _slopeTimeHeap.length - 1;
        uint256 val = _slopeTimeHeap[idx];

        while (true) {
            uint256 left = idx * 2;
            if (left > size) break;
            uint256 right = left + 1;

            uint256 smallest = left;
            uint256 smallestVal = _slopeTimeHeap[left];

            if (right <= size) {
                uint256 rightVal = _slopeTimeHeap[right];
                if (rightVal < smallestVal) {
                    smallest = right;
                    smallestVal = rightVal;
                }
            }

            if (val <= smallestVal) break;

            _slopeTimeHeap[idx] = smallestVal;
            _slopeTimeIndex[smallestVal] = idx;
            idx = smallest;
        }

        _slopeTimeHeap[idx] = val;
        _slopeTimeIndex[val] = idx;
    }

    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) internal {
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
    }

    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) internal {
        uint256 lastIndex = _ownedTokens[from].length - 1;
        uint256 index = _ownedTokensIndex[tokenId];

        if (index != lastIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastIndex];
            _ownedTokens[from][index] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = index;
        }

        _ownedTokens[from].pop();
        // Skip delete: token IDs are monotonic and never reused, so this
        // mapping slot will never be read again after burn. Saves ~2,100
        // gas (avoids a cold SSTORE-to-zero that yields no future benefit).
        // For transfer paths (non-burn), the slot IS re-populated by
        // _addTokenToOwnerEnumeration on the receiver side, so the stale
        // value is harmless either way.
    }
}
