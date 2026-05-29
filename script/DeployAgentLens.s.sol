// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {AgentLens} from "../src/lens/AgentLens.sol";

interface IAgentLensClaimTokenLike {
    function mineCore() external view returns (address);
}

interface IAgentLensVeLike {
    function claimToken() external view returns (address);
    function furnace() external view returns (address);
    function mineMarket() external view returns (address);
}

interface IAgentLensRoyaltiesLike {
    function ve() external view returns (address);
    function furnace() external view returns (address);
    function mineCore() external view returns (address);
    function mineMarket() external view returns (address);
    function claimAllHelper() external view returns (address);
}

interface IAgentLensFurnaceLike {
    function claim() external view returns (address);
    function ve() external view returns (address);
    function shareholderRoyalties() external view returns (address);
    function mineCore() external view returns (address);
    function mineMarket() external view returns (address);
    function entryTokenRegistry() external view returns (address);
    function delegationHub() external view returns (address);
    function lpRewardsVault() external view returns (address);
}

interface IAgentLensMineCoreLike {
    function claim() external view returns (address);
    function ve() external view returns (address);
    function royalties() external view returns (address);
    function furnace() external view returns (address);
    function entryTokenRegistry() external view returns (address);
    function delegationHub() external view returns (address);
    function claimAllHelper() external view returns (address);
}

interface IAgentLensMarketLike {
    function claim() external view returns (address);
    function ve() external view returns (address);
    function royalties() external view returns (address);
}

interface IAgentLensClaimAllHelperLike {
    function royalties() external view returns (address);
    function mineCore() external view returns (address);
}

interface IAgentLensDexLike {
    function aerodromeRouter() external view returns (address);
    function defaultFactory() external view returns (address);
    function weth() external view returns (address);
    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address);
}

interface IAgentLensLpVaultLike {
    function claim() external view returns (address);
    function weth() external view returns (address);
    function ve() external view returns (address);
    function furnace() external view returns (address);
    function aerodromeRouter() external view returns (address);
    function aerodromeFactory() external view returns (address);
    function lpToken() external view returns (address);
}

interface IAgentLensLaunchControllerLike {
    function claim() external view returns (address);
    function mineCore() external view returns (address);
    function genesisLpVault() external view returns (address);
    function aerodromeRouter() external view returns (address);
    function weth() external view returns (address);
    function factory() external view returns (address);
    function expectedPool() external view returns (address);
}

interface IAgentLensGenesisVaultLike {
    function pool() external view returns (address);
    function lpWithdrawRecipient() external view returns (address);
}

