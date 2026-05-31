// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Errors} from "../lib/Errors.sol";
import {IMineCore} from "../interfaces/IMineCore.sol";
import {IFurnace} from "../interfaces/IFurnace.sol";
import {IFurnaceQuoter} from "../interfaces/IFurnaceQuoter.sol";
import {IShareholderRoyalties} from "../interfaces/IShareholderRoyalties.sol";
import {IVeClaimNFT} from "../interfaces/IVeClaimNFT.sol";
import {IMarketRouter} from "../interfaces/IMarketRouter.sol";

// ------------------------------------------------------------
// Minimal "full" interfaces (include public getters not present in pinned interfaces)
// ------------------------------------------------------------

interface IMineCoreLens is IMineCore {
    function claim() external view returns (address);
    function ve() external view returns (address);
    function royalties() external view returns (address);
    function furnace() external view returns (address);
    function entryTokenRegistry() external view returns (address);
    function guardian() external view returns (address);
    function claimAllHelper() external view returns (address);

    function currentKing() external view returns (address);
    function currentReignId() external view returns (uint256);
    function currentReignStartTime() external view returns (uint256);
    function currentReignLastAccrualTime() external view returns (uint256);
    function referencePrice() external view returns (uint256);

    function genesisKingClaimCollected() external view returns (bool);
    function genesisKingClaimMinted() external view returns (uint256);

    function kingEthBalance(address user) external view returns (uint256);
    function refundEthBalance(address user) external view returns (uint256);

    function reignEthRecipient(uint256 reignId) external view returns (address);
    function reignClaimRecipient(uint256 reignId) external view returns (address);

    function getCurrentTakeoverPrice() external view returns (uint256);
}

interface IRoyaltiesLens is IShareholderRoyalties {
    function ve() external view returns (address);
    function furnace() external view returns (address);
    function mineCore() external view returns (address);
    function mineMarket() external view returns (address);
    function claimAllHelper() external view returns (address);
    function ethPerVe() external view returns (uint256);
    function pendingShareholderETH() external view returns (uint256);
}

interface IFurnaceLens is IFurnace {
    function sellImpactVolume() external view returns (uint256);
    function lastSellImpactUpdate() external view returns (uint256);
}

interface IMarketRouterLens is IMarketRouter {
    function guardian() external view returns (address);
    function tradingPaused() external view returns (bool);
    function nextOfferId() external view returns (uint256);
    function minBonusTargetEscrowBudget() external view returns (uint256);
    function maxBonusTargetEscrowDiscountBps() external view returns (uint256);
}

interface ILpStakingVault7DLens {
    function furnace() external view returns (address);

    function totalStaked() external view returns (uint256);
    function rewardPerTokenStored() external view returns (uint256);
    function accountedRewardBalance() external view returns (uint256);
    function queuedRewards() external view returns (uint256);
    function lastFeeHarvestTs() external view returns (uint256);

    function totalClaimRewardsFundedFromFurnace() external view returns (uint256);
    function totalClaimRewardsFundedFromVaultFees() external view returns (uint256);
    function totalClaimRewardsClaimed() external view returns (uint256);
    function totalClaimRewardsLockedViaFurnace() external view returns (uint256);

    function stakedBalance(address user) external view returns (uint256);
    function earned(address user) external view returns (uint256);
    function rewards(address user) external view returns (uint256);
    function getUnbondCount(address user) external view returns (uint256);

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
        );
}

interface IDexAdapterLens {
    function aerodromeRouter() external view returns (address);
    function aerodromeFactory() external view returns (address);
    function wrappedNative() external view returns (address);
}

