// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ClaimToken} from "src/ClaimToken.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Constants} from "src/lib/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Shared deployment and wiring for all Echidna harnesses.
/// @dev Mirrors the canonical Wire.s.sol deployment order.
contract EchidnaSetup {
    ClaimToken internal claim;
    VeClaimNFT internal ve;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;
    MineCoreHarness internal mineCore;
    ShareholderRoyalties internal royalties;
    MarketRouter internal market;
    DelegationHub internal delegationHub;
    ClaimAllHelper internal claimAllHelper;
    EntryTokenRegistry internal furnaceRegistry;
    EntryTokenRegistry internal mineCoreRegistry;

    MockAerodromeRouter internal dexRouter;
    MockERC20 internal weth;
    address internal mockFactory;
    address internal wethClaimPool;

    function _deployAndWire() internal {
        address deployer = address(this);

        // --- Deploy mock DEX infrastructure ---
        weth = new MockERC20("Wrapped Ether", "WETH");
        mockFactory = address(new MockERC20("Factory", "FAC")); // just needs code
        dexRouter = new MockAerodromeRouter(mockFactory, address(weth));

        // --- Deploy ---
        claim = new ClaimToken(deployer);
        ve = new VeClaimNFT(address(claim), deployer);
        royalties = new ShareholderRoyalties(address(ve), deployer);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), deployer
        );
        quoter = new FurnaceQuoter(address(furnace));
        market = new MarketRouter(address(claim), address(ve), address(royalties), deployer);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), deployer);
        delegationHub = new DelegationHub();
        claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        furnaceRegistry = new EntryTokenRegistry(deployer);
        mineCoreRegistry = new EntryTokenRegistry(deployer);

        // --- Wire ---
        // Order matters: ve.setFurnace validates the full furnace<->mineCore<->claim
        // graph via _requireCanonicalSetterBundle, so furnace and mineCore must be
        // cross-wired before ve can accept the furnace pointer.
        claim.setMineCore(address(mineCore));

        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(market));

        mineCore.setFurnace(address(furnace));

        ve.setMineMarket(address(market));
        ve.setFurnace(address(furnace));

        royalties.setWiring(address(mineCore), address(market), address(furnace));
        royalties.setClaimAllHelper(address(claimAllHelper));

        furnace.setFurnaceQuoter(address(quoter));
        furnace.setEntryTokenRegistry(address(furnaceRegistry));
        furnace.setGuardian(address(mineCore));

        mineCore.setClaimAllHelper(address(claimAllHelper));
        mineCore.setDelegationHub(address(delegationHub));
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);

        furnace.setDelegationHub(address(delegationHub));

        // --- Configure EntryTokenRegistry router + WETH/CLAIM hop ---
        // Furnace registry: full router config + WETH/CLAIM hop
        wethClaimPool = address(new MockERC20("WETH-CLAIM Pool", "POOL"));
        dexRouter.setPoolFor(address(weth), address(claim), false, mockFactory, wethClaimPool);

        furnaceRegistry.setRouterConfig(address(dexRouter), mockFactory, address(weth), address(claim));
        furnaceRegistry.setWethClaimHop(false, wethClaimPool);

        // MineCore registry: router config
        mineCoreRegistry.setRouterConfig(address(dexRouter), mockFactory, address(weth), address(claim));

        // --- Freeze ClaimToken wiring config ---
        claim.freezeConfig();
    }
}
