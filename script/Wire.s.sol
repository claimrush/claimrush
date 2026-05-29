// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {MarketRouter} from "../src/MarketRouter.sol";
import {ClaimToken} from "../src/ClaimToken.sol";
import {EntryTokenRegistry} from "../src/EntryTokenRegistry.sol";
import {Furnace} from "../src/Furnace.sol";
import {FurnaceQuoter} from "../src/FurnaceQuoter.sol";
import {LpStakingVault7D} from "../src/vault/LpStakingVault7D.sol";
import {MineCore} from "../src/MineCore.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "../src/VeClaimNFT.sol";

import {IDexAdapter} from "../src/interfaces/IDexAdapter.sol";
import {IGenesisLPVault24M} from "../src/interfaces/IGenesisLPVault24M.sol";

interface ILaunchControllerWire {
    function genesisFinalized() external view returns (bool);
}

/// @notice Wiring-only script per SPEC v1.0.0.
/// @dev Reads deployments/{base_mainnet,base_sepolia,local}.json based on chain id and wires all
///      cross-contract dependencies. All five core contracts retain a one-way freezeConfig()
///      surface for their core game-rule wiring; this script runs while those pointers remain
///      mutable, and it is also safe to re-run when the frozen pointers already match the manifest.
///      On production and testnet flows, this script runs once after
///      LaunchController.finalizeGenesis() creates the canonical CLAIM/WETH pool so
///      FurnaceEntryTokenRegistry can bind the live WETH/CLAIM hop. The script simulates the full
///      wiring sequence before
///      broadcasting so wrong owner/guardian keys fail closed before any partial onchain writes.
///
///      Required signer input:
///        - local chains: LOCAL_PRIVATE_KEY (preferred), fallback PRIVATE_KEY
///        - Base Sepolia: PRIVATE_KEY
///        - Base mainnet: LEDGER_ADDRESS / SIGNER_ADDRESS with `forge script ... --ledger --sender <address>`
///                        or PRIVATE_KEY as a fallback if explicitly desired
///      Optional env:
///        - GUARDIAN: long-term guardian address for pause/disable roles (most contracts).
///                    NOTE: MineCore.guardian is pinned to LaunchController during the genesis window (per
///                    docs/spec/launch-controller-spec-v1.0.0.md). Rotate MineCore.guardian to the long-term
///                    GUARDIAN after LaunchController.finalizeGenesis() succeeds (for example via
///                    script/FinalizeGenesis.s.sol or script/FinalizeLocalGenesis.s.sol).
///        - SETTLEMENT_KEEPER: explicit MarketRouter settlement keeper to allowlist.
///        - ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER: explicit opt-in to allowlist the permissionless
///                    MaintenanceHub as a MarketRouter settlement keeper during grace.
contract Wire is BroadcastSignerBase {
    using stdJson for string;

    struct Addrs {
        // Deployed protocol contracts (core)
        address claimToken;
        address ve;
        address royalties;
        address furnace;
        address marketRouter;
        address mineCore;
        address furnaceEntryTokenRegistry;
        address mineCoreEntryTokenRegistry;
        address claimAllHelper;
        address delegationHub;

        // Required v1.0.0 deployments for production
        address dexAdapter;
        address lpStakingVault7D;
        address genesisLpVault24M;
        address launchController;
        address maintenanceHub;

        // DEX config for EntryTokenRegistry
        address router; // raw Aerodrome router (pinned)
        address factory;
        address wrappedNative;
        address claimWethPool; // deterministic/pinned pool address (even if created later)
    }

    struct WethClaimHopParams {
        address regAddr;
        address router;
        address factory;
        address wrappedNative;
        address claimToken;
        address expectedPoolFromManifest;
        bool stable;
        bool strict;
        bool allowUndeployedPool;
    }

    function run() external {
        string memory path = _manifestPath();
        string memory json = vm.readFile(path);

        _validateManifestChainId(json);

        Addrs memory a = _readAddrs(json);

        _requireDeployed(a.claimToken, "ClaimToken");
        _requireDeployed(a.ve, "VeClaimNFT");
        _requireDeployed(a.royalties, "ShareholderRoyalties");
        _requireDeployed(a.furnace, "Furnace");
        _requireDeployed(a.marketRouter, "MarketRouter");
        _requireDeployed(a.mineCore, "MineCore");
        _requireDeployed(a.furnaceEntryTokenRegistry, "FurnaceEntryTokenRegistry");
        _requireDeployed(a.mineCoreEntryTokenRegistry, "MineCoreEntryTokenRegistry");
        _requireDeployed(a.claimAllHelper, "ClaimAllHelper");
        _requireDeployed(a.delegationHub, "DelegationHub");

        // Readback the helper's immutables BEFORE any setClaimAllHelper call. This catches
        // manifest-side address typos (helper deployed against the wrong royalties/mineCore)
        // long before the deferred `_requireCanonicalHelperWiring` check would surface them.
        // Helper is non-upgradeable; if these don't match, the deployment must be redone.
        {
            (bool okR, bytes memory retR) = a.claimAllHelper.staticcall(abi.encodeWithSignature("royalties()"));
            require(okR && retR.length >= 32, "Wire: ClaimAllHelper.royalties() unreadable");
            require(abi.decode(retR, (address)) == a.royalties, "Wire: ClaimAllHelper.royalties() mismatch vs manifest");

            (bool okM, bytes memory retM) = a.claimAllHelper.staticcall(abi.encodeWithSignature("mineCore()"));
            require(okM && retM.length >= 32, "Wire: ClaimAllHelper.mineCore() unreadable");
            require(abi.decode(retM, (address)) == a.mineCore, "Wire: ClaimAllHelper.mineCore() mismatch vs manifest");
        }

        require(
            a.furnaceEntryTokenRegistry != a.mineCoreEntryTokenRegistry, "Wire: registries must differ (policy split)"
        );

        bool isLocal = block.chainid == 31337 || block.chainid == 1337;

        bool launchControllerLive = a.launchController != address(0) && a.launchController.code.length > 0;
        bool genesisFinalized = false;
        if (launchControllerLive) {
            genesisFinalized = ILaunchControllerWire(a.launchController).genesisFinalized();
        }

        if (!isLocal) {
            // Required external pins
            _requireNonzero(a.router, "Aerodrome.router");
            _requireNonzero(a.factory, "Aerodrome.poolFactory");
            _requireNonzero(a.wrappedNative, "Aerodrome.wrappedNative");

            if (block.chainid == 8453) {
                require(
                    a.router == 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43,
                    "Wire: manifest aerodrome.router does not match canonical Base mainnet address"
                );
            }

            // Required v1.0.0 components
            _requireDeployed(a.dexAdapter, "DexAdapter");
            _requireDeployed(a.lpStakingVault7D, "LpStakingVault7D");
            _requireDeployed(a.genesisLpVault24M, "GenesisLPVault24M");
            _requireDeployed(a.launchController, "LaunchController");

            // Cross-check the vault's immutable lpWithdrawRecipient against the manifest
            // pin. The recipient is immutable, so a mis-deployed vault (e.g. wrong Safe
            // copy-pasted from a sepolia manifest) is unrecoverable post-genesis. Wire's
            // pre-flight is the last fail-loud opportunity before genesis ships.
            address expectedLpRecipient = _tryReadAddress(json, ".contracts.GenesisLPVault24M.lpWithdrawRecipient");
            if (expectedLpRecipient != address(0)) {
                address actualRecipient = IGenesisLPVault24M(a.genesisLpVault24M).lpWithdrawRecipient();
                require(
                    actualRecipient == expectedLpRecipient,
                    "Wire: GenesisLPVault24M.lpWithdrawRecipient does not match manifest pin"
                );
            }
            // MaintenanceHub is deployed after the first wiring pass because its constructor
            // validates canonical post-wire cross-contract references. Re-run Wire.s.sol after
            // DeployMaintenanceHub.s.sol to attach keeper roles and any explicitly opted-in
            // MaintenanceHub settlement-keeper role.
        }

        BroadcastSigner memory signer = _resolveBroadcastSigner();
        address broadcaster = signer.account;
        address guardian = _tryEnvAddress("GUARDIAN");

        // Production deploys MUST rotate the registry (and other) guardians off
        // the initial owner. The EntryTokenRegistry constructor seeds
        // `guardian = initialOwner` as a dev-convenience default, and Wire's
        // rotation calls are conditional on `guardian != address(0)`. Without
        // this fail-closed guard, an unset GUARDIAN env on a non-local profile
        // would silently ship mainnet with `guardian == initialOwner`, defeating
        // separation of duties between the configuration and emergency-disable
        // keys. The check is intentionally absent on local/anvil chains so the
        // dev profile keeps working without a Safe.
        if (!isLocal) {
            require(guardian != address(0), "Wire: GUARDIAN env var required on non-local deploys");
        }

        console2.log("Wire: simulating full wiring sequence before broadcast...");
        _preflightWireSequence(a, broadcaster, guardian, isLocal, launchControllerLive, genesisFinalized);
        console2.log("Wire: preflight simulation passed.");

        _startBroadcast(signer);
        _executeWire(a, broadcaster, guardian, isLocal, launchControllerLive, genesisFinalized);
        vm.stopBroadcast();
    }

    function _preflightWireSequence(
        Addrs memory a,
        address broadcaster,
        address guardian,
        bool isLocal,
        bool launchControllerLive,
        bool genesisFinalized
    ) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(broadcaster);
        _executeWire(a, broadcaster, guardian, isLocal, launchControllerLive, genesisFinalized);
        vm.stopPrank();
        require(vm.revertTo(snap), "Wire: failed to revert preflight snapshot");
    }

    function _executeWire(
        Addrs memory a,
        address broadcaster,
        address guardian,
        bool isLocal,
        bool launchControllerLive,
        bool genesisFinalized
    ) internal {
        // ----------------------------------
        // EntryTokenRegistry router config (wired here; registry's own ratchet rules prevent later changes once pools are configured)
        // ----------------------------------
        address registryRouter = (a.dexAdapter != address(0)) ? a.dexAdapter : a.router;

        _wireRegistry(a.furnaceEntryTokenRegistry, registryRouter, a.factory, a.wrappedNative, a.claimToken, guardian);
        _wireRegistry(a.mineCoreEntryTokenRegistry, registryRouter, a.factory, a.wrappedNative, a.claimToken, guardian);

        // Furnace registry needs WETH/CLAIM hop for quote & offer mechanics.
        _wireWethClaimHop(
            WethClaimHopParams({
                regAddr: a.furnaceEntryTokenRegistry,
                router: registryRouter,
                factory: a.factory,
                wrappedNative: a.wrappedNative,
                claimToken: a.claimToken,
                expectedPoolFromManifest: a.claimWethPool,
                stable: false,
                strict: !isLocal,
                allowUndeployedPool: launchControllerLive && !genesisFinalized
            })
        );

        // ----------------------------------
        // ClaimToken wiring
        // ----------------------------------
        {
            ClaimToken claimToken = ClaimToken(a.claimToken);
            if (!claimToken.configFrozen()) {
                if (claimToken.mineCore() != a.mineCore) {
                    claimToken.setMineCore(a.mineCore);
                    require(claimToken.mineCore() == a.mineCore, "Wire: ClaimToken.setMineCore did not take effect");
                }
            } else {
                require(claimToken.mineCore() == a.mineCore, "Wire: frozen ClaimToken.mineCore mismatch");
            }
        }

        // ----------------------------------
        // Furnace wiring
        // ----------------------------------
        // Furnace must be wired before VeClaimNFT: ve.setFurnace() validates the
        // reciprocal MineCore<->Furnace<->ClaimToken bundle via
        // _requireCanonicalMineCoreThroughFurnace, which needs furnace.mineCore()
        // and mineCore.furnace() to already be set.
        //
        // NOTE: `furnace.setDelegationHub(...)` is intentionally deferred to
        // after the MineCore block. The canonical-hub check inside
        // `Furnace.setDelegationHub` staticcalls `mineCore.furnace()` and
        // `mineCore.delegationHub()` and demands they already match the
        // canonical bundle, so MineCore-side wiring (setFurnace +
        // setDelegationHub) MUST land first.
        {
            Furnace furnace = Furnace(payable(a.furnace));

            if (furnace.shareholderRoyalties() != a.royalties) {
                furnace.setShareholderRoyalties(a.royalties);
            }
            if (furnace.entryTokenRegistry() != a.furnaceEntryTokenRegistry) {
                furnace.setEntryTokenRegistry(a.furnaceEntryTokenRegistry);
            }
            // setMineCore MUST precede setGuardian: Furnace.setGuardian enforces
            // guardian == mineCore when mineCore != address(0).
            if (furnace.mineCore() != a.mineCore) {
                furnace.setMineCore(a.mineCore);
            }
            if (furnace.mineMarket() != a.marketRouter) {
                furnace.setMineMarket(a.marketRouter);
            }
            // v1.0.0 REQUIRED: single pause surface for locking.
            // MineCore.setLockingPaused(...) forwards to Furnace.setLockingPaused(...),
            // so Furnace.guardian MUST be MineCore (SPEC §5.6.2).
            if (a.mineCore != address(0) && furnace.guardian() != a.mineCore) {
                furnace.setGuardian(a.mineCore);
            }
            if (a.lpStakingVault7D != address(0) && furnace.lpRewardsVault() != a.lpStakingVault7D) {
                furnace.setLpRewardsVault(a.lpStakingVault7D);
            }

            // Wire view-only quoter (reduces Furnace runtime bytecode).
            // Deployed here so manifests don't need to track an extra address.
            address q = furnace.furnaceQuoter();
            if (q == address(0) || q.code.length == 0) {
                furnace.setFurnaceQuoter(address(new FurnaceQuoter(address(furnace))));
            }
        }

        // ----------------------------------
        // ShareholderRoyalties wiring (includes ClaimAllHelper)
        // ----------------------------------
        {
            ShareholderRoyalties royalties = ShareholderRoyalties(a.royalties);
            if (
                royalties.mineCore() != a.mineCore || royalties.mineMarket() != a.marketRouter
                    || address(royalties.furnace()) != a.furnace
            ) {
                royalties.setWiring(a.mineCore, a.marketRouter, a.furnace);
            }
            _callSetClaimAllHelper(address(royalties), a.claimAllHelper);

            address shareholderCompoundKeeper = _tryEnvAddress("SHAREHOLDER_COMPOUND_KEEPER");
            if (shareholderCompoundKeeper != address(0) && !royalties.isAutoCompoundKeeper(shareholderCompoundKeeper)) {
                royalties.setAutoCompoundKeeper(shareholderCompoundKeeper, true);
            }
        }

        // ----------------------------------
        // MineCore wiring (includes ClaimAllHelper)
        // ----------------------------------
        // MineCore.setFurnace must precede VeClaimNFT wiring: ve.setFurnace()
        // validates mineCore.furnace() == furnace.
        {
            MineCore mineCore = MineCore(payable(a.mineCore));

            // ----------------------------------------------------------
            //
            // Genesis authority + pause state (v1.0.0)
            //
            // Pre-genesis requirements:
            // - takeoversPaused MUST be true for the entire genesis window
            // - MineCore.guardian MUST be LaunchController so LaunchController can:
            //     - collectGenesisKingClaim(...)
            //     - setTakeoversPaused(false) during finalizeGenesis()
            //
            // Post-genesis requirement:
            // - OWNER should rotate MineCore.guardian to the long-term GUARDIAN (see genesis checklist §B4).
            // ----------------------------------------------------------
            if (launchControllerLive && !genesisFinalized) {
                // Pre-genesis: ensure takeovers are paused BEFORE handing guardian to LaunchController.
                if (!mineCore.takeoversPaused()) {
                    // Only the current guardian can pause. At deployment time this should still be the broadcaster.
                    require(
                        mineCore.guardian() == broadcaster,
                        "Wire: MineCore guardian must be broadcaster to pause takeovers pre-genesis"
                    );
                    mineCore.setTakeoversPaused(true);
                }

                if (mineCore.guardian() != a.launchController) {
                    mineCore.setGuardian(a.launchController);
                }
            } else {
                // Post-genesis (or deployments without LaunchController): rotate to provided GUARDIAN if desired.
                if (guardian != address(0) && guardian != mineCore.guardian()) {
                    mineCore.setGuardian(guardian);
                }
            }

            if (address(mineCore.furnace()) != a.furnace) {
                mineCore.setFurnace(a.furnace);
            }
            if (mineCore.entryTokenRegistry() != a.mineCoreEntryTokenRegistry) {
                mineCore.setEntryTokenRegistry(a.mineCoreEntryTokenRegistry);
            }
            if (mineCore.claimAllHelper() != a.claimAllHelper) {
                _callSetClaimAllHelper(address(mineCore), a.claimAllHelper);
            }
            if (mineCore.delegationHub() != a.delegationHub) {
                mineCore.setDelegationHub(a.delegationHub);
            }
        }

        // ----------------------------------
        // Furnace.setDelegationHub (deferred)
        // ----------------------------------
        // Run AFTER MineCore wiring is complete so the canonical-hub
        // check (`requireCanonicalDelegationHub`) sees `mineCore.furnace()`
        // and `mineCore.delegationHub()` already pointing at the canonical
        // bundle. Setting it earlier (inside the Furnace block) would revert
        // with `WiringMismatch()` on a fresh deployment.
        {
            Furnace furnace = Furnace(payable(a.furnace));
            if (furnace.delegationHub() != a.delegationHub) {
                furnace.setDelegationHub(a.delegationHub);
            }
        }

        // ----------------------------------
        // VeClaimNFT wiring
        // ----------------------------------
        // Placed after Furnace + MineCore so the reciprocal wiring checks in
        // ve.setFurnace() can see furnace.mineCore() and mineCore.furnace().
        {
            VeClaimNFT ve = VeClaimNFT(a.ve);

            if (ve.mineMarket() != a.marketRouter) {
                ve.setMineMarket(a.marketRouter);
            }
            if (ve.furnace() != a.furnace) {
                ve.setFurnace(a.furnace);
            }

            // NFT metadata URIs (ERC-721 tokenURI + ERC-7572 contractURI)
            // VeClaimNFT enforces a 512-byte cap on both setters.
            string memory veBaseURI = _tryEnvString("VE_CLAIM_BASE_URI");
            if (bytes(veBaseURI).length > 0) {
                require(bytes(veBaseURI).length <= 512, "Wire: VE_CLAIM_BASE_URI exceeds 512-byte limit");
                if (keccak256(bytes(ve.baseURI())) != keccak256(bytes(veBaseURI))) {
                    ve.setBaseURI(veBaseURI);
                }
            }
            string memory veContractURI = _tryEnvString("VE_CLAIM_CONTRACT_URI");
            if (bytes(veContractURI).length > 0) {
                require(bytes(veContractURI).length <= 512, "Wire: VE_CLAIM_CONTRACT_URI exceeds 512-byte limit");
                if (keccak256(bytes(ve.contractURI())) != keccak256(bytes(veContractURI))) {
                    ve.setContractURI(veContractURI);
                }
            }
        }

        // ----------------------------------
        // LpStakingVault7D harvest keeper allowlist
        // ----------------------------------
        if (a.lpStakingVault7D != address(0) && a.lpStakingVault7D.code.length > 0) {
            LpStakingVault7D vault = LpStakingVault7D(a.lpStakingVault7D);

            // Policy default: keep MaintenanceHub off keeper allowlists unless explicitly opted in.
            bool allowPermissionlessHarvestViaMaintenanceHub = _tryEnvBool("ALLOW_MAINTENANCE_HUB_HARVEST_KEEPER");
            if (
                allowPermissionlessHarvestViaMaintenanceHub && a.maintenanceHub != address(0)
                    && a.maintenanceHub.code.length > 0 && !vault.isHarvestKeeper(a.maintenanceHub)
            ) {
                vault.setHarvestKeeper(a.maintenanceHub, true);
            }

            address harvestKeeper = _tryEnvAddress("HARVEST_KEEPER");
            if (harvestKeeper != address(0) && !vault.isHarvestKeeper(harvestKeeper)) {
                vault.setHarvestKeeper(harvestKeeper, true);
            }
        }

        // ----------------------------------
        // MarketRouter wiring
        // ----------------------------------
        {
            MarketRouter market = MarketRouter(a.marketRouter);

            // Guardian rotation is allowed post-freeze; do it here for completeness.
            if (guardian != address(0) && guardian != market.guardian()) {
                market.setGuardian(guardian);
            }

            // Settlement keeper priority (MEV protection): keep permissionless forwarders
            // like MaintenanceHub off this allowlist unless operators explicitly opt in.
            bool allowPermissionlessSettlementViaMaintenanceHub = _tryEnvBool("ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER");
            address settlementKeeper = _tryEnvAddress("SETTLEMENT_KEEPER");

            if (
                !allowPermissionlessSettlementViaMaintenanceHub && settlementKeeper != address(0)
                    && a.maintenanceHub != address(0) && settlementKeeper == a.maintenanceHub
            ) {
                revert("Wire: MaintenanceHub settlement keeper requires ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER");
            }

            if (settlementKeeper != address(0) && !market.isSettlementKeeper(settlementKeeper)) {
                market.setSettlementKeeper(settlementKeeper, true);
            }
            if (
                allowPermissionlessSettlementViaMaintenanceHub && a.maintenanceHub != address(0)
                    && a.maintenanceHub.code.length > 0 && !market.isSettlementKeeper(a.maintenanceHub)
            ) {
                market.setSettlementKeeper(a.maintenanceHub, true);
            }
        }

        // ----------------------------------
        // ClaimToken freeze + renounce
        // ----------------------------------
        // ClaimToken has no post-freeze owner knobs (no pause, no metadata, no guardian).
        // Ownership is dead weight from the moment setMineCore() lands. Freeze and renounce
        // immediately so there is one fewer key to protect during the initial live window.
        //
        // freezeConfig() validates MineCore identity (claim() root, emissionStartTime,
        // GENESIS_ACCRUAL_DURATION) before setting configFrozen = true. If wiring is wrong,
        // it reverts and nothing changes. renounceOwnership() requires configFrozen == true.
        {
            ClaimToken claimToken = ClaimToken(a.claimToken);
            if (!claimToken.configFrozen()) {
                claimToken.freezeConfig();
            }
            if (claimToken.owner() != address(0)) {
                claimToken.renounceOwnership();
            }
        }
    }

    // =====================================================================
    //  Internal helpers
    // =====================================================================

    function _wireRegistry(
        address regAddr,
        address router,
        address factory,
        address wrappedNative,
        address claimToken,
        address guardian
    ) internal {
        EntryTokenRegistry reg = EntryTokenRegistry(regAddr);

        // Local/anvil manifests may omit Aerodrome config (or set it to zero). In that case, skip router config wiring
        // rather than reverting or overwriting an already-initialized config.
        if (router != address(0) && factory != address(0) && wrappedNative != address(0) && claimToken != address(0)) {
            (address r0, address f0, address w0, address c0) = reg.getRouterConfig();
            if (r0 != router || f0 != factory || w0 != wrappedNative || c0 != claimToken) {
                reg.setRouterConfig(router, factory, wrappedNative, claimToken);
            }
        }

        if (guardian != address(0) && guardian != reg.guardian()) {
            reg.setGuardian(guardian);
        }
    }

    function _wireWethClaimHop(WethClaimHopParams memory p) internal {
        EntryTokenRegistry reg = EntryTokenRegistry(p.regAddr);

        // Router config must be set first (otherwise setWethClaimHop reverts).
        (address r0,, address w0, address c0) = reg.getRouterConfig();
        if (r0 == address(0) || w0 == address(0) || c0 == address(0)) {
            if (p.strict) revert("Wire: registry router config missing (hop)");
            return;
        }

        address pool = p.expectedPoolFromManifest;
        address deterministic = IDexAdapter(p.router).poolFor(p.wrappedNative, p.claimToken, p.stable, p.factory);
        if (pool == address(0)) {
            pool = deterministic;
        } else if (deterministic != address(0) && p.strict) {
            require(pool == deterministic, "Wire: manifest claimWethPool does not match deterministic poolFor()");
        }

        if (pool == address(0)) {
            if (p.strict) revert("Wire: unable to determine WETH/CLAIM pool");
            return;
        }

        (bool stable0, address pool0) = reg.getWethClaimHop();

        if (pool.code.length == 0) {
            if (p.allowUndeployedPool) {
                require(pool0 == address(0), "Wire: unexpected WETH/CLAIM hop already set before canonical pool exists");
                console2.log("Wire: deferring WETH/CLAIM hop until canonical pool has live code", pool);
                return;
            }
            if (p.strict) revert("Wire: canonical WETH/CLAIM pool has no code");
            return;
        }

        if (stable0 != p.stable || pool0 != pool) {
            reg.setWethClaimHop(p.stable, pool);
        }
    }

    function _readAddrs(string memory json) internal view returns (Addrs memory a) {
        a.claimToken = json.readAddress(".contracts.ClaimToken.address");
        a.ve = json.readAddress(".contracts.VeClaimNFT.address");
        a.royalties = json.readAddress(".contracts.ShareholderRoyalties.address");
        a.furnace = json.readAddress(".contracts.Furnace.address");
        a.marketRouter = json.readAddress(".contracts.MarketRouter.address");
        a.mineCore = json.readAddress(".contracts.MineCore.address");
        a.furnaceEntryTokenRegistry = json.readAddress(".contracts.FurnaceEntryTokenRegistry.address");
        a.mineCoreEntryTokenRegistry = json.readAddress(".contracts.MineCoreEntryTokenRegistry.address");
        a.claimAllHelper = json.readAddress(".contracts.ClaimAllHelper.address");
        a.delegationHub = json.readAddress(".contracts.DelegationHub.address");

        a.dexAdapter = _tryReadAddress(json, ".contracts.DexAdapter.address");
        a.lpStakingVault7D = _tryReadAddress(json, ".contracts.LpStakingVault7D.address");
        a.genesisLpVault24M = _tryReadAddress(json, ".contracts.GenesisLPVault24M.address");
        a.launchController = _tryReadAddress(json, ".contracts.LaunchController.address");
        a.maintenanceHub = _tryReadAddress(json, ".contracts.MaintenanceHub.address");

        a.router = _tryReadAddress(json, ".aerodrome.router.address");
        a.factory = _tryReadAddress(json, ".aerodrome.poolFactory.address");
        // Fallback: some manifests use `.aerodrome.factory.address` instead.
        if (a.factory == address(0)) {
            a.factory = _tryReadAddress(json, ".aerodrome.factory.address");
        }
        a.wrappedNative = _tryReadAddress(json, ".aerodrome.wrappedNative.address");
        a.claimWethPool = _tryReadAddress(json, ".aerodrome.claimWethPool.address");
    }

    function _validateManifestChainId(string memory json) internal view {
        try vm.parseJsonUint(json, ".chainId") returns (uint256 manifestChainId) {
            require(manifestChainId == block.chainid, "Wire: manifest chainId does not match block.chainid");
        } catch {
            if (block.chainid == 8453) {
                revert("Wire: mainnet manifest must contain a chainId field");
            }
        }
    }

    function _tryReadAddress(string memory json, string memory path) internal view returns (address out) {
        try vm.parseJsonAddress(json, path) returns (address v) {
            out = v;
        } catch {
            out = address(0);
        }
    }

    function _manifestPath() internal view returns (string memory) {
        uint256 cid = block.chainid;
        if (cid == 8453) return "deployments/base_mainnet.json"; // Base mainnet
        if (cid == 84532) return "deployments/base_sepolia.json"; // Base Sepolia
        if (cid == 31337 || cid == 1337) return "deployments/local.json"; // Anvil / local forks
        revert("Wire: unsupported chain");
    }

    function _requireNonzero(address a, string memory what) internal pure {
        require(a != address(0), string.concat("Wire: missing ", what));
    }

    function _requireDeployed(address a, string memory what) internal view {
        require(a != address(0), string.concat("Wire: missing ", what));
        require(a.code.length > 0, string.concat("Wire: no code at ", what));
    }

    function _tryEnvAddress(string memory key) internal returns (address out) {
        try vm.envAddress(key) returns (address v) {
            out = v;
        } catch {
            out = address(0);
        }
    }

    function _tryEnvBool(string memory key) internal returns (bool out) {
        try vm.envBool(key) returns (bool v) {
            out = v;
        } catch {
            out = false;
        }
    }

    function _tryEnvString(string memory key) internal returns (string memory out) {
        try vm.envString(key) returns (string memory v) {
            out = v;
        } catch {
            out = "";
        }
    }

    function _envUintOr(string memory key, uint256 fallbackValue) internal returns (uint256 out) {
        try vm.envUint(key) returns (uint256 v) {
            out = v;
        } catch {
            out = fallbackValue;
        }
    }

    /// @dev Call setClaimAllHelper(address) without coupling this script to an exact interface version.
    function _callSetClaimAllHelper(address target, address helper) internal {
        _requireDeployed(helper, "ClaimAllHelper");
        (bool ok, bytes memory ret) = target.call(abi.encodeWithSignature("setClaimAllHelper(address)", helper));
        require(ok, "Wire: setClaimAllHelper failed");
        require(
            ret.length == 0 || ret.length >= 32,
            "Wire: setClaimAllHelper returned unexpected data (possible noop fallback)"
        );
    }
}