/// @notice Deploy the AgentLens view-only snapshot bundler.
/// @dev Designed for local deployment flows but usable on any chain.
///      This helper fails closed unless the supplied constructor addresses already resolve to one
///      canonical live bundle. That prevents deploying an AgentLens instance with a mixed set of
///      stale MarketRouter / MineCore / Furnace / registry / LaunchController / MaintenanceHub pins.
///      Companion optional dependencies are also enforced so mixed partial snapshots cannot hide behind
///      omitted fields: MaintenanceHub requires MarketRouter + DexAdapter, LpStakingVault7D requires
///      DexAdapter, GenesisLPVault24M requires DexAdapter, and LaunchController requires both DexAdapter
///      and GenesisLPVault24M.
///
/// Required env vars:
/// - local chainIds 31337 / 1337: prefer LOCAL_* keys, fallback to non-prefixed keys
/// - production/testnet chains: require non-prefixed keys
/// - CLAIM_TOKEN / LOCAL_CLAIM_TOKEN
/// - VECLAIM_NFT / LOCAL_VECLAIM_NFT
/// - MINE_CORE / LOCAL_MINE_CORE
/// - SHAREHOLDER_ROYALTIES / LOCAL_SHAREHOLDER_ROYALTIES
/// - FURNACE / LOCAL_FURNACE
///
/// Optional env vars (default to address(0)):
/// - local chainIds 31337 / 1337: prefer LOCAL_* keys, fallback to non-prefixed keys
/// - production/testnet chains: read non-prefixed keys only
/// - MARKET_ROUTER / LOCAL_MARKET_ROUTER
/// - LP_STAKING_VAULT_7D / LOCAL_LP_STAKING_VAULT_7D
/// - DEX_ADAPTER / LOCAL_DEX_ADAPTER
/// - FURNACE_ENTRY_TOKEN_REGISTRY / LOCAL_FURNACE_ENTRY_TOKEN_REGISTRY
/// - MINE_CORE_ENTRY_TOKEN_REGISTRY / LOCAL_MINE_CORE_ENTRY_TOKEN_REGISTRY
/// - DELEGATION_HUB / LOCAL_DELEGATION_HUB
/// - CLAIM_ALL_HELPER / LOCAL_CLAIM_ALL_HELPER
/// - MAINTENANCE_HUB / LOCAL_MAINTENANCE_HUB
/// - LAUNCH_CONTROLLER / LOCAL_LAUNCH_CONTROLLER
/// - GENESIS_LP_VAULT_24M / LOCAL_GENESIS_LP_VAULT_24M
///
/// Signer input:
/// - local chains: LOCAL_PRIVATE_KEY (preferred), fallback PRIVATE_KEY
/// - Base Sepolia: PRIVATE_KEY
/// - Base mainnet: LEDGER_ADDRESS / SIGNER_ADDRESS with `forge script ... --ledger --sender <address>`
///                 or PRIVATE_KEY as a fallback if explicitly desired
contract DeployAgentLens is BroadcastSignerBase {
    function run() external {
        bool isLocal = block.chainid == 31337 || block.chainid == 1337;
        BroadcastSigner memory signer = _resolveBroadcastSigner();

        AgentLens.ConstructorParams memory p = AgentLens.ConstructorParams({
            claimToken: _envAddressRequired(isLocal, "LOCAL_CLAIM_TOKEN", "CLAIM_TOKEN", "claimToken"),
            veClaimNFT: _envAddressRequired(isLocal, "LOCAL_VECLAIM_NFT", "VECLAIM_NFT", "veClaimNFT"),
            mineCore: _envAddressRequired(isLocal, "LOCAL_MINE_CORE", "MINE_CORE", "mineCore"),
            shareholderRoyalties: _envAddressRequired(
                isLocal, "LOCAL_SHAREHOLDER_ROYALTIES", "SHAREHOLDER_ROYALTIES", "shareholderRoyalties"
            ),
            furnace: _envAddressRequired(isLocal, "LOCAL_FURNACE", "FURNACE", "furnace"),
            marketRouter: _envAddressOrZero(isLocal, "LOCAL_MARKET_ROUTER", "MARKET_ROUTER"),
            lpStakingVault7D: _envAddressOrZero(isLocal, "LOCAL_LP_STAKING_VAULT_7D", "LP_STAKING_VAULT_7D"),
            dexAdapter: _envAddressOrZero(isLocal, "LOCAL_DEX_ADAPTER", "DEX_ADAPTER"),
            furnaceEntryTokenRegistry: _envAddressOrZero(
                isLocal, "LOCAL_FURNACE_ENTRY_TOKEN_REGISTRY", "FURNACE_ENTRY_TOKEN_REGISTRY"
            ),
            mineCoreEntryTokenRegistry: _envAddressOrZero(
                isLocal, "LOCAL_MINE_CORE_ENTRY_TOKEN_REGISTRY", "MINE_CORE_ENTRY_TOKEN_REGISTRY"
            ),
            delegationHub: _envAddressOrZero(isLocal, "LOCAL_DELEGATION_HUB", "DELEGATION_HUB"),
            claimAllHelper: _envAddressOrZero(isLocal, "LOCAL_CLAIM_ALL_HELPER", "CLAIM_ALL_HELPER"),
            maintenanceHub: _envAddressOrZero(isLocal, "LOCAL_MAINTENANCE_HUB", "MAINTENANCE_HUB"),
            launchController: _envAddressOrZero(isLocal, "LOCAL_LAUNCH_CONTROLLER", "LAUNCH_CONTROLLER"),
            genesisLPVault24M: _envAddressOrZero(isLocal, "LOCAL_GENESIS_LP_VAULT_24M", "GENESIS_LP_VAULT_24M")
        });

        _requireContractOrZero(p.marketRouter, "marketRouter");
        _requireContractOrZero(p.lpStakingVault7D, "lpStakingVault7D");
        _requireContractOrZero(p.dexAdapter, "dexAdapter");
        _requireContractOrZero(p.furnaceEntryTokenRegistry, "furnaceEntryTokenRegistry");
        _requireContractOrZero(p.mineCoreEntryTokenRegistry, "mineCoreEntryTokenRegistry");
        _requireContractOrZero(p.delegationHub, "delegationHub");
        _requireContractOrZero(p.claimAllHelper, "claimAllHelper");
        _requireContractOrZero(p.maintenanceHub, "maintenanceHub");
        _requireContractOrZero(p.launchController, "launchController");
        _requireContractOrZero(p.genesisLPVault24M, "genesisLPVault24M");

        // Reject EIP-7702 delegation designators on every input that the
        // AgentLens constructor will bake into immutable storage. This mirrors
        // `AgentLens._rejectDelegatedEOA` and fails fast at deploy time so the
        // operator gets a clear error before broadcasting, instead of the
        // constructor reverting mid-broadcast.
        _requireNotDelegatedEOA(p.claimToken, "claimToken");
        _requireNotDelegatedEOA(p.veClaimNFT, "veClaimNFT");
        _requireNotDelegatedEOA(p.mineCore, "mineCore");
        _requireNotDelegatedEOA(p.shareholderRoyalties, "shareholderRoyalties");
        _requireNotDelegatedEOA(p.furnace, "furnace");
        _requireNotDelegatedEOAOrZero(p.marketRouter, "marketRouter");
        _requireNotDelegatedEOAOrZero(p.lpStakingVault7D, "lpStakingVault7D");
        _requireNotDelegatedEOAOrZero(p.dexAdapter, "dexAdapter");
        _requireNotDelegatedEOAOrZero(p.furnaceEntryTokenRegistry, "furnaceEntryTokenRegistry");
        _requireNotDelegatedEOAOrZero(p.mineCoreEntryTokenRegistry, "mineCoreEntryTokenRegistry");
        _requireNotDelegatedEOAOrZero(p.delegationHub, "delegationHub");
        _requireNotDelegatedEOAOrZero(p.claimAllHelper, "claimAllHelper");
        _requireNotDelegatedEOAOrZero(p.maintenanceHub, "maintenanceHub");
        _requireNotDelegatedEOAOrZero(p.launchController, "launchController");
        _requireNotDelegatedEOAOrZero(p.genesisLPVault24M, "genesisLPVault24M");

        _requireCanonicalBundle(p);

        _startBroadcast(signer);
        AgentLens lens = new AgentLens(p);
        vm.stopBroadcast();

        // Silence unused variable warnings in older solc versions.
        lens;
    }

    function _requireCanonicalBundle(AgentLens.ConstructorParams memory p) internal view {
        _requireEqAddr(
            _readAddress(p.claimToken, IAgentLensClaimTokenLike.mineCore.selector, "claimToken.mineCore"),
            p.mineCore,
            "claimToken.mineCore"
        );
        _requireEqAddr(
            _readAddress(p.veClaimNFT, IAgentLensVeLike.claimToken.selector, "veClaimNFT.claimToken"),
            p.claimToken,
            "veClaimNFT.claimToken"
        );
        _requireEqAddr(
            _readAddress(p.veClaimNFT, IAgentLensVeLike.furnace.selector, "veClaimNFT.furnace"),
            p.furnace,
            "veClaimNFT.furnace"
        );
        _requireEqAddr(
            _readAddress(p.shareholderRoyalties, IAgentLensRoyaltiesLike.ve.selector, "shareholderRoyalties.ve"),
            p.veClaimNFT,
            "shareholderRoyalties.ve"
        );
        _requireEqAddr(
            _readAddress(
                p.shareholderRoyalties, IAgentLensRoyaltiesLike.furnace.selector, "shareholderRoyalties.furnace"
            ),
            p.furnace,
            "shareholderRoyalties.furnace"
        );
        _requireEqAddr(
            _readAddress(
                p.shareholderRoyalties, IAgentLensRoyaltiesLike.mineCore.selector, "shareholderRoyalties.mineCore"
            ),
            p.mineCore,
            "shareholderRoyalties.mineCore"
        );
        _requireEqAddr(
            _readAddress(p.furnace, IAgentLensFurnaceLike.claim.selector, "furnace.claim"),
            p.claimToken,
            "furnace.claim"
        );
        _requireEqAddr(
            _readAddress(p.furnace, IAgentLensFurnaceLike.ve.selector, "furnace.ve"), p.veClaimNFT, "furnace.ve"
        );
        _requireEqAddr(
            _readAddress(
                p.furnace, IAgentLensFurnaceLike.shareholderRoyalties.selector, "furnace.shareholderRoyalties"
            ),
            p.shareholderRoyalties,
            "furnace.shareholderRoyalties"
        );
        _requireEqAddr(
            _readAddress(p.furnace, IAgentLensFurnaceLike.mineCore.selector, "furnace.mineCore"),
            p.mineCore,
            "furnace.mineCore"
        );
        _requireEqAddr(
            _readAddress(p.mineCore, IAgentLensMineCoreLike.claim.selector, "mineCore.claim"),
            p.claimToken,
            "mineCore.claim"
        );
        _requireEqAddr(
            _readAddress(p.mineCore, IAgentLensMineCoreLike.ve.selector, "mineCore.ve"), p.veClaimNFT, "mineCore.ve"
        );
        _requireEqAddr(
            _readAddress(p.mineCore, IAgentLensMineCoreLike.royalties.selector, "mineCore.royalties"),
            p.shareholderRoyalties,
            "mineCore.royalties"
        );
        _requireEqAddr(
            _readAddress(p.mineCore, IAgentLensMineCoreLike.furnace.selector, "mineCore.furnace"),
            p.furnace,
            "mineCore.furnace"
        );

        if (p.marketRouter != address(0)) {
            _requireEqAddr(
                _readAddress(p.marketRouter, IAgentLensMarketLike.claim.selector, "marketRouter.claim"),
                p.claimToken,
                "marketRouter.claim"
            );
            _requireEqAddr(
                _readAddress(p.marketRouter, IAgentLensMarketLike.ve.selector, "marketRouter.ve"),
                p.veClaimNFT,
                "marketRouter.ve"
            );
            _requireEqAddr(
                _readAddress(p.marketRouter, IAgentLensMarketLike.royalties.selector, "marketRouter.royalties"),
                p.shareholderRoyalties,
                "marketRouter.royalties"
            );
            _requireEqAddr(
                _readAddress(p.veClaimNFT, IAgentLensVeLike.mineMarket.selector, "veClaimNFT.mineMarket"),
                p.marketRouter,
                "veClaimNFT.mineMarket"
            );
            _requireEqAddr(
                _readAddress(
                    p.shareholderRoyalties,
                    IAgentLensRoyaltiesLike.mineMarket.selector,
                    "shareholderRoyalties.mineMarket"
                ),
                p.marketRouter,
                "shareholderRoyalties.mineMarket"
            );
            _requireEqAddr(
                _readAddress(p.furnace, IAgentLensFurnaceLike.mineMarket.selector, "furnace.mineMarket"),
                p.marketRouter,
                "furnace.mineMarket"
            );
        }

        if (p.furnaceEntryTokenRegistry != address(0)) {
            _requireEqAddr(
                _readAddress(
                    p.furnace, IAgentLensFurnaceLike.entryTokenRegistry.selector, "furnace.entryTokenRegistry"
                ),
                p.furnaceEntryTokenRegistry,
                "furnace.entryTokenRegistry"
            );
        }

        if (p.mineCoreEntryTokenRegistry != address(0)) {
            _requireEqAddr(
                _readAddress(
                    p.mineCore, IAgentLensMineCoreLike.entryTokenRegistry.selector, "mineCore.entryTokenRegistry"
                ),
                p.mineCoreEntryTokenRegistry,
                "mineCore.entryTokenRegistry"
            );
        }

        if (p.delegationHub != address(0)) {
            _requireEqAddr(
                _readAddress(p.furnace, IAgentLensFurnaceLike.delegationHub.selector, "furnace.delegationHub"),
                p.delegationHub,
                "furnace.delegationHub"
            );
            _requireEqAddr(
                _readAddress(p.mineCore, IAgentLensMineCoreLike.delegationHub.selector, "mineCore.delegationHub"),
                p.delegationHub,
                "mineCore.delegationHub"
            );
        }

        if (p.claimAllHelper != address(0)) {
            _requireEqAddr(
                _readAddress(
                    p.claimAllHelper, IAgentLensClaimAllHelperLike.royalties.selector, "claimAllHelper.royalties"
                ),
                p.shareholderRoyalties,
                "claimAllHelper.royalties"
            );
            _requireEqAddr(
                _readAddress(
                    p.claimAllHelper, IAgentLensClaimAllHelperLike.mineCore.selector, "claimAllHelper.mineCore"
                ),
                p.mineCore,
                "claimAllHelper.mineCore"
            );
            _requireEqAddr(
                _readAddress(
                    p.shareholderRoyalties,
                    IAgentLensRoyaltiesLike.claimAllHelper.selector,
                    "shareholderRoyalties.claimAllHelper"
                ),
                p.claimAllHelper,
                "shareholderRoyalties.claimAllHelper"
            );
            _requireEqAddr(
                _readAddress(p.mineCore, IAgentLensMineCoreLike.claimAllHelper.selector, "mineCore.claimAllHelper"),
                p.claimAllHelper,
                "mineCore.claimAllHelper"
            );
        }

        address dexRouter;
        address dexFactory;
        address dexWeth;
        address expectedPool;
        if (p.dexAdapter != address(0)) {
            dexRouter =
                _readAddress(p.dexAdapter, IAgentLensDexLike.aerodromeRouter.selector, "dexAdapter.aerodromeRouter");
            dexFactory =
                _readAddress(p.dexAdapter, IAgentLensDexLike.defaultFactory.selector, "dexAdapter.defaultFactory");
            dexWeth = _readAddress(p.dexAdapter, IAgentLensDexLike.weth.selector, "dexAdapter.weth");
            _requireContract(dexRouter, "dexAdapter.aerodromeRouter");
            _requireContract(dexFactory, "dexAdapter.defaultFactory");
            _requireContract(dexWeth, "dexAdapter.weth");

            expectedPool = IAgentLensDexLike(p.dexAdapter).poolFor(dexWeth, p.claimToken, false, dexFactory);
            require(expectedPool != address(0), "DeployAgentLens: dexAdapter.poolFor returned 0");
        }

        if (p.maintenanceHub != address(0)) {
            require(p.marketRouter != address(0), "DeployAgentLens: maintenanceHub requires marketRouter");
            require(p.dexAdapter != address(0), "DeployAgentLens: maintenanceHub requires dexAdapter");
            _requireCodeContainsAddress(p.maintenanceHub, p.marketRouter, "maintenanceHub.marketRouter");
            _requireCodeContainsAddress(p.maintenanceHub, p.furnace, "maintenanceHub.furnace");
            _requireCodeContainsAddress(p.maintenanceHub, p.veClaimNFT, "maintenanceHub.veClaimNFT");
            _requireCodeContainsAddress(p.maintenanceHub, p.shareholderRoyalties, "maintenanceHub.shareholderRoyalties");
            _requireCodeContainsAddress(p.maintenanceHub, dexWeth, "maintenanceHub.weth");
        }

        if (p.lpStakingVault7D != address(0)) {
            require(p.dexAdapter != address(0), "DeployAgentLens: lpStakingVault7D requires dexAdapter");
            _requireEqAddr(
                _readAddress(p.lpStakingVault7D, IAgentLensLpVaultLike.claim.selector, "lpStakingVault7D.claim"),
                p.claimToken,
                "lpStakingVault7D.claim"
            );
            _requireEqAddr(
                _readAddress(p.lpStakingVault7D, IAgentLensLpVaultLike.ve.selector, "lpStakingVault7D.ve"),
                p.veClaimNFT,
                "lpStakingVault7D.ve"
            );
            _requireEqAddr(
                _readAddress(p.lpStakingVault7D, IAgentLensLpVaultLike.furnace.selector, "lpStakingVault7D.furnace"),
                p.furnace,
                "lpStakingVault7D.furnace"
            );
            _requireEqAddr(
                _readAddress(p.furnace, IAgentLensFurnaceLike.lpRewardsVault.selector, "furnace.lpRewardsVault"),
                p.lpStakingVault7D,
                "furnace.lpRewardsVault"
            );
            _requireEqAddr(
                _readAddress(p.lpStakingVault7D, IAgentLensLpVaultLike.weth.selector, "lpStakingVault7D.weth"),
                dexWeth,
                "lpStakingVault7D.weth"
            );
            _requireEqAddr(
                _readAddress(
                    p.lpStakingVault7D,
                    IAgentLensLpVaultLike.aerodromeRouter.selector,
                    "lpStakingVault7D.aerodromeRouter"
                ),
                dexRouter,
                "lpStakingVault7D.aerodromeRouter"
            );
            _requireEqAddr(
                _readAddress(
                    p.lpStakingVault7D,
                    IAgentLensLpVaultLike.aerodromeFactory.selector,
                    "lpStakingVault7D.aerodromeFactory"
                ),
                dexFactory,
                "lpStakingVault7D.aerodromeFactory"
            );
            _requireEqAddr(
                _readAddress(p.lpStakingVault7D, IAgentLensLpVaultLike.lpToken.selector, "lpStakingVault7D.lpToken"),
                expectedPool,
                "lpStakingVault7D.lpToken"
            );
        }

        address genesisPool;
        if (p.genesisLPVault24M != address(0)) {
            require(p.dexAdapter != address(0), "DeployAgentLens: genesisLPVault24M requires dexAdapter");
            genesisPool =
                _readAddress(p.genesisLPVault24M, IAgentLensGenesisVaultLike.pool.selector, "genesisLPVault24M.pool");
            _requireEqAddr(genesisPool, expectedPool, "genesisLPVault24M.pool");
            require(
                _readAddress(
                    p.genesisLPVault24M,
                    IAgentLensGenesisVaultLike.lpWithdrawRecipient.selector,
                    "genesisLPVault24M.lpWithdrawRecipient"
                ) != address(0),
                "DeployAgentLens: genesisLPVault24M.lpWithdrawRecipient mismatch"
            );
        }

        if (p.launchController != address(0)) {
            require(p.dexAdapter != address(0), "DeployAgentLens: launchController requires dexAdapter");
            require(p.genesisLPVault24M != address(0), "DeployAgentLens: launchController requires genesisLPVault24M");
            _requireEqAddr(
                _readAddress(
                    p.launchController, IAgentLensLaunchControllerLike.claim.selector, "launchController.claim"
                ),
                p.claimToken,
                "launchController.claim"
            );
            _requireEqAddr(
                _readAddress(
                    p.launchController, IAgentLensLaunchControllerLike.mineCore.selector, "launchController.mineCore"
                ),
                p.mineCore,
                "launchController.mineCore"
            );
            _requireEqAddr(
                _readAddress(
                    p.launchController,
                    IAgentLensLaunchControllerLike.genesisLpVault.selector,
                    "launchController.genesisLpVault"
                ),
                p.genesisLPVault24M,
                "launchController.genesisLpVault"
            );
            // p.dexAdapter (the DexAdapter wrapper), NOT the underlying Aerodrome router.
            // LaunchController stores the DexAdapter-compatible wrapper there as documented
            // in src/genesis/LaunchController.sol, so compare against p.dexAdapter.
            _requireEqAddr(
                _readAddress(
                    p.launchController,
                    IAgentLensLaunchControllerLike.aerodromeRouter.selector,
                    "launchController.aerodromeRouter"
                ),
                p.dexAdapter,
                "launchController.aerodromeRouter"
            );
            _requireEqAddr(
                _readAddress(p.launchController, IAgentLensLaunchControllerLike.weth.selector, "launchController.weth"),
                dexWeth,
                "launchController.weth"
            );
            _requireEqAddr(
                _readAddress(
                    p.launchController, IAgentLensLaunchControllerLike.factory.selector, "launchController.factory"
                ),
                dexFactory,
                "launchController.factory"
            );
            _requireEqAddr(
                _readAddress(
                    p.launchController,
                    IAgentLensLaunchControllerLike.expectedPool.selector,
                    "launchController.expectedPool"
                ),
                expectedPool,
                "launchController.expectedPool"
            );
        }
    }

    function _readAddress(address target, bytes4 selector, string memory label) internal view returns (address out) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        require(ok && data.length >= 32, string.concat("DeployAgentLens: unable to read ", label));
        out = abi.decode(data, (address));
    }

    function _requireEqAddr(address got, address want, string memory label) internal pure {
        require(got == want, string.concat("DeployAgentLens: ", label, " mismatch"));
    }

    function _requireCodeContainsAddress(address target, address expected, string memory label) internal view {
        bytes memory code = target.code;
        bytes memory needle = abi.encodePacked(expected);
        require(needle.length == 20, "DeployAgentLens: invalid address scan needle");

        bool found;
        if (code.length >= needle.length) {
            for (uint256 i = 0; i <= code.length - needle.length; ++i) {
                bool match_ = true;
                for (uint256 j = 0; j < needle.length; ++j) {
                    if (code[i + j] != needle[j]) {
                        match_ = false;
                        break;
                    }
                }
                if (match_) {
                    found = true;
                    break;
                }
            }
        }

        require(found, string.concat("DeployAgentLens: ", label, " mismatch"));
    }

    function _envAddressRequired(bool isLocal, string memory localKey, string memory prodKey, string memory label)
        internal
        returns (address out)
    {
        out = _envAddressOrZero(isLocal, localKey, prodKey);
        require(out != address(0), "DeployAgentLens: missing required env address");
        _requireContract(out, label);
    }

    function _envAddressOrZero(bool isLocal, string memory localKey, string memory prodKey)
        internal
        returns (address out)
    {
        if (isLocal) {
            try vm.envAddress(localKey) returns (address v) {
                out = v;
                return out;
            } catch {}
        }

        try vm.envAddress(prodKey) returns (address v2) {
            out = v2;
            return out;
        } catch {
            out = address(0);
            return out;
        }
    }

    function _requireContract(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat("DeployAgentLens: ", label, " is not a contract"));
    }

    function _requireContractOrZero(address target, string memory label) internal view {
        if (target == address(0)) return;
        _requireContract(target, label);
    }

    /// @dev Mirror of `AgentLens._rejectDelegatedEOA`. The 7702 designator is
    ///      exactly 23 bytes and starts with `0xEF0100`. We catch it here so
    ///      the operator gets a deploy-time error instead of a mid-broadcast
    ///      revert, and so the failure mode is symmetric with the lens itself.
    function _requireNotDelegatedEOA(address target, string memory label) internal view {
        if (target.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(target, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        require(prefix != 0xEF0100, string.concat("DeployAgentLens: ", label, " is an EIP-7702 delegated EOA"));
    }

    function _requireNotDelegatedEOAOrZero(address target, string memory label) internal view {
        if (target == address(0)) return;
        _requireNotDelegatedEOA(target, label);
    }
}
