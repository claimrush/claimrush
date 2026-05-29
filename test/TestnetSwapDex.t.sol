// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

import {LocalWETH} from "src/mocks/LocalWETH.sol";
import {MintableERC20} from "src/mocks/MintableERC20.sol";
import {LocalAerodromeRouter} from "src/mocks/localdex/LocalAerodromeRouter.sol";
import {TestnetSwapFactory} from "src/mocks/testnet/TestnetSwapFactory.sol";
import {TestnetSwapPool} from "src/mocks/testnet/TestnetSwapPool.sol";

/// @notice End-to-end test that simulates the full Sepolia deployment flow locally.
/// @dev Validates: CREATE2 prediction, pool configuration, swaps, LP mint, skim,
///      access control, and the critical invariant that expectedPool == deployed pool.
contract TestnetSwapDexTest is Test {
    LocalWETH weth;
    MintableERC20 claim;
    TestnetSwapFactory factory;
    LocalAerodromeRouter router;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(deployer);

        weth = new LocalWETH();
        factory = new TestnetSwapFactory(address(weth));
        router = new LocalAerodromeRouter(address(factory), address(weth));
        claim = new MintableERC20("ClaimToken", "CLAIM", 18);

        vm.stopPrank();
    }

    // ================================================================
    // A: CREATE2 prediction matches actual deployment
    // ================================================================

    function test_A1_predictedAddressMatchesCreatePool() public {
        address predicted = factory.getPool(address(weth), address(claim), false);
        assertTrue(predicted != address(0), "prediction must be non-zero");
        assertEq(predicted.code.length, 0, "no code yet at predicted address");

        vm.prank(deployer);
        address deployed = factory.createPool(address(weth), address(claim), false);

        assertEq(deployed, predicted, "CREATE2 address must match prediction");
        assertTrue(deployed.code.length > 0, "pool must have code after deployment");
    }

    function test_A2_getPoolReturnsDeployedAfterCreate() public {
        address predicted = factory.getPool(address(weth), address(claim), false);

        vm.prank(deployer);
        address deployed = factory.createPool(address(weth), address(claim), false);

        address lookup = factory.getPool(address(weth), address(claim), false);
        assertEq(lookup, deployed, "getPool must return deployed address");
        assertEq(lookup, predicted, "getPool must still equal original prediction");
    }

    function test_A3_predictionStableWithTokenOrderSwap() public {
        address p1 = factory.getPool(address(weth), address(claim), false);
        address p2 = factory.getPool(address(claim), address(weth), false);
        assertEq(p1, p2, "prediction must be order-independent");
    }

    function test_A4_createPoolRevertsOnDuplicate() public {
        vm.startPrank(deployer);
        factory.createPool(address(weth), address(claim), false);
        vm.expectRevert("POOL_EXISTS");
        factory.createPool(address(weth), address(claim), false);
        vm.stopPrank();
    }

    // ================================================================
    // B: Pool configuration (order-agnostic pricing)
    // ================================================================

    function test_B1_poolConfiguredCorrectly() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        TestnetSwapPool p = TestnetSwapPool(pool);
        assertEq(p.wethAddr(), address(weth), "wethAddr must be set");
        assertEq(p.claimPerWeth(), 864_000, "default rate must be 864000");
    }

    function test_B2_quoteWethToClaimCorrect() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        uint256 out = TestnetSwapPool(pool).quoteOut(address(weth), 1 ether);
        assertEq(out, 864_000 ether, "1 WETH -> 864k CLAIM");
    }

    function test_B3_quoteClaimToWethCorrect() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        uint256 out = TestnetSwapPool(pool).quoteOut(address(claim), 864_000 ether);
        assertEq(out, 1 ether, "864k CLAIM -> 1 WETH");
    }

    function test_B4_quoteWorksRegardlessOfAddressOrder() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);
        TestnetSwapPool p = TestnetSwapPool(pool);

        if (address(weth) < address(claim)) {
            assertEq(p.token0(), address(weth));
            assertEq(p.token1(), address(claim));
        } else {
            assertEq(p.token0(), address(claim));
            assertEq(p.token1(), address(weth));
        }

        assertEq(p.quoteOut(address(weth), 1 ether), 864_000 ether, "WETH->CLAIM");
        assertEq(p.quoteOut(address(claim), 432_000 ether), 0.5 ether, "CLAIM->WETH");
    }

    function test_B5_unconfiguredPoolFallsBackTo1to1() public {
        TestnetSwapPool raw = new TestnetSwapPool(address(weth), address(claim));
        assertEq(raw.quoteOut(address(weth), 1 ether), 1 ether, "unconfigured = 1:1");
    }

    function test_B6_configureRevertsIfAlreadyConfigured() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Pool deployer is the factory; call from factory context
        vm.prank(address(factory));
        vm.expectRevert("ALREADY_CONFIGURED");
        TestnetSwapPool(pool).configure(address(weth), 200_000);
    }

    // ================================================================
    // C: Router integration (getAmountsOut + swaps)
    // ================================================================

    function test_C1_getAmountsOutWorks() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Seed pool so liquidity check passes
        claim.mint(pool, 10_000_000 ether);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: address(weth), to: address(claim), stable: false, factory: address(factory)});

        uint256[] memory amounts = router.getAmountsOut(1 ether, routes);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], 864_000 ether);
    }

    function test_C2_swapExactETHForTokens() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        claim.mint(pool, 10_000_000 ether);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: address(weth), to: address(claim), stable: false, factory: address(factory)});

        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256[] memory amounts = router.swapExactETHForTokens{value: 1 ether}(1, routes, user, type(uint256).max);

        assertEq(amounts[1], 864_000 ether);
        assertEq(claim.balanceOf(user), 864_000 ether);
    }

    function test_C3_swapExactTokensForTokens_ClaimToWeth() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        IERC20(address(weth)).transfer(pool, 10 ether);

        uint256 claimAmt = 1_728_000 ether; // 2 WETH worth at 864k rate
        claim.mint(user, claimAmt);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: address(claim), to: address(weth), stable: false, factory: address(factory)});

        vm.startPrank(user);
        claim.approve(address(router), claimAmt);
        uint256[] memory amounts = router.swapExactTokensForTokens(claimAmt, 1, routes, user, type(uint256).max);
        vm.stopPrank();

        assertEq(amounts[1], 2 ether);
        assertEq(IERC20(address(weth)).balanceOf(user), 2 ether);
    }

    function test_C4_getAmountsOutRevertsWhenPoolDepleted() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Seed pool with minimal CLAIM (less than 1 WETH worth)
        claim.mint(pool, 1_000 ether);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: address(weth), to: address(claim), stable: false, factory: address(factory)});

        // 1 WETH would need 864k CLAIM but pool only has 1k
        vm.expectRevert(LocalAerodromeRouter.InsufficientPoolLiquidity.selector);
        router.getAmountsOut(1 ether, routes);
    }

    // ================================================================
    // D: LP mint (pool.mint) -- simulates finalizeGenesis flow
    // ================================================================

    function test_D1_lpMintWorks() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        claim.mint(pool, 500_000 ether);
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        IERC20(address(weth)).transfer(pool, 5 ether);

        address vault = makeAddr("genesisVault");
        uint256 lp = TestnetSwapPool(pool).mint(vault);

        assertTrue(lp > 0, "LP minted > 0");
        assertEq(TestnetSwapPool(pool).balanceOf(vault), lp);
        assertEq(TestnetSwapPool(pool).totalSupply(), lp);
    }

    function test_D2_lpMintProportionalToReserves() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Genesis-like seed: 5 ETH + 4.32M CLAIM (realistic Sepolia ratio)
        claim.mint(pool, 4_320_000 ether);
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        IERC20(address(weth)).transfer(pool, 5 ether);

        address vault = makeAddr("genesisVault");
        uint256 genesisLp = TestnetSwapPool(pool).mint(vault);
        assertTrue(genesisLp > 0, "genesis LP > 0");

        // Attacker deposits 1 ETH + 1 CLAIM (hugely imbalanced)
        claim.mint(pool, 1 ether);
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        IERC20(address(weth)).transfer(pool, 1 ether);

        address attackerVault = makeAddr("attackerVault");
        uint256 attackerLp = TestnetSwapPool(pool).mint(attackerVault);

        // Attacker LP should be negligible compared to genesis LP because
        // the CLAIM side (1 CLAIM vs 4.32M CLAIM) constrains the mint.
        assertTrue(attackerLp < genesisLp / 1000, "attacker LP must be < 0.1% of genesis LP");
    }

    function test_D3_lpMintFirstMintUsesSqrt() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Deposit 100 of each token (balanced)
        claim.mint(pool, 100 ether);
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        IERC20(address(weth)).transfer(pool, 100 ether);

        address vault = makeAddr("vault");
        uint256 lp = TestnetSwapPool(pool).mint(vault);

        // sqrt(100e18 * 100e18) = 100e18
        assertEq(lp, 100 ether, "first mint uses geometric mean");
    }

    // ================================================================
    // E: Full Deploy.s.sol -> CreatePool -> FinalizeGenesis flow
    // ================================================================

    function test_E1_fullDeployFlowInvariant() public {
        // Step 1: DeployTestnetSwapDex (already done in setUp)

        // Step 2: Simulate Deploy.s.sol -- queries poolFor BEFORE pool exists
        address expectedPool = router.poolFor(address(weth), address(claim), false, address(factory));
        assertTrue(expectedPool != address(0), "poolFor must be non-zero");

        // Step 3: CreateTestnetPool
        vm.prank(deployer);
        address realPool = factory.createPool(address(weth), address(claim), false);
        assertEq(realPool, expectedPool, "CREATE2 == expectedPool");

        // Step 4: Simulate finalizeGenesis
        address genesisPool = factory.getPool(address(weth), address(claim), false);
        assertEq(genesisPool, expectedPool, "getPool == expectedPool");

        claim.mint(genesisPool, 4_320_000 ether);
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        IERC20(address(weth)).transfer(genesisPool, 5 ether);

        address vault = makeAddr("genesisVault");
        uint256 lp = TestnetSwapPool(genesisPool).mint(vault);
        assertTrue(lp > 0, "LP minted");

        // Post-genesis swap should work
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: address(weth), to: address(claim), stable: false, factory: address(factory)});

        vm.deal(user, 0.001 ether);
        vm.prank(user);
        uint256[] memory amounts = router.swapExactETHForTokens{value: 0.001 ether}(1, routes, user, type(uint256).max);
        assertEq(amounts[1], 864 ether);
    }

    // ================================================================
    // F: Skim -- [B2] donation DoS prevention
    // ================================================================

    function test_F1_skimClearsDonatedTokens() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Donate tokens to pool (simulates attacker griefing pre-genesis)
        claim.mint(pool, 1 ether);
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        IERC20(address(weth)).transfer(pool, 1 ether);

        address recipient = makeAddr("skimRecipient");
        TestnetSwapPool(pool).skim(recipient);

        assertEq(claim.balanceOf(recipient), 1 ether, "CLAIM skimmed");
        assertEq(IERC20(address(weth)).balanceOf(recipient), 1 ether, "WETH skimmed");
        assertEq(claim.balanceOf(pool), 0, "pool CLAIM cleared");
        assertEq(IERC20(address(weth)).balanceOf(pool), 0, "pool WETH cleared");
    }

    function test_F2_skimOnlyRemovesExcessAboveReserves() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Seed pool and mint LP (establishes reserves) at the canonical
        // Sepolia genesis ratio of 5 ETH + 4.32M CLAIM.
        claim.mint(pool, 4_320_000 ether);
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        IERC20(address(weth)).transfer(pool, 5 ether);
        TestnetSwapPool(pool).mint(makeAddr("vault"));

        // Donate extra
        claim.mint(pool, 500 ether);

        address recipient = makeAddr("skimRecipient");
        TestnetSwapPool(pool).skim(recipient);

        assertEq(claim.balanceOf(recipient), 500 ether, "only excess CLAIM skimmed");
        assertEq(IERC20(address(weth)).balanceOf(recipient), 0, "no excess WETH");
    }

    function test_F3_skimCannotCapturePostSwapBalances() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Seed the pool with CLAIM liquidity and mint LP (enough for a 1 ETH swap at 864k rate)
        claim.mint(pool, 50_000_000 ether);
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        IERC20(address(weth)).transfer(pool, 10 ether);
        TestnetSwapPool(pool).mint(makeAddr("vault"));

        // Swap: user sends WETH, gets CLAIM. Pool's WETH balance increases.
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: address(weth), to: address(claim), stable: false, factory: address(factory)});

        vm.deal(user, 1 ether);
        vm.prank(user);
        router.swapExactETHForTokens{value: 1 ether}(1, routes, user, type(uint256).max);

        // Attacker tries to skim the newly deposited WETH
        address skimRecipient = makeAddr("skimRecipient");
        vm.prank(attacker);
        TestnetSwapPool(pool).skim(skimRecipient);

        // Reserves are updated by swap(), so skim() cannot capture the WETH
        assertEq(IERC20(address(weth)).balanceOf(skimRecipient), 0, "skim must not capture post-swap WETH");
        assertEq(claim.balanceOf(skimRecipient), 0, "skim must not capture post-swap CLAIM");
    }

    // ================================================================
    // F4-F5: Direct pool.swap() without prior transfer (free-drain)
    // ================================================================

    function test_F4_directSwapWithoutTransferRevertsWETH() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Seed pool with liquidity and mint LP
        claim.mint(pool, 1_000_000 ether);
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        IERC20(address(weth)).transfer(pool, 10 ether);
        TestnetSwapPool(pool).mint(makeAddr("vault"));

        // Attacker calls swap directly without transferring WETH first
        vm.prank(attacker);
        vm.expectRevert("INSUFFICIENT_INPUT");
        TestnetSwapPool(pool).swap(address(weth), 1 ether, attacker);
    }

    function test_F5_directSwapWithoutTransferRevertsCLAIM() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        // Seed pool with liquidity and mint LP
        claim.mint(pool, 1_000_000 ether);
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        IERC20(address(weth)).transfer(pool, 10 ether);
        TestnetSwapPool(pool).mint(makeAddr("vault"));

        // Attacker calls swap directly without transferring CLAIM first
        vm.prank(attacker);
        vm.expectRevert("INSUFFICIENT_INPUT");
        TestnetSwapPool(pool).swap(address(claim), 864_000 ether, attacker);
    }

    // ================================================================
    // G: Access control -- [H1] [H2]
    // ================================================================

    function test_G1_nonOwnerCannotCreatePool() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        factory.createPool(address(weth), address(claim), false);
    }

    function test_G2_nonOwnerCannotRegisterPool() public {
        TestnetSwapPool manual = new TestnetSwapPool(address(weth), address(claim));

        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        factory.registerPool(address(weth), address(claim), false, address(manual));
    }

    function test_G3_nonOwnerCannotSetDefaultRate() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        factory.setDefaultRate(200_000);
    }

    function test_G4_nonOwnerCannotSetPoolRate() public {
        vm.prank(deployer);
        factory.createPool(address(weth), address(claim), false);

        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        factory.setPoolRate(address(weth), address(claim), false, 50_000);
    }

    function test_G5_nonDeployerCannotConfigurePool() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        vm.prank(attacker);
        vm.expectRevert("NOT_DEPLOYER");
        TestnetSwapPool(pool).setClaimPerWeth(50_000);
    }

    function test_G6_ownerCanSetPoolRateViaFactory() public {
        vm.prank(deployer);
        address pool = factory.createPool(address(weth), address(claim), false);

        vm.prank(deployer);
        factory.setPoolRate(address(weth), address(claim), false, 50_000);

        assertEq(TestnetSwapPool(pool).claimPerWeth(), 50_000);
        assertEq(TestnetSwapPool(pool).quoteOut(address(weth), 1 ether), 50_000 ether);
    }

    function test_G7_registerPoolValidatesTokens() public {
        TestnetSwapPool manual = new TestnetSwapPool(address(weth), address(claim));

        MintableERC20 other = new MintableERC20("Other", "OTH", 18);

        vm.prank(deployer);
        vm.expectRevert("TOKEN_MISMATCH");
        factory.registerPool(address(other), address(claim), false, address(manual));
    }

    function test_G8_registerPoolRequiresCode() public {
        vm.prank(deployer);
        vm.expectRevert("POOL_NO_CODE");
        factory.registerPool(address(weth), address(claim), false, makeAddr("noCode"));
    }

    function test_G9_registerPoolValidatesWeth() public {
        // Deploy pool with wrong WETH direction
        TestnetSwapPool manual = new TestnetSwapPool(address(weth), address(claim));
        manual.configure(address(claim), 4_320_000); // wethAddr = claim (wrong!)

        vm.prank(deployer);
        vm.expectRevert("WETH_MISMATCH");
        factory.registerPool(address(weth), address(claim), false, address(manual));
    }

    function test_G10_registerPoolValidatesRate() public {
        // Unconfigured pool has wethAddr == address(0) → WETH_MISMATCH
        TestnetSwapPool manual = new TestnetSwapPool(address(weth), address(claim));

        vm.prank(deployer);
        vm.expectRevert("WETH_MISMATCH"); // wethAddr is 0, not wethAddress
        factory.registerPool(address(weth), address(claim), false, address(manual));
    }

    // ================================================================
    // H: Edge cases
    // ================================================================

    function test_H1_differentStablePoolHasDifferentAddress() public {
        address vol = factory.getPool(address(weth), address(claim), false);
        address sta = factory.getPool(address(weth), address(claim), true);
        assertTrue(vol != sta);
    }

    function test_H2_customRateViaSetDefaultRate() public {
        vm.startPrank(deployer);
        factory.setDefaultRate(200_000);
        address pool = factory.createPool(address(weth), address(claim), false);
        vm.stopPrank();

        assertEq(TestnetSwapPool(pool).claimPerWeth(), 200_000);
        assertEq(TestnetSwapPool(pool).quoteOut(address(weth), 1 ether), 200_000 ether);
    }

    function test_H3_registerPoolAcceptsValidExternalPool() public {
        // Externally deployed pool with correct configuration
        TestnetSwapPool manual = new TestnetSwapPool(address(weth), address(claim));
        manual.configure(address(weth), 4_320_000);

        vm.prank(deployer);
        factory.registerPool(address(weth), address(claim), false, address(manual));

        assertEq(factory.getPool(address(weth), address(claim), false), address(manual));
    }

    receive() external payable {}
}
