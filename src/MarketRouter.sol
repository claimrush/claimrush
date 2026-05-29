// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Errors} from "./lib/Errors.sol";
import {SafeApprove} from "./lib/SafeApprove.sol";
import {SafeERC20View} from "./lib/SafeERC20View.sol";
import {Events} from "./lib/Events.sol";
import {Constants} from "./lib/Constants.sol";
import {IClaimToken} from "./interfaces/IClaimToken.sol";
import {IFurnace} from "./interfaces/IFurnace.sol";
import {IFurnaceQuoter} from "./interfaces/IFurnaceQuoter.sol";
import {IShareholderRoyalties} from "./interfaces/IShareholderRoyalties.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IMarketRouter} from "./interfaces/IMarketRouter.sol";
import {UpgradeableProtocolBase} from "./lib/UpgradeableProtocolBase.sol";

interface IMarketRouterFreezeView {
    function mineMarket() external view returns (address);
    function furnace() external view returns (address);
}

/// @notice veCLAIM marketplace with 0% fee, CLAIM-only prices, and global buy orders.
/// @dev This contract is the canonical marketplace router address referenced as `MarketRouter` in docs and manifests.
///      High-trust surface: may escrow CLAIM for global-offer budgets.
///      Value-out-only: this contract does not accept ETH (no receive/fallback) or safe ERC721 receives
///      (no onERC721Received). Any ETH / NFT / non-CLAIM ERC20 misdirected here is pinned; non-CLAIM
///      ERC20s can be owner-rescued via recoverToken, ETH and NFTs cannot.
contract MarketRouter is UpgradeableProtocolBase, IMarketRouter {
    using SafeERC20 for IERC20;

    /// @dev Gas forwarded to Furnace quote staticcalls. Caps quoter work to prevent DoS.
    uint256 internal constant QUOTE_STATICCALL_GAS_LIMIT = 1_100_000;

    bytes4 internal constant _SEL_MINE_MARKET = bytes4(keccak256("mineMarket()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_CLAIM_TOKEN = bytes4(keccak256("claimToken()"));
    bytes4 internal constant _SEL_ROYALTIES = bytes4(keccak256("royalties()"));
    bytes4 internal constant _SEL_SHAREHOLDER_ROYALTIES = bytes4(keccak256("shareholderRoyalties()"));

    IClaimToken public immutable claim;
    IVeClaimNFT public immutable ve;
    IShareholderRoyalties public immutable royalties;

    address public guardian; // trading-pause surface + emergency self-rotation
    bool public tradingPaused;

    mapping(address => bool) public isSettlementKeeper;

    // 1-block cooldown between listing state changes (any function that calls _enforceListingCooldown)
    mapping(uint256 => uint256) public lastListingActionBlock;

    struct BonusTargetConfig {
        uint256 targetBonusBps;
        uint256 slippageBps;
        bool configured;
    }

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => BonusTargetEscrow) public offers;
    mapping(uint256 => BonusTargetConfig) public bonusTargetConfigs;

    uint256 public nextOfferId = 1;

    // Global offer spam-control parameters (owner-managed governance config)
    uint256 public minBonusTargetEscrowBudget;
    uint256 public maxBonusTargetEscrowDiscountBps; // set to 10_000 to disable extra cap

    // Active listings / offers index (for view helpers)
    mapping(address => uint256[]) private _userListings;
    mapping(uint256 => uint256) private _userListingIndexPlusOne; // tokenId => index+1

    mapping(address => uint256[]) private _userBonusTargetEscrows;
    mapping(uint256 => uint256) private _userOfferIndexPlusOne; // offerId => index+1

    /// @dev Runtime delegate-EOA guard mirrors the seating-time check in
    ///      `setGuardian()`. A clean EOA guardian that installs an EIP-7702
    ///      designator after seating exposes guardian-only pause / role calls
    ///      to arbitrary callers; this re-checks the prefix on every
    ///      guardian-only entry. Cost: one `extcodecopy` per call.
    modifier onlyGuardian() {
        address sender = msg.sender;
        if (sender != guardian) revert Errors.OnlyGuardian();
        _rejectDelegatedEOA(sender);
        _;
    }

    modifier whenTradingEnabled() {
        if (tradingPaused) revert Errors.TradingPaused();
        _;
    }

    /// @dev Reject EIP-7702 delegation designators on roots and on the runtime
    ///      guardian seat. The 7702 designator is exactly 23 bytes and starts
    ///      with `0xEF0100`. Bare EOAs (`code.length == 0`) are still permitted —
    ///      this only catches the delegation case.
    function _rejectDelegatedEOA(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    constructor(address _claim, address _ve, address _royalties, address initialOwner) {
        if (_claim == address(0) || _ve == address(0) || _royalties == address(0)) {
            revert Errors.ZeroAddress();
        }

        // Defensive: these roots participate in no-return external calls (e.g.
        // royalties.checkpointTransfer(...)). If accidentally wired to an EOA, calls can succeed
        // silently and violate accounting invariants.
        if (!_isContract(_claim) || !_isContract(_ve) || !_isContract(_royalties)) {
            revert Errors.NotAContract();
        }
        _rejectDelegatedEOA(_claim);
        _rejectDelegatedEOA(_ve);
        _rejectDelegatedEOA(_royalties);

        // Root hardening: reject split-brain CLAIM/ve/royalties trees at deployment time so every
        // proxy implementation keeps the canonical asset bundle baked into immutable bytecode.
        if (_staticcallAddress(_ve, _SEL_CLAIM_TOKEN) != _claim || _staticcallAddress(_royalties, _SEL_VE) != _ve) {
            revert Errors.WiringMismatch();
        }

        claim = IClaimToken(_claim);
        ve = IVeClaimNFT(_ve);
        royalties = IShareholderRoyalties(_royalties);

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
        guardian = initialOwner;
        nextOfferId = 1;

        // Initialize global offer parameters to protocol defaults.
        minBonusTargetEscrowBudget = Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET;
        maxBonusTargetEscrowDiscountBps = Constants.DEFAULT_MAX_BONUS_TARGET_ESCROW_DISCOUNT_BPS;
    }

    // Admin

    function setGuardian(address _guardian) external {
        address sender = msg.sender;
        if (sender == owner()) {
            // Runtime 7702 reject on the caller seat. The owner branch does not
            // route through `onlyOwner`, so apply the same guard `_checkOwner`
            // runs for owner-only entry points.
            _validateNewOwner(sender);
        } else if (sender == guardian) {
            // guardian-rotation path: re-run the runtime delegate guard so a
            // post-seating 7702 install cannot route a self-rotation through
            // the guardian role.
            _rejectDelegatedEOA(sender);
        } else {
            revert Errors.NotAuthorized();
        }
        if (_guardian == address(0)) revert Errors.ZeroAddress();
        // The router itself cannot call guardian-gated functions, so self-assignment would brick
        // the trading pause surface until the owner rotates it back.
        if (_guardian == address(this)) revert Errors.NotAuthorized();
        // Reject EIP-7702 delegated EOAs from the guardian seat. The 7702 designator's target can
        // be re-pointed off-chain at any time, which would silently change who controls the
        // trading-pause surface. Bare EOAs (code.length == 0) and normal contracts are unaffected.
        _rejectDelegatedEOA(_guardian);
        address oldGuardian = guardian;
        guardian = _guardian;
        emit Events.GuardianChanged(oldGuardian, _guardian);
    }

    /// @dev MarketRouter is operationally replaceable via owner-driven redeploy + rewire.
    ///      Renouncing ownership would permanently disable that path, the settlement-keeper
    ///      allowlist, and the documented owner break-glass during grace windows.
    function renounceOwnership() public pure {
        revert Errors.NotAuthorized();
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory (prevents "return data bomb" griefing).
    ///      Gas-bounded: forwards at most 200 000 gas to prevent untrusted callees from consuming
    ///      the caller's entire gas budget during wiring checks.
    ///      NOTE: 200k gas is ample for standard proxies but may be tight for deeply nested
    ///      proxy chains. If spurious WiringMismatch reverts appear after a proxy architecture change,
    ///      consider increasing this constant.
    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)

            let success := staticcall(200000, target, ptr, 0x04, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    out := and(mload(ptr), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    /// @dev Robust contract-existence check resistant to CREATE2 pre-deployment and
    ///      post-selfdestruct edge cases. Returns false for EOAs, precompiles, and
    ///      addresses whose code was destroyed via selfdestruct within the same tx.
    function _isContract(address addr) internal view returns (bool) {
        if (addr == address(0)) return false;
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(addr)
        }
        if (size == 0) return false;
        bytes32 codehash;
        assembly ("memory-safe") {
            codehash := extcodehash(addr)
        }
        // keccak256("") is the codehash of an account with no code (EOA or selfdestructed)
        return codehash != 0 && codehash != keccak256("");
    }

    /// @dev Resolve the canonical Furnace used for strict-mode settlement and auto-furnace execution.
    ///      Runtime hardening: reject split-brain Furnace / MineCore / royalties bundles by
    ///      verifying every reciprocal edge of the canonical asset bundle. The check fully defends
    ///      against an externally-deployed impostor that cannot be written into a peer's canonical
    ///      pointer storage. A coherently-rewired peer bundle authored by the admin passes this
    ///      check, so during any interval in which peer setters remain unfrozen, chain integrity
    ///      additionally rests on admin-key hygiene. The freeze surface on each peer is one-way;
    ///      once called, rewire becomes impossible and this check is cryptographically complete.
    function _requireCanonicalFurnace() internal view returns (address furnaceAddr) {
        furnaceAddr = _staticcallAddress(address(ve), _SEL_FURNACE);
        if (furnaceAddr == address(0)) revert Errors.ZeroAddress();
        if (!_isContract(furnaceAddr)) revert Errors.NotAContract();

        // Verify ve.mineMarket still points to this router.
        if (_staticcallAddress(address(ve), _SEL_MINE_MARKET) != address(this)) {
            revert Errors.WiringMismatch();
        }

        if (!_isContract(address(claim)) || !_isContract(address(ve)) || !_isContract(address(royalties))) {
            revert Errors.NotAContract();
        }

        address sr = address(royalties);
        address core = _staticcallAddress(sr, _SEL_MINE_CORE);
        if (core == address(0)) revert Errors.ZeroAddress();
        if (!_isContract(core)) revert Errors.NotAContract();

        if (
            _staticcallAddress(furnaceAddr, _SEL_VE) != address(ve)
                || _staticcallAddress(furnaceAddr, _SEL_CLAIM) != address(claim)
                || _staticcallAddress(furnaceAddr, _SEL_MINE_MARKET) != address(this)
                || _staticcallAddress(furnaceAddr, _SEL_MINE_CORE) != core
                || _staticcallAddress(furnaceAddr, _SEL_SHAREHOLDER_ROYALTIES) != sr
                || _staticcallAddress(sr, _SEL_MINE_MARKET) != address(this)
                || _staticcallAddress(sr, _SEL_FURNACE) != furnaceAddr || _staticcallAddress(sr, _SEL_VE) != address(ve)
                || _staticcallAddress(core, _SEL_FURNACE) != furnaceAddr
                || _staticcallAddress(core, _SEL_ROYALTIES) != sr
                || _staticcallAddress(core, _SEL_CLAIM) != address(claim)
                || _staticcallAddress(core, _SEL_VE) != address(ve)
                || _staticcallAddress(address(claim), _SEL_MINE_CORE) != core
        ) {
            revert Errors.WiringMismatch();
        }
    }

    /// @dev Non-reverting probe used by stale-router unwind paths.
    ///      Returns false when this router is no longer the live canonical market surface
    ///      for the current Furnace / ShareholderRoyalties / MineCore / ve / CLAIM bundle.
    function _isCanonicalOfferLifecycleRouter() internal view returns (bool) {
        address furnaceAddr = _staticcallAddress(address(ve), _SEL_FURNACE);
        if (furnaceAddr == address(0) || !_isContract(furnaceAddr)) return false;

        // Symmetric stale detection via ve.mineMarket.
        if (_staticcallAddress(address(ve), _SEL_MINE_MARKET) != address(this)) return false;

        address sr = address(royalties);
        if (!_isContract(address(claim)) || !_isContract(address(ve)) || !_isContract(sr)) return false;
        address core = _staticcallAddress(sr, _SEL_MINE_CORE);
        if (core == address(0) || !_isContract(core)) return false;

        return _staticcallAddress(furnaceAddr, _SEL_VE) == address(ve)
            && _staticcallAddress(furnaceAddr, _SEL_CLAIM) == address(claim)
            && _staticcallAddress(furnaceAddr, _SEL_MINE_MARKET) == address(this)
            && _staticcallAddress(furnaceAddr, _SEL_MINE_CORE) == core
            && _staticcallAddress(furnaceAddr, _SEL_SHAREHOLDER_ROYALTIES) == sr
            && _staticcallAddress(sr, _SEL_MINE_MARKET) == address(this)
            && _staticcallAddress(sr, _SEL_FURNACE) == furnaceAddr && _staticcallAddress(sr, _SEL_VE) == address(ve)
            && _staticcallAddress(core, _SEL_FURNACE) == furnaceAddr && _staticcallAddress(core, _SEL_ROYALTIES) == sr
            && _staticcallAddress(core, _SEL_CLAIM) == address(claim)
            && _staticcallAddress(core, _SEL_VE) == address(ve)
            && _staticcallAddress(address(claim), _SEL_MINE_CORE) == core;
    }

    /// @dev Gas-bounded exact-size quoter staticcall.
    ///      Never copies arbitrary revertdata/returndata into memory and requires the canonical
    ///      fixed-size 4-word return payload used by MarketRouter's Furnace quote paths.
    function _staticcallQuoteExact(address target, bytes memory callData)
        internal
        view
        returns (uint256 a, uint256 b, uint256 c, uint256 d)
    {
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            ok := staticcall(QUOTE_STATICCALL_GAS_LIMIT, target, add(callData, 0x20), mload(callData), 0, 0)
            ok := and(ok, eq(returndatasize(), 0x80))
            if ok {
                returndatacopy(ptr, 0, 0x80)
                a := mload(ptr)
                b := mload(add(ptr, 0x20))
                c := mload(add(ptr, 0x40))
                d := mload(add(ptr, 0x60))
            }
        }
        if (!ok) revert Errors.QuoteCallFailed();
    }

    function setBonusTargetEscrowParams(uint256 _minBonusTargetEscrowBudget, uint256 _maxBonusTargetEscrowDiscountBps)
        external
        onlyOwner
    {
        if (_minBonusTargetEscrowBudget == 0) revert Errors.BudgetTooSmall();
        if (_maxBonusTargetEscrowDiscountBps > Constants.BPS_DENOM) revert Errors.DiscountTooHigh();

        // Governance safety: minimums are increase-only (docs/spec + env-config).
        if (_minBonusTargetEscrowBudget < minBonusTargetEscrowBudget) revert Errors.DecreaseNotAllowed();

        uint256 MAX_BONUS_TARGET_ESCROW_BUDGET_CAP = 1_000_000e18;
        if (_minBonusTargetEscrowBudget > MAX_BONUS_TARGET_ESCROW_BUDGET_CAP) revert Errors.BudgetTooHigh();

        uint256 oldBudget = minBonusTargetEscrowBudget;
        uint256 oldDiscount = maxBonusTargetEscrowDiscountBps;

        minBonusTargetEscrowBudget = _minBonusTargetEscrowBudget;
        maxBonusTargetEscrowDiscountBps = _maxBonusTargetEscrowDiscountBps;

        emit Events.BonusTargetEscrowParamsChanged(
            oldBudget, _minBonusTargetEscrowBudget, oldDiscount, _maxBonusTargetEscrowDiscountBps
        );
    }

    function pauseTrading(bool paused) external onlyGuardian {
        if (paused == tradingPaused) return;
        tradingPaused = paused;
        emit Events.TradingPausedChanged(paused);
    }

    function setSettlementKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert Errors.ZeroAddress();
        // Reject EIP-7702 delegated EOAs as new keeper seats. A delegated keeper
        // would let any caller execute through `keeper`, bypassing the MEV-protected
        // grace window and the listing/offer keeper-priority gates. Revocations
        // (`allowed == false`) are still permitted against an address that became
        // delegated after seating, so an operator can clear an existing seat.
        if (allowed) _rejectDelegatedEOA(keeper);
        isSettlementKeeper[keeper] = allowed;
        emit Events.SettlementKeeperSet(keeper, allowed);
    }

    /// @notice Owner-only: recover non-CLAIM tokens accidentally sent to this contract.
    /// @dev CLAIM itself cannot be recovered. Any CLAIM directly sent to the router (outside
    ///      `createBonusTargetEscrowWithTarget`) is pinned dust and does not participate in offer
    ///      accounting. The escrow solvency invariant compares active-offer budgets against the
    ///      router's CLAIM balance as a lower bound (>=), so pinned dust is safe for the invariant.
    function recoverToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (token == address(claim)) revert Errors.NotAuthorized();
        IERC20(token).safeTransfer(to, amount);
    }

    // View helpers (SPEC §8.6)

    function getListing(uint256 tokenId) external view returns (Listing memory) {
        return listings[tokenId];
    }

    function getUserListings(address user) external view returns (uint256[] memory) {
        return _userListings[user];
    }

    function getUserListingsPaginated(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, bool hasMore)
    {
        return _sliceUintArray(_userListings[user], offset, limit);
    }

    function getBonusTargetEscrow(uint256 offerId) external view returns (BonusTargetEscrow memory) {
        return offers[offerId];
    }

    function getUserBonusTargetEscrows(address user) external view returns (uint256[] memory) {
        return _userBonusTargetEscrows[user];
    }

    function getUserBonusTargetEscrowsPaginated(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, bool hasMore)
    {
        return _sliceUintArray(_userBonusTargetEscrows[user], offset, limit);
    }

    /// @notice Sum of all active offers' fundsRemaining for off-chain monitoring.
    /// @dev Gas-unbounded — intended for off-chain use only.
    function totalEscrowedClaim() external view returns (uint256 total) {
        uint256 maxId = nextOfferId;
        for (uint256 i = 1; i < maxId; ++i) {
            BonusTargetEscrow storage offer = offers[i];
            if (offer.active) {
                total += offer.fundsRemaining;
            }
        }
    }

    /// @notice Paginated version of totalEscrowedClaim for on-chain safety.
    /// @param startId First offer ID to scan (inclusive, minimum 1).
    /// @param endId   Last offer ID to scan (exclusive, capped at nextOfferId).
    function totalEscrowedClaimPaginated(uint256 startId, uint256 endId) external view returns (uint256 total) {
        uint256 maxId = nextOfferId;
        if (endId > maxId) endId = maxId;
        if (startId < 1) startId = 1;
        if (startId >= endId) return 0;
        for (uint256 i = startId; i < endId; ++i) {
            BonusTargetEscrow storage offer = offers[i];
            if (offer.active) {
                total += offer.fundsRemaining;
            }
        }
    }

    // Listings (SPEC §8.2)

    function listLock(uint256 tokenId, uint256 minClaimOut, uint256 expiresAtTime)
        external
        nonReentrant
        whenTradingEnabled
    {
        if (minClaimOut == 0) revert Errors.AmountZero();
        if (expiresAtTime <= block.timestamp) revert Errors.InvalidListingExpiry();
        _enforceListingCooldown(tokenId);

        address tokenOwner = _requireTokenOwner(tokenId);
        if (tokenOwner != msg.sender) revert Errors.NotAuthorized();
        uint256 lockEnd;
        bool listed;
        (, lockEnd,, listed) = ve.getLockInfo(tokenId);
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();
        if (expiresAtTime > lockEnd) revert Errors.InvalidListingExpiry();
        if (listed) revert Errors.LockListedOrFrozen();

        listings[tokenId] = Listing({
            seller: msg.sender,
            minClaimOut: minClaimOut,
            listedAtTime: block.timestamp,
            expiresAtTime: expiresAtTime,
            active: true
        });
        lastListingActionBlock[tokenId] = block.number;
        _addUserListing(msg.sender, tokenId);

        ve.setListed(tokenId, true);
        emit Events.LockListed(tokenId, msg.sender, minClaimOut, block.timestamp, expiresAtTime);
    }

    /// @dev MUST remain callable even when trading is paused.
    function delistLock(uint256 tokenId) external nonReentrant {
        _enforceListingCooldown(tokenId);

        Listing storage lst = listings[tokenId];
        if (!lst.active) {
            // Router-replacement rescue: when local listing storage has no record for this token
            // but VeClaimNFT still reports `listed == true`, the token owner can clear the stale
            // ve-level flag so the lock can be unlocked / maintained without forcing a sale.
            address tokenOwner = _requireTokenOwner(tokenId);
            if (tokenOwner != msg.sender) revert Errors.NotAuthorized();

            (,,, bool listed) = ve.getLockInfo(tokenId);
            if (!listed) revert Errors.ListingNotActive();

            lastListingActionBlock[tokenId] = block.number;
            ve.setListed(tokenId, false);
            emit Events.LockDelisted(tokenId, tokenOwner, Constants.LOCK_DELIST_REASON_NORMAL);
            return;
        }

        address seller = lst.seller;
        if (seller != msg.sender) revert Errors.NotAuthorized();

        uint8 reason = block.timestamp >= lst.expiresAtTime
            ? Constants.LOCK_DELIST_REASON_EXPIRED
            : Constants.LOCK_DELIST_REASON_NORMAL;
        _clearListing(tokenId, seller);
        ve.setListed(tokenId, false);
        emit Events.LockDelisted(tokenId, seller, reason);
    }

    /// @notice Permissionless: cancel an expired listing and clear the veNFT listed flag.
    /// @dev MUST remain callable even when trading is paused.
    function cancelExpiredListing(uint256 tokenId) external nonReentrant {
        _enforceListingCooldown(tokenId);

        Listing storage lst = listings[tokenId];
        if (!lst.active) revert Errors.ListingNotActive();
        if (block.timestamp < lst.expiresAtTime) revert Errors.ListingNotExpired();

        address seller = lst.seller;
        _clearListing(tokenId, seller);
        ve.setListed(tokenId, false);
        emit Events.LockDelisted(tokenId, seller, Constants.LOCK_DELIST_REASON_EXPIRED);
    }

    /// @notice Batch-cancel expired listings. Best-effort: ineligible items are silently skipped.
    /// @dev MUST remain callable even when trading is paused.
    function cancelExpiredListingBatch(uint256[] calldata tokenIds) external nonReentrant {
        // Best-effort batch: caller controls array length and pays gas.
        uint256 n = tokenIds.length;
        for (uint256 i = 0; i < n;) {
            uint256 tokenId = tokenIds[i];
            Listing storage lst = listings[tokenId];
            if (lst.active && block.timestamp >= lst.expiresAtTime) {
                address seller = lst.seller;
                _clearListing(tokenId, seller);
                // slither-disable-next-line reentrancy-no-eth
                ve.setListed(tokenId, false);
                emit Events.LockDelisted(tokenId, seller, Constants.LOCK_DELIST_REASON_EXPIRED);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Permissionless: clear a zombie listing where local state is active but
    ///         the ve-level listed flag has been cleared externally.
    /// @dev MUST remain callable even when trading is paused.
    function cleanupStaleListing(uint256 tokenId) external nonReentrant {
        _enforceListingCooldown(tokenId);

        Listing storage lst = listings[tokenId];
        if (!lst.active) revert Errors.ListingNotActive();

        (,,, bool listed) = ve.getLockInfo(tokenId);
        if (listed) revert Errors.LockListedOrFrozen();

        address seller = lst.seller;
        _clearListing(tokenId, seller);
        emit Events.LockDelisted(tokenId, seller, Constants.LOCK_DELIST_REASON_NORMAL);
    }

    // Sell to Furnace (Strict Mode: Furnace is the only buyer)

    /// @notice Sell an unlisted (or listed) lock directly to the Furnace.
    /// @dev Callable only by the current veNFT holder (`msg.sender` must own `tokenId`).
    ///      If the lock is listed, auto-delists first.
    ///      MarketRouter transfers the veNFT to Furnace custody and calls sellLockToFurnaceFromMarket.
    /// @param tokenId The veNFT token id to sell.
    /// @param minClaimOut Minimum CLAIM payout (slippage protection).
    /// @param deadline Latest acceptable `block.timestamp` for the call.
    /// @return claimOut Actual CLAIM payout to the seller.
    function sellLockToFurnace(uint256 tokenId, uint256 minClaimOut, uint256 deadline)
        external
        nonReentrant
        whenTradingEnabled
        returns (uint256 claimOut)
    {
        if (block.timestamp > deadline) revert Errors.DeadlineExpired();
        address seller = _requireTokenOwner(tokenId);
        if (seller != msg.sender) revert Errors.NotAuthorized();

        address furnaceAddr = _requireCanonicalFurnace();

        // Defense-in-depth: reject expired or empty locks before transferring to Furnace.
        (uint256 lockAmount, uint256 lockEnd,,) = ve.getLockInfo(tokenId);
        if (lockAmount == 0) revert Errors.InvalidToken();
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();

        // Auto-delist if listed (clears internal listing + ve flag).
        _autoDelistForSale(tokenId);

        // Checkpoint royalties before transfer.
        royalties.checkpointTransfer(seller, furnaceAddr);

        // Transfer veNFT to Furnace custody (strict: only mineMarket can transfer, only to furnace).
        IERC721(address(ve)).safeTransferFrom(seller, furnaceAddr, tokenId);

        // Execute sellback via Furnace.
        claimOut = IFurnace(furnaceAddr).sellLockToFurnaceFromMarket(seller, tokenId, minClaimOut);

        // Defense-in-depth: verify the Furnace honoured the seller's slippage floor.
        if (claimOut < minClaimOut) revert Errors.SlippageTooHigh();

        emit Events.MarketSellToFurnace(tokenId, seller, minClaimOut, deadline, claimOut);
    }

    /// @notice Settle a listed lock into the Furnace.
    /// @dev Keeper-priority: during the first SETTLEMENT_KEEPER_GRACE_SECONDS after
    ///      listing creation, only whitelisted keepers (or owner) may settle. After
    ///      the grace window, settlement is permissionless.
    /// @param tokenId The listed veNFT token id to settle.
    /// @param deadline Latest acceptable `block.timestamp` for the call.
    /// @return claimOut Actual CLAIM payout to the seller.
    function sellListedLockToFurnace(uint256 tokenId, uint256 deadline)
        external
        nonReentrant
        whenTradingEnabled
        returns (uint256 claimOut)
    {
        if (block.timestamp > deadline) revert Errors.DeadlineExpired();
        Listing storage lst = listings[tokenId];
        if (!lst.active) revert Errors.ListingNotActive();
        _enforceListingCooldown(tokenId);
        if (block.timestamp >= lst.expiresAtTime) revert Errors.ListingExpired();

        address seller = lst.seller;

        // Defense-in-depth — verify seller still owns the token.
        // The ve listed-flag prevents transfers while listed; an explicit
        // ownership check gives a clear revert and guards against ve-level invariant drift.
        {
            address currentOwner = _requireTokenOwner(tokenId);
            if (currentOwner != seller) revert Errors.NotAuthorized();
        }

        if (!isSettlementKeeper[msg.sender] && msg.sender != owner()) {
            if (block.timestamp < lst.listedAtTime + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS) {
                revert Errors.SettlementKeeperGracePeriod();
            }
        } else if (isSettlementKeeper[msg.sender]) {
            // Runtime 7702 reject: an allowlisted keeper EOA that installs the
            // `0xEF0100` designator after seating exposes public-executor code,
            // letting arbitrary callers route into the protected grace window.
            // The transfer-time check at `setSettlementKeeper` is not sufficient
            // because the seat survives a delegation flip on the keeper.
            _rejectDelegatedEOA(msg.sender);
        } else {
            // Owner break-glass branch. Runtime 7702 reject on the owner seat
            // mirrors `_checkOwner`, which the manual owner equality skips.
            _validateNewOwner(msg.sender);
        }

        uint256 minClaimOut = lst.minClaimOut;

        // Get lock info for quote.
        uint256 lockAmount;
        uint256 lockEnd;
        bool autoMax;
        bool listed;
        (lockAmount, lockEnd, autoMax, listed) = ve.getLockInfo(tokenId);
        if (lockAmount == 0) revert Errors.InvalidToken();

        // Defense-in-depth: settlement requires both an active local listing AND `listed == true`
        // on VeClaimNFT. The ve-level flag is the authoritative mutation lock; local listing
        // storage alone is not sufficient because it can become stale after router replacement.
        if (!listed) revert Errors.ListingNotActive();

        // Defense-in-depth — verify lock has not expired even though
        // listing expiry <= lock expiry is enforced at creation time.
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();

        // Resolve and verify the canonical Furnace before any quote or listing side-effects.
        address furnaceAddr = _requireCanonicalFurnace();

        uint256 quoteClaimOut;
        {
            address quoter = IFurnace(furnaceAddr).furnaceQuoter();
            if (quoter == address(0)) revert Errors.ZeroAddress();
            (quoteClaimOut,,,) = _staticcallQuoteExact(
                quoter, abi.encodeCall(IFurnaceQuoter.quoteSellLockToFurnaceFromInfo, (lockAmount, lockEnd, autoMax))
            );
        }
        if (quoteClaimOut < minClaimOut) revert Errors.SlippageTooHigh();

        // Delist + clear ve flag.
        _clearListing(tokenId, seller);
        ve.setListed(tokenId, false);
        emit Events.LockDelisted(tokenId, seller, Constants.LOCK_DELIST_REASON_SOLD_TO_FURNACE);

        // Checkpoint royalties before transfer.
        royalties.checkpointTransfer(seller, furnaceAddr);

        // Transfer veNFT to Furnace custody.
        IERC721(address(ve)).safeTransferFrom(seller, furnaceAddr, tokenId);

        // Execute sellback via Furnace.
        claimOut = IFurnace(furnaceAddr).sellLockToFurnaceFromMarket(seller, tokenId, quoteClaimOut);

        // Post-condition: Furnace must honour the quoted minimum.
        if (claimOut < quoteClaimOut) revert Errors.SlippageTooHigh();

        // Defense-in-depth: the seller's listing floor must always be respected.
        if (claimOut < minClaimOut) revert Errors.SlippageTooHigh();

        // Emit ListingSettled event for analytics.
        // penalty = max(0, lockedPrincipal - claimOut) in CLAIM (0 when payout meets or exceeds locked principal).
        uint256 penalty = lockAmount > claimOut ? lockAmount - claimOut : 0;
        emit Events.ListingSettled(tokenId, seller, claimOut, penalty);
    }

    // Global offers (SPEC §8.4 + §8.5)

    /// @notice Create a global buy order escrowing CLAIM with a target Furnace bonus rate.
    /// @dev targetBonusBps is a PRE-EXECUTION gate checked against FurnaceQuoter's view-call
    ///      result, not the actual Furnace entry. Between quote and execution, Furnace AMM
    ///      state can change (other entries may drain bonus reserve). The minVeOut floor
    ///      (derived from slippageBps) bounds minimum ve received vs the quoted veOut, but the actual bonus
    ///      percentage may fall below targetBonusBps. Set slippageBps conservatively.
    function createBonusTargetEscrowWithTarget(
        uint256 targetBonusBps,
        uint256 budgetClaim,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 escrowTtlSeconds,
        uint256 destinationLockId,
        uint256 slippageBps
    ) external nonReentrant whenTradingEnabled returns (uint256 offerId) {
        // Fail closed on stale / non-canonical routers: offer creation is only safe on the
        // live market bundle because execution routes into the canonical Furnace.
        _requireCanonicalFurnace();

        offerId = _createBonusTargetEscrowWithTargetInternal(
            targetBonusBps,
            budgetClaim,
            durationSeconds,
            createAutoMax,
            escrowTtlSeconds,
            destinationLockId,
            slippageBps
        );

        // Emit from storage to keep stack small.
        BonusTargetEscrow storage offer = offers[offerId];
        emit Events.BonusTargetEscrowCreated(
            offerId,
            offer.buyer,
            offer.discountBps,
            offer.durationSeconds,
            offer.createAutoMax,
            offer.expiresAt,
            offer.destinationLockId,
            offer.fundsRemaining,
            offer.createdAt
        );
        emit Events.BonusTargetEscrowConfigured(offerId, offer.buyer, targetBonusBps, slippageBps);
    }

    function _createBonusTargetEscrowWithTargetInternal(
        uint256 targetBonusBps,
        uint256 budgetClaim,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 escrowTtlSeconds,
        uint256 destinationLockId,
        uint256 slippageBps
    ) internal returns (uint256 offerId) {
        if (slippageBps >= Constants.BPS_DENOM) revert Errors.SlippageTooHigh();
        if (targetBonusBps == 0) revert Errors.AmountZero();

        // discountBps = floor(targetBonusBps * BPS_DENOM / (BPS_DENOM + targetBonusBps))
        uint256 discountBps = Math.mulDiv(targetBonusBps, Constants.BPS_DENOM, Constants.BPS_DENOM + targetBonusBps);
        (uint256 effectiveDurationSeconds, uint256 expiresAt) =
            _validateBonusTargetEscrow(discountBps, budgetClaim, durationSeconds, createAutoMax, escrowTtlSeconds);

        uint256 targetEnd = block.timestamp + effectiveDurationSeconds;
        if (destinationLockId != 0) {
            _validateEligibleDestinationLock(msg.sender, destinationLockId, targetEnd, createAutoMax);
        }

        // NOTE: CLAIM transfer precedes state mutation (interactions-before-effects).
        // Safe because: (1) nonReentrant on entry, (2) CLAIM is a standard ERC20 with
        // no transfer hooks, so no callback vector exists.
        IERC20(address(claim)).safeTransferFrom(msg.sender, address(this), budgetClaim);

        offerId = nextOfferId++;
        offers[offerId] = BonusTargetEscrow({
            buyer: msg.sender,
            discountBps: discountBps,
            durationSeconds: effectiveDurationSeconds,
            createAutoMax: createAutoMax,
            destinationLockId: destinationLockId,
            fundsRemaining: budgetClaim,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            active: true
        });
        _addUserOffer(msg.sender, offerId);

        bonusTargetConfigs[offerId] =
            BonusTargetConfig({targetBonusBps: targetBonusBps, slippageBps: slippageBps, configured: true});
    }

    /// @dev MUST remain callable even when trading is paused.
    ///      If this router has been rewired stale, anyone may unwind and refund the buyer.
    ///      NOTE: If the buyer address is a contract that reverts on ERC20 transfer,
    ///      the cancel will revert and escrowed CLAIM remains locked. Buyers must
    ///      ensure their address can receive CLAIM.
    function cancelBonusTargetEscrow(uint256 offerId) external nonReentrant {
        BonusTargetEscrow storage offer = offers[offerId];
        if (!offer.active) revert Errors.OfferNotActive();
        address buyer = offer.buyer;
        if (buyer != msg.sender && _isCanonicalOfferLifecycleRouter()) revert Errors.NotAuthorized();

        uint256 remaining = offer.fundsRemaining;
        offer.active = false;
        offer.fundsRemaining = 0;
        delete bonusTargetConfigs[offerId];

        _removeUserOffer(buyer, offerId);

        if (remaining > 0) {
            IERC20(address(claim)).safeTransfer(buyer, remaining);
        }

        emit Events.BonusTargetEscrowCancelled(offerId, buyer, remaining);
    }

    /// @notice Permissionless: cancel an expired global offer and refund remaining budget to the buyer.
    /// @dev MUST remain callable even when trading is paused.
    function cancelExpiredBonusTargetEscrow(uint256 offerId) external nonReentrant {
        BonusTargetEscrow storage offer = offers[offerId];
        if (!offer.active) revert Errors.OfferNotActive();
        if (block.timestamp < offer.expiresAt) revert Errors.OfferNotExpired();
        address buyer = offer.buyer;

        uint256 remaining = offer.fundsRemaining;
        offer.active = false;
        offer.fundsRemaining = 0;
        delete bonusTargetConfigs[offerId];

        _removeUserOffer(buyer, offerId);

        if (remaining > 0) {
            IERC20(address(claim)).safeTransfer(buyer, remaining);
        }

        emit Events.BonusTargetEscrowExpired(offerId, buyer, remaining);
    }

    /// @notice Batch-cancel expired bonus target escrows.
    /// @dev Iteration-level best-effort: entries that are not active or not yet expired are silently
    ///      skipped. If any eligible entry's CLAIM refund reverts (e.g. the buyer address is blocked
    ///      from receiving CLAIM), the entire call reverts. Per-buyer cancel remains available via
    ///      `cancelExpiredBonusTargetEscrow` for unaffected offers.
    /// @dev MUST remain callable even when trading is paused.
    function cancelExpiredBonusTargetEscrowBatch(uint256[] calldata offerIds) external nonReentrant {
        // Best-effort batch: caller controls array length and pays gas.
        uint256 n = offerIds.length;
        for (uint256 i = 0; i < n;) {
            uint256 offerId = offerIds[i];
            BonusTargetEscrow storage offer = offers[offerId];
            if (offer.active && block.timestamp >= offer.expiresAt) {
                address buyer = offer.buyer;
                uint256 remaining = offer.fundsRemaining;
                offer.active = false;
                offer.fundsRemaining = 0;
                delete bonusTargetConfigs[offerId];
                _removeUserOffer(buyer, offerId);
                if (remaining > 0) {
                    // slither-disable-next-line reentrancy-no-eth
                    IERC20(address(claim)).safeTransfer(buyer, remaining);
                }
                emit Events.BonusTargetEscrowExpired(offerId, buyer, remaining);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Buyer-only: extend an active offer's expiry.
    /// @param newExpiresAt New expiry timestamp (unix seconds).
    /// @dev Preconditions: offer must be active and unexpired, `msg.sender == buyer`, trading
    ///      must be enabled, and Furnace must be canonical. `newExpiresAt` must be > current
    ///      expiresAt and <= offer.createdAt + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS.
    function extendBonusTargetEscrowExpiry(uint256 offerId, uint256 newExpiresAt)
        external
        nonReentrant
        whenTradingEnabled
    {
        BonusTargetEscrow storage offer = offers[offerId];
        if (!offer.active) revert Errors.OfferNotActive();
        if (offer.buyer != msg.sender) revert Errors.NotAuthorized();
        _requireCanonicalFurnace();
        if (block.timestamp >= offer.expiresAt) revert Errors.OfferExpired();
        if (newExpiresAt <= offer.expiresAt) revert Errors.InvalidOfferExpiry();
        if (newExpiresAt > offer.createdAt + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS) {
            revert Errors.InvalidOfferExpiry();
        }

        uint256 oldExpiresAt = offer.expiresAt;
        offer.expiresAt = newExpiresAt;

        emit Events.BonusTargetEscrowExpiryExtended(offerId, msg.sender, oldExpiresAt, newExpiresAt);
    }

    /// @notice Convenience helper for UI: returns (createdAt, expiresAt, maxExpiresAt).
    function getBonusTargetEscrowExpiryBounds(uint256 offerId)
        external
        view
        returns (uint256 createdAt, uint256 expiresAt, uint256 maxExpiresAt)
    {
        BonusTargetEscrow storage offer = offers[offerId];
        createdAt = offer.createdAt;
        expiresAt = offer.expiresAt;
        maxExpiresAt = offer.createdAt + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS;
    }

    /// @dev Keeper-priority: only whitelisted keepers (or owner) may execute during the first
    ///      SETTLEMENT_KEEPER_GRACE_SECONDS after offer creation. After that, permissionless.
    function executeAutoFurnace(uint256 offerId, uint256 deadline) external nonReentrant whenTradingEnabled {
        if (block.timestamp > deadline) revert Errors.DeadlineExpired();

        BonusTargetEscrow storage offer = offers[offerId];
        if (!offer.active) revert Errors.OfferNotActive();
        // Fail fast on expired offers before the keeper-grace gate (correct error + gas savings).
        if (block.timestamp >= offer.expiresAt) revert Errors.OfferExpired();
        if (!isSettlementKeeper[msg.sender] && msg.sender != owner()) {
            if (block.timestamp < offer.createdAt + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS) {
                revert Errors.SettlementKeeperGracePeriod();
            }
        } else if (isSettlementKeeper[msg.sender]) {
            // Runtime 7702 reject on the allowlisted keeper seat. See the
            // matching guard in the listing-settlement path for rationale.
            _rejectDelegatedEOA(msg.sender);
        } else {
            // Owner break-glass branch. Runtime 7702 reject on the owner seat
            // mirrors `_checkOwner`, which the manual owner equality skips.
            _validateNewOwner(msg.sender);
        }

        AutoFurnaceSnapshot memory s = _closeOfferForAutoFurnace(offerId);
        AutoFurnacePrep memory p = _prepareAutoFurnaceExecution(s);

        if (s.destinationLockId != 0 && p.resolvedLockId == 0) {
            emit Events.DestinationLockIneligible(offerId, s.destinationLockId);
        }

        uint256 furnaceTokenId = _enterFurnaceWithClaimFor(
            p.furnaceAddr, s.buyer, s.claimIn, p.resolvedLockId, p.executionDurationSeconds, s.createAutoMax, p.minVeOut
        );

        emit Events.BonusTargetEscrowExecuted(
            offerId, s.buyer, s.claimIn, p.principalClaim, p.bonusClaim, p.veOut, p.routeTokenId, furnaceTokenId
        );
        emit Events.BonusTargetEscrowAutoFurnaceExecuted(
            offerId, s.buyer, s.claimIn, p.principalClaim, p.bonusClaim, p.veOut, p.routeTokenId, furnaceTokenId
        );
    }

    struct AutoFurnaceSnapshot {
        address buyer;
        uint256 claimIn;
        uint256 durationSeconds;
        bool createAutoMax;
        uint256 destinationLockId;
        uint256 targetBonusBps;
        uint256 slippageBps;
    }

    struct AutoFurnacePrep {
        address furnaceAddr;
        uint256 resolvedLockId;
        uint256 executionDurationSeconds;
        uint256 principalClaim;
        uint256 bonusClaim;
        uint256 veOut;
        uint256 routeTokenId;
        uint256 minVeOut;
    }

    function _closeOfferForAutoFurnace(uint256 offerId) internal returns (AutoFurnaceSnapshot memory s) {
        BonusTargetEscrow storage offer = offers[offerId];
        if (!offer.active) revert Errors.OfferNotActive();
        // Use >= so that at exact expiresAt only cancellation (not execution) is valid.
        if (block.timestamp >= offer.expiresAt) revert Errors.OfferExpired();

        BonusTargetConfig storage cfg = bonusTargetConfigs[offerId];
        if (!cfg.configured) revert Errors.BonusTargetNotConfigured();

        uint256 claimIn = offer.fundsRemaining;
        if (claimIn == 0) revert Errors.OfferInsufficientFunds();

        s.buyer = offer.buyer;
        s.claimIn = claimIn;
        s.durationSeconds = offer.durationSeconds;
        s.createAutoMax = offer.createAutoMax;
        s.destinationLockId = offer.destinationLockId;
        s.targetBonusBps = cfg.targetBonusBps;
        s.slippageBps = cfg.slippageBps;

        // Close the offer (CEI) before any external calls.
        offer.fundsRemaining = 0;
        offer.active = false;

        _removeUserOffer(s.buyer, offerId);
        delete bonusTargetConfigs[offerId];
    }

    function _prepareAutoFurnaceExecution(AutoFurnaceSnapshot memory s)
        internal
        view
        returns (AutoFurnacePrep memory p)
    {
        uint256 resolvedLockId = s.destinationLockId;
        // Execution-time eligibility uses live remaining duration plus the
        // protocol-wide minimum lock floor instead of `now + s.durationSeconds`.
        // Existing non-AutoMax destination locks do not extend on entry, so a
        // lock that was valid at offer creation with exactly the requested
        // duration would otherwise drift below `now + s.durationSeconds` as
        // time passes and silently fall back to creating a new lock. The
        // execution path uses `lockEnd - block.timestamp` as the actual
        // duration, so this gate only needs to assert the lock is still alive
        // and has the minimum remaining life.
        uint256 targetEnd = block.timestamp + Constants.MIN_LOCK_DURATION;
        // Graceful degradation: if the buyer's destination lock becomes ineligible
        // (transferred, expired, listed, autoMax mismatch), fall back to creating a
        // new lock. The buyer cannot prevent this; DestinationLockIneligible is emitted.
        if (resolvedLockId != 0 && !_isEligibleDestinationLock(s.buyer, resolvedLockId, targetEnd, s.createAutoMax)) {
            resolvedLockId = 0;
        }
        p.resolvedLockId = resolvedLockId;
        p.executionDurationSeconds = s.durationSeconds;
        if (p.resolvedLockId != 0) {
            // Existing non-AutoMax locks do not extend on entry, so quote and execution
            // must use the live remaining duration rather than the offer's target duration.
            (, uint256 lockEnd, bool autoMaxExisting,) = ve.getLockInfo(p.resolvedLockId);
            if (autoMaxExisting) {
                p.executionDurationSeconds = Constants.MAX_LOCK_DURATION;
            } else {
                p.executionDurationSeconds = lockEnd - block.timestamp;
            }
        }

        p.furnaceAddr = _requireCanonicalFurnace();

        address quoter = IFurnace(p.furnaceAddr).furnaceQuoter();
        if (quoter == address(0)) revert Errors.ZeroAddress();
        (p.principalClaim, p.bonusClaim, p.veOut, p.routeTokenId) = _staticcallQuoteExact(
            quoter,
            abi.encodeCall(
                IFurnaceQuoter.quoteEnterWithClaim,
                (s.buyer, s.claimIn, p.resolvedLockId, p.executionDurationSeconds, s.createAutoMax)
            )
        );

        // Guard: principalClaim == 0 would cause division-by-zero in the
        // bonusBpsVsPrincipalClaim calculation below.
        if (p.principalClaim == 0) revert Errors.AmountZero();

        if (p.resolvedLockId == 0 && s.claimIn < Constants.MIN_LOCK_AMOUNT) revert Errors.BudgetTooSmall();

        // bonusBpsVsPrincipalClaim is validated on the QUOTED values. The actual Furnace
        // entry may yield a different bonus if AMM state changes between quote and
        // execution. The minVeOut floor below bounds minimum ve received but does not
        // guarantee the bonus rate. This is inherent to the quote-then-execute pattern.
        //
        // Floor rounding (`Math.mulDiv` default) is the correct direction here: the gate
        // accepts iff the rational ratio `bonusClaim / principalClaim` is `>= targetBonusBps
        // / BPS_DENOM`. Floor never spuriously rejects a satisfying ratio because
        // `floor(bonusClaim * BPS_DENOM / principalClaim) >= targetBonusBps` is implied by
        // `bonusClaim / principalClaim >= targetBonusBps / BPS_DENOM` whenever
        // `targetBonusBps` is a uint integer.
        uint256 bonusBpsVsPrincipalClaim = Math.mulDiv(p.bonusClaim, Constants.BPS_DENOM, p.principalClaim);
        if (bonusBpsVsPrincipalClaim < s.targetBonusBps) revert Errors.BonusTargetNotMet();

        p.minVeOut = Math.mulDiv(p.veOut, Constants.BPS_DENOM - s.slippageBps, Constants.BPS_DENOM);
        // `Furnace.enter*` requires `minVeOut > 0`. Clamp pathological rounding-to-zero cases.
        if (p.minVeOut == 0 && p.veOut > 0) p.minVeOut = 1;
    }

    function _enterFurnaceWithClaimFor(
        address furnaceAddr,
        address buyer,
        uint256 claimIn,
        uint256 resolvedLockId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) internal returns (uint256 furnaceTokenId) {
        // Allow Furnace to pull CLAIM for this call only.
        // MarketRouter can custody user escrowed CLAIM (offer budgets), so avoid leaving
        // persistent/infinite approvals that increase blast radius if Furnace is misconfigured.
        IERC20 claimErc20 = IERC20(address(claim));
        SafeApprove.forceApprove(claimErc20, furnaceAddr, claimIn);

        furnaceTokenId = IFurnace(furnaceAddr)
            .enterWithClaimFor(buyer, claimIn, resolvedLockId, durationSeconds, createAutoMax, minVeOut);

        if (furnaceTokenId == 0) revert Errors.InvalidToken();

        // Best-effort reset back to 0 for defense-in-depth.
        // If the above call reverted, the whole tx reverts and this is unnecessary.
        SafeApprove.forceApprove(claimErc20, furnaceAddr, 0);
    }

    // Emergency delist (SPEC §8.2)

    /// @dev MUST remain callable even when trading is paused.
    function emergencyDelist(uint256 tokenId) external nonReentrant {
        _enforceListingCooldown(tokenId);

        Listing storage lst = listings[tokenId];
        if (!lst.active) revert Errors.ListingNotActive();
        address seller = lst.seller;
        if (seller != msg.sender) revert Errors.NotAuthorized();

        if (block.timestamp < lst.listedAtTime + Constants.EMERGENCY_DELIST_MIN_AGE) {
            revert Errors.EmergencyDelistTooSoon();
        }

        _clearListing(tokenId, seller);
        ve.setListed(tokenId, false);
        emit Events.LockDelisted(tokenId, seller, Constants.LOCK_DELIST_REASON_EMERGENCY);
    }

    function _autoDelistForSale(uint256 tokenId) internal {
        _enforceListingCooldown(tokenId);
        Listing storage lst = listings[tokenId];
        if (lst.active) {
            address seller = lst.seller;
            if (seller != msg.sender) revert Errors.NotAuthorized();
            _clearListing(tokenId, seller);
            emit Events.LockDelisted(tokenId, seller, Constants.LOCK_DELIST_REASON_SOLD_TO_FURNACE);
        } else {
            lastListingActionBlock[tokenId] = block.number;
        }

        // Clear ve-level listed flag even if internal listing state was already cleared out-of-sync.
        ve.setListed(tokenId, false);
    }

    // Internal helpers

    function _enforceListingCooldown(uint256 tokenId) internal view {
        if (block.number <= lastListingActionBlock[tokenId]) revert Errors.ListingCooldown();
    }

    function _requireTokenOwner(uint256 tokenId) internal view returns (address owner_) {
        try ve.ownerOf(tokenId) returns (address o) {
            owner_ = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (owner_ == address(0)) revert Errors.InvalidToken();
    }

    function _clearListing(uint256 tokenId, address seller) internal {
        delete listings[tokenId];
        lastListingActionBlock[tokenId] = block.number;
        _removeUserListing(seller, tokenId);
    }

    function _addUserListing(address seller, uint256 tokenId) internal {
        if (_userListingIndexPlusOne[tokenId] != 0) return;
        _userListingIndexPlusOne[tokenId] = _userListings[seller].length + 1;
        _userListings[seller].push(tokenId);
    }

    function _removeUserListing(address seller, uint256 tokenId) internal {
        uint256 idxPlusOne = _userListingIndexPlusOne[tokenId];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;

        uint256 lastIdx = _userListings[seller].length - 1;
        if (idx != lastIdx) {
            uint256 lastTokenId = _userListings[seller][lastIdx];
            _userListings[seller][idx] = lastTokenId;
            _userListingIndexPlusOne[lastTokenId] = idx + 1;
        }

        _userListings[seller].pop();
        _userListingIndexPlusOne[tokenId] = 0;
    }

    function _addUserOffer(address buyer, uint256 offerId) internal {
        if (_userOfferIndexPlusOne[offerId] != 0) return;
        _userOfferIndexPlusOne[offerId] = _userBonusTargetEscrows[buyer].length + 1;
        _userBonusTargetEscrows[buyer].push(offerId);
    }

    function _removeUserOffer(address buyer, uint256 offerId) internal {
        uint256 idxPlusOne = _userOfferIndexPlusOne[offerId];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;

        uint256 lastIdx = _userBonusTargetEscrows[buyer].length - 1;
        if (idx != lastIdx) {
            uint256 lastOfferId = _userBonusTargetEscrows[buyer][lastIdx];
            _userBonusTargetEscrows[buyer][idx] = lastOfferId;
            _userOfferIndexPlusOne[lastOfferId] = idx + 1;
        }

        _userBonusTargetEscrows[buyer].pop();
        _userOfferIndexPlusOne[offerId] = 0;
    }

    function _sliceUintArray(uint256[] storage src, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, bool hasMore)
    {
        uint256 len = src.length;
        if (offset >= len || limit == 0) {
            return (new uint256[](0), false);
        }

        uint256 remaining = len - offset;
        uint256 count = limit > remaining ? remaining : limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = src[offset + i];
        }
        hasMore = count < remaining;
    }

    function _validateBonusTargetEscrow(
        uint256 discountBps,
        uint256 budgetClaim,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 escrowTtlSeconds
    ) internal view returns (uint256 effectiveDurationSeconds, uint256 expiresAt) {
        if (budgetClaim < minBonusTargetEscrowBudget) revert Errors.BudgetTooSmall();
        if (discountBps >= Constants.BPS_DENOM) revert Errors.DiscountTooHigh();
        if (discountBps > maxBonusTargetEscrowDiscountBps) revert Errors.DiscountTooHigh();

        uint256 ttl = escrowTtlSeconds == 0 ? Constants.DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS : escrowTtlSeconds;
        if (ttl < Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS || ttl > Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS)
        {
            revert Errors.InvalidOfferTtl();
        }

        effectiveDurationSeconds = createAutoMax ? Constants.MAX_LOCK_DURATION : durationSeconds;
        if (
            effectiveDurationSeconds < Constants.MIN_LOCK_DURATION
                || effectiveDurationSeconds > Constants.MAX_LOCK_DURATION
        ) {
            revert Errors.InvalidDuration();
        }

        // Offer expiry (TTL) is distinct from lock duration. (Optional extension is handled via `extendBonusTargetEscrowExpiry`.)
        expiresAt = block.timestamp + ttl;
    }

    function _validateEligibleDestinationLock(address user, uint256 tokenId, uint256 targetEnd, bool targetAutoMax)
        internal
        view
    {
        address tokenOwner = _requireTokenOwner(tokenId);
        if (tokenOwner != user) revert Errors.NotAuthorized();

        (, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();
        if (listed) revert Errors.LockListedOrFrozen();
        if (!autoMax && (lockEnd - block.timestamp) < Constants.MIN_LOCK_DURATION) revert Errors.InvalidDuration();
        if (autoMax != targetAutoMax) revert Errors.AutoMaxMismatch();
        if (lockEnd < targetEnd) revert Errors.DecreaseNotAllowed();
    }

    function _isEligibleDestinationLock(address user, uint256 tokenId, uint256 targetEnd, bool targetAutoMax)
        internal
        view
        returns (bool)
    {
        if (tokenId == 0) return false;

        // Token existence + ownership.
        address tokenOwner = address(0);
        try ve.ownerOf(tokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            return false;
        }
        if (tokenOwner != user) return false;

        (, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
        if (lockEnd <= block.timestamp) return false;
        if (listed) return false;
        if (!autoMax && (lockEnd - block.timestamp) < Constants.MIN_LOCK_DURATION) return false;
        if (autoMax != targetAutoMax) return false;
        if (lockEnd < targetEnd) return false;
        return true;
    }
}