/// @notice AgentLens: view-only snapshot bundler intended for off-chain agents.
/// @dev This contract MUST NOT modify protocol state. It only aggregates read calls.
///      It is optional and can be deployed per-network.
///      The _readXxxExt() helpers are self-call targets only; they revert if called externally.
///      DO NOT use as an on-chain price/share oracle — totalVeCurrent data may be stale
///      or manipulable via selective checkpointing.
contract AgentLens {
    // ------------------------------------------------------------
    // Versioning
    // ------------------------------------------------------------

    error SelfCallOnly();

    uint256 public constant SNAPSHOT_VERSION = 1;

    uint256 internal constant _MARKET_USER_MAX_ITEMS = 500;

    // ------------------------------------------------------------
    // Constructor params struct (avoids stack-too-deep)
    // ------------------------------------------------------------

    struct ConstructorParams {
        address claimToken;
        address veClaimNFT;
        address mineCore;
        address shareholderRoyalties;
        address furnace;
        address marketRouter;
        address lpStakingVault7D;
        address dexAdapter;
        address furnaceEntryTokenRegistry;
        address mineCoreEntryTokenRegistry;
        address delegationHub;
        address claimAllHelper;
        address maintenanceHub;
        address launchController;
        address genesisLPVault24M;
    }

    // ------------------------------------------------------------
    // Wiring
    // ------------------------------------------------------------

    address public immutable claimToken;
    address public immutable veClaimNFT;
    address public immutable mineCore;
    address public immutable shareholderRoyalties;
    address public immutable furnace;

    // Optional "periphery" modules.
    address public immutable marketRouter;
    address public immutable lpStakingVault7D;
    address public immutable dexAdapter;

    // Optional (useful for agent tooling / manifest parity).
    address public immutable furnaceEntryTokenRegistry;
    address public immutable mineCoreEntryTokenRegistry;
    address public immutable delegationHub;
    address public immutable claimAllHelper;
    address public immutable maintenanceHub;
    address public immutable launchController;
    address public immutable genesisLPVault24M;

    /// @dev Reject EIP-7702 delegation designators on any address that would be
    ///      written to immutable storage. AgentLens is view-only and trusted by
    ///      agents/deployment checks as a snapshot oracle, so accepting a
    ///      delegated EOA here would let an attacker satisfy the constructor's
    ///      `code.length != 0` check at deploy time and later mutate the
    ///      delegation target — leaving the lens permanently pinned to an
    ///      address whose actual code can rotate. The 7702 designator is exactly
    ///      23 bytes and starts with `0xEF0100`; bare EOAs (`code.length == 0`)
    ///      and normal contracts are unaffected by this check.
    ///
    ///      Mirrored by the protocol-root contracts via the same helper name and
    ///      mirrored deploy-side by `DeployAgentLens._requireNotDelegatedEOA`.
    function _rejectDelegatedEOA(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    constructor(ConstructorParams memory p) {
        if (p.claimToken == address(0) || p.veClaimNFT == address(0) || p.mineCore == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (p.shareholderRoyalties == address(0) || p.furnace == address(0)) revert Errors.ZeroAddress();

        if (p.claimToken.code.length == 0) revert Errors.NotAContract();
        if (p.veClaimNFT.code.length == 0) revert Errors.NotAContract();
        if (p.mineCore.code.length == 0) revert Errors.NotAContract();
        if (p.shareholderRoyalties.code.length == 0) revert Errors.NotAContract();
        if (p.furnace.code.length == 0) revert Errors.NotAContract();

        // Required roots: every address baked into immutable storage MUST NOT
        // be an EIP-7702 delegated EOA. See `_rejectDelegatedEOA` Natspec for
        // the threat model.
        _rejectDelegatedEOA(p.claimToken);
        _rejectDelegatedEOA(p.veClaimNFT);
        _rejectDelegatedEOA(p.mineCore);
        _rejectDelegatedEOA(p.shareholderRoyalties);
        _rejectDelegatedEOA(p.furnace);

        // Optional periphery and tooling addresses: same threat model — if they
        // are nonzero AND their code is a 7702 designator, refuse to bake them
        // in. `_rejectDelegatedEOA` is a no-op for `address(0)` and for normal
        // contracts, so unset optional fields keep working unchanged.
        _rejectDelegatedEOA(p.marketRouter);
        _rejectDelegatedEOA(p.lpStakingVault7D);
        _rejectDelegatedEOA(p.dexAdapter);
        _rejectDelegatedEOA(p.furnaceEntryTokenRegistry);
        _rejectDelegatedEOA(p.mineCoreEntryTokenRegistry);
        _rejectDelegatedEOA(p.delegationHub);
        _rejectDelegatedEOA(p.claimAllHelper);
        _rejectDelegatedEOA(p.maintenanceHub);
        _rejectDelegatedEOA(p.launchController);
        _rejectDelegatedEOA(p.genesisLPVault24M);

        claimToken = p.claimToken;
        veClaimNFT = p.veClaimNFT;
        mineCore = p.mineCore;
        shareholderRoyalties = p.shareholderRoyalties;
        furnace = p.furnace;

        marketRouter = p.marketRouter;
        lpStakingVault7D = p.lpStakingVault7D;
        dexAdapter = p.dexAdapter;

        furnaceEntryTokenRegistry = p.furnaceEntryTokenRegistry;
        mineCoreEntryTokenRegistry = p.mineCoreEntryTokenRegistry;
        delegationHub = p.delegationHub;
        claimAllHelper = p.claimAllHelper;
        maintenanceHub = p.maintenanceHub;
        launchController = p.launchController;
        genesisLPVault24M = p.genesisLPVault24M;
    }

    // ------------------------------------------------------------
    // Snapshot types
    // ------------------------------------------------------------

    struct Addresses {
        address claimToken;
        address veClaimNFT;
        address mineCore;
        address shareholderRoyalties;
        address furnace;
        address marketRouter;
        address lpStakingVault7D;
        address dexAdapter;
        address furnaceEntryTokenRegistry;
        address mineCoreEntryTokenRegistry;
        address delegationHub;
        address claimAllHelper;
        address maintenanceHub;
        address launchController;
        address genesisLPVault24M;
    }

    struct TokenMetaV1 {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
    }

    struct MineCoreGlobalV1 {
        // Headline reign state
        address currentKing;
        uint256 currentReignId;
        uint256 currentReignStartTime;
        uint256 currentReignLastAccrualTime;

        // Pricing
        uint256 currentTakeoverPrice;
        uint256 referencePrice;

        // Emissions
        uint256 emissionStartTime;
        uint256 currentFurnaceEmissionRate;

        // Flags + guardians
        bool takeoversPaused;
        address guardian;

        // Wiring
        address claim;
        address ve;
        address royalties;
        address furnace;
        address entryTokenRegistry;
        address delegationHub;
        address claimAllHelper;

        // Reign recipients
        address currentReignEthRecipient;
        address currentReignClaimRecipient;

        // Genesis
        bool genesisKingClaimCollected;
        uint256 genesisKingClaimMinted;

        // King emission rate, derived as currentFurnaceEmissionRate * 10 from the
        // Constants.sol 10:1 launch + floor split (KING/FURNACE both decay through
        // the same _rateAt helper in MineCoreHelper). Drift bound: ~5-15 wei out of
        // ~5e18. The 10:1 invariant is pinned by testKingFurnaceLaunchRateRatioPinned
        // and testKingFurnaceFloorRatioPinnedWithin5Wei in
        // test/SecurityCriticalConstantsPinned.t.sol. Appended at the end of the
        // struct so existing positional decoders are not shifted.
        uint256 currentKingEmissionRate;
    }

    struct FurnaceGlobalV1 {
        bool lockingPaused;

        // Core bonus state
        uint256 reserve;
        uint256 lockedSupply;
        uint256 userSpotBonusBps;
        uint256 lpTopupRateBps;
        uint256 quoteUserBonusBps;
        uint256 quoteLpTopupBps;
        uint256 virtualDepth;
        uint256 lastUpdate;

        // Sell-impact tracking
        uint256 sellImpactVolume;
        uint256 lastSellImpactUpdate;

        // LP stream
        uint256 lpStreamRatePerSec;
        uint256 lpStreamPeriodFinish;
        uint256 lpStreamLastUpdate;
        uint256 lpStreamRemaining;
    }

    struct RoyaltiesGlobalV1 {
        uint256 ethPerVe;
        uint256 pendingShareholderETH;
        address ve;
        address furnace;
        address mineCore;
        address mineMarket;
        address claimAllHelper;
    }

    struct VeGlobalV1 {
        uint256 totalLockedClaim;
        uint256 totalVeCached;
        /// @dev Processed ve-bias denominator used by ShareholderRoyalties; units are ve * 1e18.
        uint256 totalVeBiasScaled;
        /// @dev totalVeCurrent: view-only, no checkpoint. Only as fresh as globalLastTs; use for UI share denominator.
        uint256 totalVeCurrent;
        /// @dev Last timestamp fully processed by VeClaimNFT's global VE checkpoint. totalVeCurrent is at most as fresh as this.
        uint256 globalLastTs;
        address furnace;
    }

    struct MarketGlobalV1 {
        address guardian;
        bool tradingPaused;
        uint256 nextOfferId;
        uint256 minBonusTargetEscrowBudget;
        uint256 maxBonusTargetEscrowDiscountBps;
    }

    struct LpVaultGlobalV1 {
        address furnace;
        uint256 totalStaked;
        uint256 rewardPerTokenStored;
        uint256 accountedRewardBalance;
        uint256 queuedRewards;
        uint256 lastFeeHarvestTs;

        uint256 totalClaimRewardsFundedFromFurnace;
        uint256 totalClaimRewardsFundedFromVaultFees;
        uint256 totalClaimRewardsClaimed;
        uint256 totalClaimRewardsLockedViaFurnace;
    }

    struct DexAdapterGlobalV1 {
        address aerodromeRouter;
        address aerodromeFactory;
        address wrappedNative;
    }

    struct ModuleStatus {
        bool claimOk;
        bool mineCoreOk;
        bool furnaceOk;
        bool royaltiesOk;
        bool veOk;
        bool marketOk;
        bool lpVaultOk;
        bool dexOk;
    }

    struct GlobalV1 {
        uint256 blockNumber;
        uint256 blockTimestamp;
        uint256 snapshotVersion;

        TokenMetaV1 claim;
        MineCoreGlobalV1 mineCore;
        FurnaceGlobalV1 furnace;
        RoyaltiesGlobalV1 royalties;
        VeGlobalV1 ve;

        MarketGlobalV1 market;
        LpVaultGlobalV1 lpVault;
        DexAdapterGlobalV1 dex;

        ModuleStatus status;
    }

    struct KingAutoLockConfigV1 {
        bool enabled;
        uint256 targetTokenId;
        uint256 pinnedTokenId;
        uint32 durationSeconds;
        bool createAutoMax;
        uint256 minVeOut;
    }

    struct MineCoreUserV1 {
        uint256 kingEthBalance;
        uint256 refundEthBalance;
        KingAutoLockConfigV1 kingAutoLockConfig;
    }

    struct ShareholderStateV1 {
        uint256 claimable;
        uint256 userVe;
        uint256 paid;
    }

    struct ShareholderAutoCompoundConfigV1 {
        bool enabled;
        bool paused;
        uint256 tokenId;
        uint256 durationSeconds;
        uint32 minCadenceSeconds;
        uint256 minEthToCompound;
        uint32 maxSlippageBps;
        uint40 lastCompoundTs;
    }

    struct RoyaltiesUserV1 {
        ShareholderStateV1 shareholderState;
        ShareholderAutoCompoundConfigV1 autoCompoundConfig;
    }

    struct VeUserV1 {
        uint256 nftBalance;
        uint256 veBalance;
    }

    struct MarketUserV1 {
        uint256[] listingIds;
        uint256[] offerIds;
        bool listingsTruncated;
        bool offersTruncated;
    }

    struct MarketUserPaginatedV1 {
        uint256[] listingIds;
        uint256[] offerIds;
        bool listingsFetchOk;
        bool offersFetchOk;
        bool hasMoreListings;
        bool hasMoreOffers;
    }

    struct LpVaultAutoCompoundConfigV1 {
        bool enabled;
        bool paused;
        uint256 tokenId;
        uint256 durationSeconds;
        uint32 maxSlippageBps;
        uint256 minRewardToCompound;
    }

    struct LpVaultUserV1 {
        uint256 stakedBalance;
        uint256 earned;
        uint256 rewards;
        uint256 unbondCount;
        LpVaultAutoCompoundConfigV1 autoCompoundConfig;
    }

    struct UserModuleStatus {
        bool mineCoreOk;
        bool royaltiesOk;
        bool veOk;
        bool marketOk;
        bool lpVaultOk;
        bool claimBalanceOk;
    }

    struct UserV1 {
        uint256 blockNumber;
        uint256 blockTimestamp;

        address user;
        uint256 snapshotVersion;
        uint256 ethBalance;
        uint256 claimBalance;

        MineCoreUserV1 mineCore;
        RoyaltiesUserV1 royalties;
        VeUserV1 ve;
        MarketUserV1 market;
        LpVaultUserV1 lpVault;

        UserModuleStatus status;
    }

    // ------------------------------------------------------------
    // View entrypoints
    // ------------------------------------------------------------

    /// @notice Return the canonical address bundle this lens was wired against.
    /// @dev Returned values are immutable for the lifetime of the lens. Off-chain consumers
    ///      should treat any per-deployment redeploy of the lens as carrying a fresh
    ///      `Addresses` struct; the lens does not track upstream rotations.
    function getAddresses() external view returns (Addresses memory a) {
        a = Addresses({
            claimToken: claimToken,
            veClaimNFT: veClaimNFT,
            mineCore: mineCore,
            shareholderRoyalties: shareholderRoyalties,
            furnace: furnace,
            marketRouter: marketRouter,
            lpStakingVault7D: lpStakingVault7D,
            dexAdapter: dexAdapter,
            furnaceEntryTokenRegistry: furnaceEntryTokenRegistry,
            mineCoreEntryTokenRegistry: mineCoreEntryTokenRegistry,
            delegationHub: delegationHub,
            claimAllHelper: claimAllHelper,
            maintenanceHub: maintenanceHub,
            launchController: launchController,
            genesisLPVault24M: genesisLPVault24M
        });
    }

    // ------------------------------------------------------------
    // External try/catch wrappers (self-staticcall targets)
    // ------------------------------------------------------------

    function _readClaimMetaExt() external view returns (TokenMetaV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readClaimMeta();
    }

    function _readMineCoreGlobalExt() external view returns (MineCoreGlobalV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readMineCoreGlobal();
    }

    function _readFurnaceGlobalExt() external view returns (FurnaceGlobalV1 memory, bool) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readFurnaceGlobal();
    }

    function _readRoyaltiesGlobalExt() external view returns (RoyaltiesGlobalV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readRoyaltiesGlobal();
    }

    function _readVeGlobalExt() external view returns (VeGlobalV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readVeGlobal();
    }

    function _readMarketGlobalExt() external view returns (MarketGlobalV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readMarketGlobal();
    }

    function _readLpVaultGlobalExt() external view returns (LpVaultGlobalV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readLpVaultGlobal();
    }

    function _readDexGlobalExt() external view returns (DexAdapterGlobalV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readDexGlobal();
    }

    function _readMineCoreUserExt(address user) external view returns (MineCoreUserV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readMineCoreUser(user);
    }

    function _readRoyaltiesUserExt(address user) external view returns (RoyaltiesUserV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readRoyaltiesUser(user);
    }

    function _readVeUserExt(address user) external view returns (VeUserV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readVeUser(user);
    }

    function _readMarketUserExt(address user) external view returns (MarketUserV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readMarketUser(user);
    }

    function _readLpVaultUserExt(address user) external view returns (LpVaultUserV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readLpVaultUser(user);
    }

    function _readMarketUserPaginatedExt(
        address user,
        uint256 listingOffset,
        uint256 listingLimit,
        uint256 offerOffset,
        uint256 offerLimit
    ) external view returns (MarketUserPaginatedV1 memory) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        return _readMarketUserPaginated(user, listingOffset, listingLimit, offerOffset, offerLimit);
    }

    // ------------------------------------------------------------
    // Global snapshot
    // ------------------------------------------------------------

    /// @notice One-shot read of every protocol-wide field a generic agent SDK consumer needs.
    /// @dev Per-module sub-reads are isolated via `_readXxxExt` self-staticcalls that the
    ///      surrounding `try/catch` rejects on revert. The returned `status.*Ok` flags are
    ///      the authoritative completeness signal: a `false` flag means the module's struct
    ///      is stale / zero / partial and MUST NOT be trusted by the consumer. The lens
    ///      never reverts on a sub-read failure — the worst case is a struct with
    ///      `*Ok = false`.
    ///
    ///      Each `_readXxxGlobal` wraps individual getters in `try/catch {}` and returns a
    ///      partial struct on per-getter revert, so outer-try success alone does not prove
    ///      the data is trustworthy. Each `*Ok` flag is therefore gated on a *headline
    ///      field* — a field set once in the constructor or wiring step of a healthy
    ///      deployment and required to be non-zero on a live module — chosen so an
    ///      all-zero return cannot pass it.
    function readGlobalV1() external view returns (GlobalV1 memory s) {
        s.blockNumber = block.number;
        s.blockTimestamp = block.timestamp;
        s.snapshotVersion = SNAPSHOT_VERSION;

        try AgentLens(address(this))._readClaimMetaExt() returns (TokenMetaV1 memory c) {
            s.claim = c;
            // Headline field: `name` is set in `ClaimToken`'s constructor and is required
            // to be non-empty on a live deployment.
            s.status.claimOk = bytes(c.name).length != 0;
        } catch {}

        try AgentLens(address(this))._readMineCoreGlobalExt() returns (MineCoreGlobalV1 memory mc) {
            s.mineCore = mc;
            // Headline field: `claim` is wired in `MineCore`'s constructor to the canonical
            // CLAIM token address.
            s.status.mineCoreOk = mc.claim != address(0);
        } catch {}

        try AgentLens(address(this))._readFurnaceGlobalExt() returns (FurnaceGlobalV1 memory f, bool complete) {
            s.furnace = f;
            s.status.furnaceOk = complete;
        } catch {}

        try AgentLens(address(this))._readRoyaltiesGlobalExt() returns (RoyaltiesGlobalV1 memory r) {
            s.royalties = r;
            // Headline field: `ve` is wired in `ShareholderRoyalties`'s constructor.
            s.status.royaltiesOk = r.ve != address(0);
        } catch {}

        try AgentLens(address(this))._readVeGlobalExt() returns (VeGlobalV1 memory v) {
            s.ve = v;
            // Headline field: `furnace` is wired by the deployer before any user-facing
            // entry path is reachable.
            s.status.veOk = v.furnace != address(0);
        } catch {}

        if (marketRouter != address(0)) {
            try AgentLens(address(this))._readMarketGlobalExt() returns (MarketGlobalV1 memory m) {
                s.market = m;
                // Headline field: `guardian` is set in `MarketRouter`'s constructor.
                s.status.marketOk = m.guardian != address(0);
            } catch {}
        }

        if (lpStakingVault7D != address(0)) {
            try AgentLens(address(this))._readLpVaultGlobalExt() returns (LpVaultGlobalV1 memory lp) {
                s.lpVault = lp;
                // Headline field: `furnace` is wired in `LpStakingVault7D`'s initializer.
                s.status.lpVaultOk = lp.furnace != address(0);
            } catch {}
        }

        if (dexAdapter != address(0)) {
            try AgentLens(address(this))._readDexGlobalExt() returns (DexAdapterGlobalV1 memory d) {
                s.dex = d;
                // Headline field: `aerodromeRouter` is wired in `DexAdapter`'s constructor.
                s.status.dexOk = d.aerodromeRouter != address(0);
            } catch {}
        }
    }

    // ------------------------------------------------------------
    // User snapshot
    // ------------------------------------------------------------

    /// @notice One-shot read of every per-user field a generic agent SDK consumer needs.
    /// @dev Same status-flag semantics as `readGlobalV1`. The market sub-read uses the
    ///      non-paginated path; consumers expecting users with > _MARKET_USER_MAX_ITEMS
    ///      open listings/offers should call `readMarketUserPaginatedV1` and stitch pages
    ///      themselves. Reverts only on `user == address(0)`.
    function readUserV1(address user) external view returns (UserV1 memory s) {
        if (user == address(0)) revert Errors.ZeroAddress();

        s.blockNumber = block.number;
        s.blockTimestamp = block.timestamp;
        s.user = user;
        s.snapshotVersion = SNAPSHOT_VERSION;
        s.ethBalance = user.balance;

        (bool ok, bytes memory data) = claimToken.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, user));
        if (ok && data.length >= 32) {
            s.claimBalance = abi.decode(data, (uint256));
            s.status.claimBalanceOk = true;
        }

        // Per-user `*Ok` flags use outer-try success as the signal. The user-level
        // getters consumed here (`kingEthBalance`, `refundEthBalance`, `balanceOf`,
        // `veBalanceOf`, `getKingAutoLockConfig`, `getShareholderState`,
        // `getAutoCompoundConfig`, `getUserListingsPaginated`, `getUserOffersPaginated`,
        // and account balance accessors) return zero / empty for a user with no data;
        // a non-zero headline-field check is not applicable because zero is a legitimate
        // per-user idle state.
        try AgentLens(address(this))._readMineCoreUserExt(user) returns (MineCoreUserV1 memory mc) {
            s.mineCore = mc;
            s.status.mineCoreOk = true;
        } catch {}

        try AgentLens(address(this))._readRoyaltiesUserExt(user) returns (RoyaltiesUserV1 memory r) {
            s.royalties = r;
            s.status.royaltiesOk = true;
        } catch {}

        try AgentLens(address(this))._readVeUserExt(user) returns (VeUserV1 memory v) {
            s.ve = v;
            s.status.veOk = true;
        } catch {}

        if (marketRouter != address(0)) {
            try AgentLens(address(this))._readMarketUserExt(user) returns (MarketUserV1 memory m) {
                s.market = m;
                s.status.marketOk = true;
            } catch {}
        }

        if (lpStakingVault7D != address(0)) {
            try AgentLens(address(this))._readLpVaultUserExt(user) returns (LpVaultUserV1 memory lp) {
                s.lpVault = lp;
                s.status.lpVaultOk = true;
            } catch {}
        }
    }

    // ------------------------------------------------------------
    // Paginated market-user reader (safe for users with many listings/offers)
    // ------------------------------------------------------------

    /// @notice Paginated variant of the market sub-read for users with many open positions.
    /// @dev Listing and offer limits are silently clamped to `_MARKET_USER_MAX_ITEMS = 500`
    ///      per page. The returned struct carries explicit `listingsFetchOk` / `offersFetchOk`
    ///      flags (separate from `hasMoreListings` / `hasMoreOffers`) so consumers can
    ///      distinguish "more pages exist" from "the read failed". Returns the zero struct
    ///      on `marketRouter == address(0)`; reverts only on `user == address(0)`.
    function readMarketUserPaginatedV1(
        address user,
        uint256 listingOffset,
        uint256 listingLimit,
        uint256 offerOffset,
        uint256 offerLimit
    ) external view returns (MarketUserPaginatedV1 memory u) {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (marketRouter == address(0)) return u;

        if (listingLimit > _MARKET_USER_MAX_ITEMS) listingLimit = _MARKET_USER_MAX_ITEMS;
        if (offerLimit > _MARKET_USER_MAX_ITEMS) offerLimit = _MARKET_USER_MAX_ITEMS;

        try AgentLens(address(this))
            ._readMarketUserPaginatedExt(user, listingOffset, listingLimit, offerOffset, offerLimit) returns (
            MarketUserPaginatedV1 memory result
        ) {
            u = result;
        } catch {}
    }

    // ------------------------------------------------------------
    // Internal readers
    // ------------------------------------------------------------

    function _readClaimMeta() internal view returns (TokenMetaV1 memory t) {
        IERC20Metadata token = IERC20Metadata(claimToken);
        try token.totalSupply() returns (uint256 ts) {
            t.totalSupply = ts;
        } catch {}

        try token.name() returns (string memory n) {
            t.name = n;
        } catch {}
        try token.symbol() returns (string memory s) {
            t.symbol = s;
        } catch {}
        try token.decimals() returns (uint8 d) {
            t.decimals = d;
        } catch {}
    }

    function _readMineCoreGlobal() internal view returns (MineCoreGlobalV1 memory m) {
        IMineCoreLens c = IMineCoreLens(mineCore);

        uint256 reignId = 0;
        try c.currentReignId() returns (uint256 rid) {
            reignId = rid;
            m.currentReignId = rid;
        } catch {}
        try c.currentKing() returns (address k) {
            m.currentKing = k;
        } catch {}
        try c.currentReignStartTime() returns (uint256 t) {
            m.currentReignStartTime = t;
        } catch {}
        try c.currentReignLastAccrualTime() returns (uint256 t) {
            m.currentReignLastAccrualTime = t;
        } catch {}

        try c.getCurrentTakeoverPrice() returns (uint256 price) {
            m.currentTakeoverPrice = price;
        } catch {}
        try c.referencePrice() returns (uint256 rp) {
            m.referencePrice = rp;
        } catch {}
        try c.emissionStartTime() returns (uint256 est) {
            m.emissionStartTime = est;
        } catch {}
        try c.getFurnaceEmissionRateAt(block.timestamp) returns (uint256 rate) {
            m.currentFurnaceEmissionRate = rate;
            // KING_EMISSION_LAUNCH_RATE = 10 * FURNACE_EMISSION_LAUNCH_RATE in
            // Constants.sol; both decay through the same _rateAt helper, so
            // kingRate(t) = 10 * furnaceRate(t) within ~5-15 wei drift. The 10:1
            // ratio is pinned by testKingFurnaceLaunchRateRatioPinned +
            // testKingFurnaceFloorRatioPinnedWithin5Wei.
            m.currentKingEmissionRate = rate * 10;
        } catch {}

        try c.takeoversPaused() returns (bool tp) {
            m.takeoversPaused = tp;
        } catch {}
        try c.guardian() returns (address g) {
            m.guardian = g;
        } catch {}

        try c.claim() returns (address v) {
            m.claim = v;
        } catch {}
        try c.ve() returns (address v) {
            m.ve = v;
        } catch {}
        try c.royalties() returns (address v) {
            m.royalties = v;
        } catch {}
        try c.furnace() returns (address v) {
            m.furnace = v;
        } catch {}
        try c.entryTokenRegistry() returns (address v) {
            m.entryTokenRegistry = v;
        } catch {}
        try c.delegationHub() returns (address v) {
            m.delegationHub = v;
        } catch {}
        try c.claimAllHelper() returns (address v) {
            m.claimAllHelper = v;
        } catch {}

        if (reignId > 0) {
            try c.reignEthRecipient(reignId) returns (address ethR) {
                m.currentReignEthRecipient = ethR;
            } catch {}
            try c.reignClaimRecipient(reignId) returns (address claimR) {
                m.currentReignClaimRecipient = claimR;
            } catch {}
        }

        try c.genesisKingClaimCollected() returns (bool v) {
            m.genesisKingClaimCollected = v;
        } catch {}
        try c.genesisKingClaimMinted() returns (uint256 v) {
            m.genesisKingClaimMinted = v;
        } catch {}
    }

    /// @dev Returns partial furnace data plus a completeness flag. `readGlobalV1` sets
    ///      `status.furnaceOk` from `complete` so partial reads are not reported as fully successful.
    function _readFurnaceGlobal() internal view returns (FurnaceGlobalV1 memory f, bool complete) {
        IFurnace x = IFurnace(furnace);
        complete = true;

        try x.lockingPaused() returns (bool val) {
            f.lockingPaused = val;
        } catch {
            complete = false;
        }

        {
            try x.furnaceQuoter() returns (address quoter) {
                if (quoter != address(0)) {
                    try IFurnaceQuoter(quoter).getFurnaceState() returns (
                        uint256 reserve,
                        uint256 lockedSupply,
                        uint256 userSpotBonusBps,
                        uint256 lpTopupRateBps,
                        uint256 quoteUserBonusBps,
                        uint256 quoteLpTopupBps,
                        uint256 virtualDepth,
                        uint256 lastUpdate
                    ) {
                        f.reserve = reserve;
                        f.lockedSupply = lockedSupply;
                        f.userSpotBonusBps = userSpotBonusBps;
                        f.lpTopupRateBps = lpTopupRateBps;
                        f.quoteUserBonusBps = quoteUserBonusBps;
                        f.quoteLpTopupBps = quoteLpTopupBps;
                        f.virtualDepth = virtualDepth;
                        f.lastUpdate = lastUpdate;
                    } catch {
                        complete = false;
                    }
                } else {
                    complete = false;
                }
            } catch {
                complete = false;
            }
        }

        {
            IFurnaceLens fl = IFurnaceLens(furnace);
            try fl.sellImpactVolume() returns (uint256 v) {
                f.sellImpactVolume = v;
            } catch {
                complete = false;
            }
            try fl.lastSellImpactUpdate() returns (uint256 t) {
                f.lastSellImpactUpdate = t;
            } catch {
                complete = false;
            }
        }

        try x.getLpStreamState() returns (uint256 rate, uint256 finish, uint256 lastUpd, uint256 remaining) {
            f.lpStreamRatePerSec = rate;
            f.lpStreamPeriodFinish = finish;
            f.lpStreamLastUpdate = lastUpd;
            f.lpStreamRemaining = remaining;
        } catch {
            complete = false;
        }
    }

    function _readRoyaltiesGlobal() internal view returns (RoyaltiesGlobalV1 memory r) {
        IRoyaltiesLens x = IRoyaltiesLens(shareholderRoyalties);

        try x.ethPerVe() returns (uint256 v) {
            r.ethPerVe = v;
        } catch {}
        try x.pendingShareholderETH() returns (uint256 v) {
            r.pendingShareholderETH = v;
        } catch {}

        try x.ve() returns (address v) {
            r.ve = v;
        } catch {}
        try x.furnace() returns (address v) {
            r.furnace = v;
        } catch {}
        try x.mineCore() returns (address v) {
            r.mineCore = v;
        } catch {}
        try x.mineMarket() returns (address v) {
            r.mineMarket = v;
        } catch {}
        try x.claimAllHelper() returns (address v) {
            r.claimAllHelper = v;
        } catch {}
    }

    /// @dev totalVeCurrent is view-only (no checkpoint); it is only as fresh as globalLastTs.
    function _readVeGlobal() internal view returns (VeGlobalV1 memory v) {
        IVeClaimNFT x = IVeClaimNFT(veClaimNFT);

        try x.totalLockedClaim() returns (uint256 val) {
            v.totalLockedClaim = val;
        } catch {}
        try x.totalVeCached() returns (uint256 val) {
            v.totalVeCached = val;
        } catch {}
        try x.totalVeBiasScaled() returns (uint256 vbs) {
            v.totalVeBiasScaled = vbs;
        } catch {}
        try x.totalVeCurrent() returns (uint256 vc) {
            v.totalVeCurrent = vc;
        } catch {}
        try x.globalLastTs() returns (uint256 val) {
            v.globalLastTs = val;
        } catch {}
        try x.furnace() returns (address val) {
            v.furnace = val;
        } catch {}
    }

    function _readMarketGlobal() internal view returns (MarketGlobalV1 memory m) {
        IMarketRouterLens x = IMarketRouterLens(marketRouter);

        try x.guardian() returns (address v) {
            m.guardian = v;
        } catch {}
        try x.tradingPaused() returns (bool v) {
            m.tradingPaused = v;
        } catch {}
        try x.nextOfferId() returns (uint256 v) {
            m.nextOfferId = v;
        } catch {}
        try x.minBonusTargetEscrowBudget() returns (uint256 v) {
            m.minBonusTargetEscrowBudget = v;
        } catch {}
        try x.maxBonusTargetEscrowDiscountBps() returns (uint256 v) {
            m.maxBonusTargetEscrowDiscountBps = v;
        } catch {}
    }

    function _readLpVaultGlobal() internal view returns (LpVaultGlobalV1 memory v) {
        ILpStakingVault7DLens x = ILpStakingVault7DLens(lpStakingVault7D);

        try x.furnace() returns (address val) {
            v.furnace = val;
        } catch {}
        try x.totalStaked() returns (uint256 val) {
            v.totalStaked = val;
        } catch {}
        try x.rewardPerTokenStored() returns (uint256 val) {
            v.rewardPerTokenStored = val;
        } catch {}
        try x.accountedRewardBalance() returns (uint256 val) {
            v.accountedRewardBalance = val;
        } catch {}
        try x.queuedRewards() returns (uint256 val) {
            v.queuedRewards = val;
        } catch {}
        try x.lastFeeHarvestTs() returns (uint256 val) {
            v.lastFeeHarvestTs = val;
        } catch {}

        try x.totalClaimRewardsFundedFromFurnace() returns (uint256 val) {
            v.totalClaimRewardsFundedFromFurnace = val;
        } catch {}
        try x.totalClaimRewardsFundedFromVaultFees() returns (uint256 val) {
            v.totalClaimRewardsFundedFromVaultFees = val;
        } catch {}
        try x.totalClaimRewardsClaimed() returns (uint256 val) {
            v.totalClaimRewardsClaimed = val;
        } catch {}
        try x.totalClaimRewardsLockedViaFurnace() returns (uint256 val) {
            v.totalClaimRewardsLockedViaFurnace = val;
        } catch {}
    }

    function _readDexGlobal() internal view returns (DexAdapterGlobalV1 memory d) {
        IDexAdapterLens x = IDexAdapterLens(dexAdapter);

        try x.aerodromeRouter() returns (address val) {
            d.aerodromeRouter = val;
        } catch {}
        try x.aerodromeFactory() returns (address val) {
            d.aerodromeFactory = val;
        } catch {}
        try x.wrappedNative() returns (address val) {
            d.wrappedNative = val;
        } catch {}
    }

    function _readMineCoreUser(address user) internal view returns (MineCoreUserV1 memory u) {
        IMineCoreLens c = IMineCoreLens(mineCore);

        try c.kingEthBalance(user) returns (uint256 kb) {
            u.kingEthBalance = kb;
        } catch {}
        try c.refundEthBalance(user) returns (uint256 rb) {
            u.refundEthBalance = rb;
        } catch {}

        try c.getKingAutoLockConfig(user) returns (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) {
            u.kingAutoLockConfig = KingAutoLockConfigV1({
                enabled: enabled,
                targetTokenId: targetTokenId,
                pinnedTokenId: pinnedTokenId,
                durationSeconds: durationSeconds,
                createAutoMax: createAutoMax,
                minVeOut: minVeOut
            });
        } catch {}
    }

    function _readRoyaltiesUser(address user) internal view returns (RoyaltiesUserV1 memory u) {
        IShareholderRoyalties r = IShareholderRoyalties(shareholderRoyalties);

        try r.getShareholderState(user) returns (uint256 claimable, uint256 userVe, uint256 paid) {
            u.shareholderState = ShareholderStateV1({claimable: claimable, userVe: userVe, paid: paid});
        } catch {}

        try r.getAutoCompoundConfig(user) returns (
            bool enabled,
            bool paused,
            uint256 tokenId,
            uint256 durationSeconds,
            uint32 minCadenceSeconds,
            uint256 minEthToCompound,
            uint32 maxSlippageBps,
            uint40 lastCompoundTs
        ) {
            u.autoCompoundConfig = ShareholderAutoCompoundConfigV1({
                enabled: enabled,
                paused: paused,
                tokenId: tokenId,
                durationSeconds: durationSeconds,
                minCadenceSeconds: minCadenceSeconds,
                minEthToCompound: minEthToCompound,
                maxSlippageBps: maxSlippageBps,
                lastCompoundTs: lastCompoundTs
            });
        } catch {}
    }

    function _readVeUser(address user) internal view returns (VeUserV1 memory u) {
        IVeClaimNFT v = IVeClaimNFT(veClaimNFT);

        try IERC721(veClaimNFT).balanceOf(user) returns (uint256 nb) {
            u.nftBalance = nb;
        } catch {}
        try v.veBalanceOf(user) returns (uint256 veBal) {
            u.veBalance = veBal;
        } catch {}
    }

    function _readMarketUser(address user) internal view returns (MarketUserV1 memory u) {
        IMarketRouter x = IMarketRouter(marketRouter);

        uint256 gasPerCall = gasleft() / 3;

        try x.getUserListingsPaginated{gas: gasPerCall}(user, 0, _MARKET_USER_MAX_ITEMS) returns (
            uint256[] memory l, bool hasMoreListings
        ) {
            u.listingIds = l;
            u.listingsTruncated = hasMoreListings;
        } catch {
            u.listingIds = new uint256[](0);
            u.listingsTruncated = true;
        }

        uint256 gasForOffers = gasleft() / 2;
        try x.getUserBonusTargetEscrowsPaginated{gas: gasForOffers}(user, 0, _MARKET_USER_MAX_ITEMS) returns (
            uint256[] memory o, bool hasMoreOffers
        ) {
            u.offerIds = o;
            u.offersTruncated = hasMoreOffers;
        } catch {
            u.offerIds = new uint256[](0);
            u.offersTruncated = true;
        }
    }

    function _readMarketUserPaginated(
        address user,
        uint256 listingOffset,
        uint256 listingLimit,
        uint256 offerOffset,
        uint256 offerLimit
    ) internal view returns (MarketUserPaginatedV1 memory u) {
        if (listingLimit > _MARKET_USER_MAX_ITEMS) listingLimit = _MARKET_USER_MAX_ITEMS;
        if (offerLimit > _MARKET_USER_MAX_ITEMS) offerLimit = _MARKET_USER_MAX_ITEMS;

        uint256 gasPerCall = gasleft() / 3;

        try IMarketRouter(marketRouter).getUserListingsPaginated{gas: gasPerCall}(
            user, listingOffset, listingLimit
        ) returns (
            uint256[] memory l, bool hasMoreListings
        ) {
            u.listingIds = l;
            u.hasMoreListings = hasMoreListings;
            u.listingsFetchOk = true;
        } catch {
            u.listingIds = new uint256[](0);
        }

        uint256 gasForOffers = gasleft() / 2;
        try IMarketRouter(marketRouter).getUserBonusTargetEscrowsPaginated{gas: gasForOffers}(
            user, offerOffset, offerLimit
        ) returns (
            uint256[] memory o, bool hasMoreOffers
        ) {
            u.offerIds = o;
            u.hasMoreOffers = hasMoreOffers;
            u.offersFetchOk = true;
        } catch {
            u.offerIds = new uint256[](0);
        }
    }

    function _readLpVaultUser(address user) internal view returns (LpVaultUserV1 memory u) {
        ILpStakingVault7DLens x = ILpStakingVault7DLens(lpStakingVault7D);

        try x.stakedBalance(user) returns (uint256 sb) {
            u.stakedBalance = sb;
        } catch {}
        try x.earned(user) returns (uint256 e) {
            u.earned = e;
        } catch {}
        try x.rewards(user) returns (uint256 r) {
            u.rewards = r;
        } catch {}
        try x.getUnbondCount(user) returns (uint256 uc) {
            u.unbondCount = uc;
        } catch {}

        try x.getAutoCompoundConfig(user) returns (
            bool enabled,
            bool paused,
            uint256 tokenId,
            uint256 durationSeconds,
            uint32 maxSlippageBps,
            uint256 minRewardToCompound
        ) {
            u.autoCompoundConfig = LpVaultAutoCompoundConfigV1({
                enabled: enabled,
                paused: paused,
                tokenId: tokenId,
                durationSeconds: durationSeconds,
                maxSlippageBps: maxSlippageBps,
                minRewardToCompound: minRewardToCompound
            });
        } catch {}
    }
}
