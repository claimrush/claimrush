// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LaunchController} from "src/genesis/LaunchController.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {IAerodromePoolMint} from "src/interfaces/IAerodromePoolMint.sol";
import {IAerodromePoolSkim} from "src/interfaces/IAerodromePoolSkim.sol";
import {IGenesisLPVault24M} from "src/interfaces/IGenesisLPVault24M.sol";

contract LaunchControllerTest is Test {
    // Mirror LaunchController event for expectEmit.
    event GenesisFinalized(
        uint256 timestamp,
        uint256 claimMinted,
        uint256 claimToLiquidity,
        uint256 lpMinted,
        address pool,
        address genesisLpVault
    );

    MockWETH internal weth;
    MockERC20 internal claim;

    MockPoolFactory internal factory;
    MockAerodromeRouter internal router;
    MockGenesisPool internal pool;

    MockGenesisLPVault internal lpVault;
    MockMineCoreGenesis internal mineCore;

    LaunchController internal controller;

    uint256 internal constant CLAIM_MINTED = 10_000e18;

    function setUp() public {
        weth = new MockWETH();
        claim = new MockERC20("CLAIM", "CLAIM");

        factory = new MockPoolFactory();
        router = new MockAerodromeRouter(address(factory), address(weth));

        pool = new MockGenesisPool();
        factory.setPool(address(pool));

        // Deterministic poolFor resolution used by LaunchController.
        router.setPoolFor(address(weth), address(claim), false, address(factory), address(pool));

        lpVault = new MockGenesisLPVault(address(pool));

        mineCore = new MockMineCoreGenesis(address(claim), block.timestamp, CLAIM_MINTED);

        controller =
            new LaunchController(address(claim), address(mineCore), address(lpVault), address(router), address(this));

        mineCore.setCollector(address(controller));
        mineCore.setTakeoversPaused(true);

        // Ensure this test contract can pay the 50 ETH seed.
        vm.deal(address(this), 100 ether);
    }

    function testFinalizeGenesisHappyPath() public {
        // Move beyond genesis accrual window.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        // All minted CLAIM goes to liquidity (no genesis ve lock).
        uint256 expectedClaimToLiquidity = CLAIM_MINTED;
        uint256 expectedLpMinted = pool.NEXT_LP_MINT();

        vm.expectEmit(true, true, true, true);
        emit GenesisFinalized(
            block.timestamp, CLAIM_MINTED, expectedClaimToLiquidity, expectedLpMinted, address(pool), address(lpVault)
        );

        controller.finalizeGenesis{value: 50 ether}();

        assertTrue(controller.genesisFinalized());
        assertEq(controller.genesisClaimMinted(), CLAIM_MINTED);
        assertEq(controller.genesisClaimToLiquidity(), expectedClaimToLiquidity);
        assertEq(controller.genesisLpMinted(), expectedLpMinted);
        assertEq(controller.genesisFinalizedAt(), block.timestamp);

        // MineCore must be unpaused.
        assertFalse(mineCore.takeoversPaused());

        // LP lock must be started.
        assertEq(lpVault.startLockCalls(), 1);

        // LP minted directly to the LP vault.
        assertEq(pool.balanceOf(address(lpVault)), expectedLpMinted);
        assertEq(pool.balanceOf(address(controller)), 0);

        // LaunchController must not retain assets.
        assertEq(claim.balanceOf(address(controller)), 0);
        assertEq(weth.balanceOf(address(controller)), 0);
        assertEq(address(controller).balance, 0);
    }

    function testConstructorRevertsWhenClaimIsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(address(0xBEEF), address(mineCore), address(lpVault), address(router), address(this));
    }

    function testConstructorRevertsWhenMineCoreIsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(address(claim), address(0xCAFE), address(lpVault), address(router), address(this));
    }

    function testConstructorRevertsWhenGenesisLpVaultIsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(address(claim), address(mineCore), address(0xDEAD), address(router), address(this));
    }

    function testConstructorRevertsWhenRouterIsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(address(claim), address(mineCore), address(lpVault), address(0xF00D), address(this));
    }

    function testConstructorRevertsWhenRouterReportsNonContractFactory() public {
        MockAerodromeRouter badRouter = new MockAerodromeRouter(address(0xFACA), address(weth));

        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(address(claim), address(mineCore), address(lpVault), address(badRouter), address(this));
    }

    function testConstructorRevertsWhenRouterReportsNonContractWeth() public {
        MockAerodromeRouter badRouter = new MockAerodromeRouter(address(factory), address(0xB0B));

        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(address(claim), address(mineCore), address(lpVault), address(badRouter), address(this));
    }

    /// @dev EIP-7702 delegation designators carry exactly 23 bytes of code
    ///      (`0xEF0100 || target20`) so the prior `code.length == 0` rejection is
    ///      bypassable by a designator pointing at any contract. Constructor must
    ///      reject the designator shape on every wiring root.
    function testConstructorRevertsOnDelegatedEoaGuardian() public {
        address eoa = address(0xE0A);
        bytes memory designator = abi.encodePacked(bytes3(0xEF0100), bytes20(address(claim)));
        vm.etch(eoa, designator);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LaunchController(address(claim), address(mineCore), address(lpVault), address(router), eoa);
    }

    function testConstructorRevertsOnDelegatedEoaClaim() public {
        address eoa = address(0xC1A);
        bytes memory designator = abi.encodePacked(bytes3(0xEF0100), bytes20(address(claim)));
        vm.etch(eoa, designator);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LaunchController(eoa, address(mineCore), address(lpVault), address(router), address(this));
    }

    /// @dev Self-installation guard. The controller becomes the temporary MineCore
    ///      guardian during finalize and rotates the role to `guardian` at the end.
    ///      If `_guardian == address(this)` the rotation is a no-op and the
    ///      controller permanently holds the role. The constructor reverts up front
    ///      with `GenesisPoolMismatch` (shared selector for self-collision class).
    function testConstructorRevertsWhenGuardianEqualsSelf() public {
        bytes memory ctorArgs = abi.encode(address(claim), address(mineCore), address(lpVault), address(router));
        bytes memory bytecode = abi.encodePacked(type(LaunchController).creationCode, ctorArgs);

        // The constructor reads `_guardian` and compares to `address(this)` of the
        // contract under construction. Using `vm.expectRevert` against the
        // CREATE2-derivable address is heavy; instead, deploy normally and assert
        // the constructor rejects the case via the controller's own deployment.
        // We use a sentinel by deploying twice: the second deployment passes the
        // first deployment's address as `_guardian`, which is irrelevant; the
        // self-equality guard fires only when `_guardian == address(this)` at
        // construction. Since we cannot pre-compute the CREATE address easily in
        // this test contract context, this test asserts the related bytecode
        // shape: the constructor MUST contain the self-equality guard.
        bytecode; // silence unused warning

        // Pragmatic equivalent: assert the runtime check by constructing with a
        // guardian that we KNOW is the eventual deployment address using `new`
        // with deterministic CREATE. Foundry exposes `vm.computeCreateAddress`.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(Errors.GenesisPoolMismatch.selector);
        new LaunchController(address(claim), address(mineCore), address(lpVault), address(router), predicted);
    }

    function testConstructorRevertsWhenMineCoreClaimRootMismatches() public {
        MockERC20 otherClaim = new MockERC20("OTHER", "OTHER");
        MockMineCoreGenesis badMineCore = new MockMineCoreGenesis(address(otherClaim), block.timestamp, CLAIM_MINTED);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new LaunchController(address(claim), address(badMineCore), address(lpVault), address(router), address(this));
    }

    function testConstructorRevertsWhenGenesisLpVaultPoolMismatchesCanonicalPool() public {
        MockGenesisLPVault wrongVault = new MockGenesisLPVault(address(0xDEAD));

        vm.expectRevert(Errors.GenesisPoolMismatch.selector);
        new LaunchController(address(claim), address(mineCore), address(wrongVault), address(router), address(this));
    }

    function testConstructorRevertsWhenRouterReportsZeroCanonicalPool() public {
        MockAerodromeRouter badRouter = new MockAerodromeRouter(address(factory), address(weth));

        vm.expectRevert(Errors.GenesisPoolMismatch.selector);
        new LaunchController(address(claim), address(mineCore), address(lpVault), address(badRouter), address(this));
    }

    function testFuzzConstructorRevertsWhenGenesisLpVaultPoolMismatchesCanonicalPool(address wrongPool) public {
        vm.assume(wrongPool != address(0));
        vm.assume(wrongPool != address(pool));

        MockGenesisLPVault wrongVault = new MockGenesisLPVault(wrongPool);

        vm.expectRevert(Errors.GenesisPoolMismatch.selector);
        new LaunchController(address(claim), address(mineCore), address(wrongVault), address(router), address(this));
    }

    function testFuzzConstructorRevertsWhenClaimIsEoa(address badClaim) public {
        vm.assume(badClaim != address(0));
        vm.assume(badClaim.code.length == 0);

        vm.expectRevert(Errors.NotAContract.selector);
        new LaunchController(badClaim, address(mineCore), address(lpVault), address(router), address(this));
    }

    function testFinalizeGenesisRevertsIfTooEarly() public {
        // emissionStartTime is now; calling immediately is too early.
        vm.expectRevert();
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFinalizeGenesisRevertsIfWrongSeedEth() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.expectRevert();
        controller.finalizeGenesis{value: 49.99 ether}();

        vm.expectRevert();
        controller.finalizeGenesis{value: 0}();
    }

    /// @notice Pin proportional `requiredSeedEth` math at canonical durations and at one
    ///         non-canonical duration to expose any future regression in the scaling formula.
    function testFinalizeGenesisRequiredSeedEthScalesWithDuration() public {
        _assertRequiredSeedForDuration(1 days, 5 ether);
        _assertRequiredSeedForDuration(5 days, 25 ether);
        _assertRequiredSeedForDuration(10 days, 50 ether);
        _assertRequiredSeedForDuration(10 days + 1, 50000057870370370370);
    }

    function _assertRequiredSeedForDuration(uint256 duration, uint256 requiredSeedEth) internal {
        MockPoolFactory seedFactory = new MockPoolFactory();
        MockAerodromeRouter seedRouter = new MockAerodromeRouter(address(seedFactory), address(weth));
        MockGenesisPool seedPool = new MockGenesisPool();
        seedFactory.setPool(address(seedPool));
        seedRouter.setPoolFor(address(weth), address(claim), false, address(seedFactory), address(seedPool));

        MockGenesisLPVault seedVault = new MockGenesisLPVault(address(seedPool));
        MockMineCoreGenesis seedMineCore = new MockMineCoreGenesis(address(claim), block.timestamp, CLAIM_MINTED);
        seedMineCore.setGenesisAccrualDuration(duration);

        LaunchController seedController = new LaunchController(
            address(claim), address(seedMineCore), address(seedVault), address(seedRouter), address(this)
        );
        seedMineCore.setCollector(address(seedController));
        seedMineCore.setTakeoversPaused(true);

        vm.warp(seedMineCore.emissionStartTime() + duration);

        // Re-fund per iteration so cumulative `requiredSeedEth` across all four
        // duration probes does not exhaust the test contract's balance. A reverted
        // call returns msg.value, so the floor needed is `requiredSeedEth + 1` for
        // the success-path call alone.
        vm.deal(address(this), requiredSeedEth + 1);

        vm.expectRevert(Errors.GenesisExactSeedRequired.selector);
        seedController.finalizeGenesis{value: requiredSeedEth - 1}();

        seedController.finalizeGenesis{value: requiredSeedEth}();
        assertTrue(seedController.genesisFinalized());
    }

    function testFinalizeGenesisRevertsIfTakeoversNotPaused() public {
        mineCore.setTakeoversPaused(false);
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.expectRevert();
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFinalizeGenesisRevertsIfPoolNotEmpty() public {
        // Pre-seed LP supply.
        pool.mint(address(0xBEEF), 1);

        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.expectRevert(LaunchController.PoolNotEmpty.selector);
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFinalizeGenesisRevertsIfPoolHasDonatedClaim() public {
        // Attacker transfers tokens to pool without minting LP (totalSupply stays 0).
        // LaunchController must revert if donations remain after skim to prevent ratio skew.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        claim.mint(address(pool), 1);

        vm.expectRevert(LaunchController.PoolDonationRemains.selector);
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFinalizeGenesisRevertsIfPoolHasDonatedWeth() public {
        // Attacker transfers WETH to pool without minting LP (totalSupply stays 0).
        // LaunchController must revert if donations remain after skim to prevent ratio skew.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(address(pool), 1 ether));

        vm.expectRevert(LaunchController.PoolDonationRemains.selector);
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFinalizeGenesisDoesNotRevertIfControllerHasDonatedWeth() public {
        // Anyone can transfer ERC20s to a contract address; this must not brick genesis.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(address(controller), 1 ether));

        controller.finalizeGenesis{value: 50 ether}();
        assertTrue(controller.genesisFinalized());
        assertEq(weth.balanceOf(address(controller)), 0);
    }

    function testFinalizeGenesisIgnoresControllerDonatedClaimForLiquidity() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        uint256 donatedClaim = 123e18;
        claim.mint(address(controller), donatedClaim);

        controller.finalizeGenesis{value: 50 ether}();

        assertTrue(controller.genesisFinalized());
        assertEq(controller.genesisClaimMinted(), CLAIM_MINTED);
        assertEq(controller.genesisClaimToLiquidity(), CLAIM_MINTED);
        assertEq(claim.balanceOf(address(pool)), CLAIM_MINTED);
        assertEq(claim.balanceOf(address(lpVault)), 0);
    }

    function testFinalizeGenesisSweepsControllerDonatedClaimToGuardian() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        uint256 donatedClaim = 77e18;
        claim.mint(address(controller), donatedClaim);

        controller.finalizeGenesis{value: 50 ether}();

        assertEq(claim.balanceOf(address(controller)), 0);
        assertEq(claim.balanceOf(address(this)), donatedClaim);
    }

    function testFinalizeGenesisEventUsesMintedClaimOnlyWhenControllerHasDonatedClaim() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        claim.mint(address(controller), 5e18);

        uint256 expectedLpMinted = pool.NEXT_LP_MINT();

        vm.expectEmit(true, true, true, true);
        emit GenesisFinalized(
            block.timestamp, CLAIM_MINTED, CLAIM_MINTED, expectedLpMinted, address(pool), address(lpVault)
        );

        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFuzz_FinalizeGenesisIgnoresControllerDonatedClaim(uint96 donatedClaim) public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.assume(donatedClaim != 0);
        claim.mint(address(controller), uint256(donatedClaim));

        controller.finalizeGenesis{value: 50 ether}();

        assertEq(controller.genesisClaimToLiquidity(), CLAIM_MINTED);
        assertEq(claim.balanceOf(address(pool)), CLAIM_MINTED);
        assertEq(claim.balanceOf(address(controller)), 0);
        assertEq(claim.balanceOf(address(this)), uint256(donatedClaim));
    }

    function testFinalizeGenesisRevertsIfCalledTwice() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());
        controller.finalizeGenesis{value: 50 ether}();

        vm.expectRevert();
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testLaunchControllerHasNoExternalSweepSurface() public {
        vm.warp(mineCore.emissionStartTime() + 10 days);

        (bool okSweepToken,) = address(controller).call(abi.encodeWithSignature("sweepToken(address)", address(claim)));
        (bool okSweepEth,) = address(controller).call(abi.encodeWithSignature("sweepETH()"));
        (bool okReceive,) = address(controller).call{value: 1 ether}("");

        assertFalse(okSweepToken);
        assertFalse(okSweepEth);
        assertFalse(okReceive);
    }

    function testFinalizeGenesisRevertsIfRouterWethChanges() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        router.setWeth(address(0x1234));
        vm.expectRevert();
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFinalizeGenesisSucceedsWhenRouterDefaultFactoryChangesAfterDeployment() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        MockPoolFactory foreignFactory = new MockPoolFactory();
        router.setDefaultFactory(address(foreignFactory));

        controller.finalizeGenesis{value: 50 ether}();

        assertTrue(controller.genesisFinalized());
        assertEq(controller.factory(), address(factory));
        assertEq(pool.balanceOf(address(lpVault)), pool.NEXT_LP_MINT());
    }

    function testFinalizeGenesisIgnoresForeignFactoryThatWouldReturnWrongPool() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        MockPoolFactory foreignFactory = new MockPoolFactory();
        MockGenesisPool foreignPool = new MockGenesisPool();
        foreignFactory.setPool(address(foreignPool));
        router.setDefaultFactory(address(foreignFactory));

        controller.finalizeGenesis{value: 50 ether}();

        assertTrue(controller.genesisFinalized());
        assertEq(pool.balanceOf(address(lpVault)), pool.NEXT_LP_MINT());
        assertEq(foreignPool.balanceOf(address(lpVault)), 0);
    }

    function testFuzz_FinalizeGenesisSucceedsDespiteRouterDefaultFactoryDrift(address foreignFactoryAddr) public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.assume(foreignFactoryAddr != address(0));
        vm.assume(foreignFactoryAddr != address(factory));

        router.setDefaultFactory(foreignFactoryAddr);

        controller.finalizeGenesis{value: 50 ether}();

        assertTrue(controller.genesisFinalized());
        assertEq(controller.factory(), address(factory));
        assertEq(pool.balanceOf(address(lpVault)), pool.NEXT_LP_MINT());
    }

    function testFinalizeGenesisRevertsIfRouterPoolForChanges() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        // Re-point poolFor to a different address.
        router.setPoolFor(address(weth), address(claim), false, address(factory), address(0xB0B));

        vm.expectRevert();
        controller.finalizeGenesis{value: 50 ether}();
    }

    // --- non-guardian caller rejection ---

    function testFinalizeGenesisRevertsIfNotGuardian() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.deal(address(0xBEEF), 50 ether);
        vm.prank(address(0xBEEF));
        controller.finalizeGenesis{value: 50 ether}();
    }

    function testFuzz_FinalizeGenesisRevertsIfNotGuardian(address caller) public {
        vm.assume(caller != address(this)); // address(this) is the guardian
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.deal(caller, 50 ether);
        vm.prank(caller);
        controller.finalizeGenesis{value: 50 ether}();
    }

    // --- successful skim path ---

    function testFinalizeGenesisSucceedsAfterSkimmingPoolDonations() public {
        // Deploy a skimmable pool variant that clears donations on skim.
        SkimmableMockGenesisPool skimmablePool = new SkimmableMockGenesisPool(address(weth), address(claim));
        factory.setPool(address(skimmablePool));
        router.setPoolFor(address(weth), address(claim), false, address(factory), address(skimmablePool));

        MockGenesisLPVault skimVault = new MockGenesisLPVault(address(skimmablePool));

        MockMineCoreGenesis skimMineCore = new MockMineCoreGenesis(address(claim), block.timestamp, CLAIM_MINTED);

        LaunchController skimController = new LaunchController(
            address(claim), address(skimMineCore), address(skimVault), address(router), address(this)
        );

        skimMineCore.setCollector(address(skimController));
        skimMineCore.setTakeoversPaused(true);

        vm.warp(skimMineCore.emissionStartTime() + skimMineCore.GENESIS_ACCRUAL_DURATION());

        // Donate tokens to the pool before genesis (simulating attacker donation).
        weth.deposit{value: 0.5 ether}();
        assertTrue(weth.transfer(address(skimmablePool), 0.5 ether));
        claim.mint(address(skimmablePool), 42e18);

        // Genesis must succeed: skim clears donations, then proceeds normally.
        skimController.finalizeGenesis{value: 50 ether}();

        assertTrue(skimController.genesisFinalized());
        assertEq(skimController.genesisClaimMinted(), CLAIM_MINTED);
        assertEq(skimController.genesisClaimToLiquidity(), CLAIM_MINTED);

        // Skimmed donations went to guardian (address(this)).
        // Controller must not retain assets.
        assertEq(claim.balanceOf(address(skimController)), 0);
        assertEq(weth.balanceOf(address(skimController)), 0);
    }

    // --- guardian rotation verification ---

    function testFinalizeGenesisRotatesGuardian() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        controller.finalizeGenesis{value: 50 ether}();

        // Verify guardian was rotated to the operational guardian (address(this) in test setup).
        assertEq(mineCore.lastGuardianSet(), address(this));
    }

    function testFinalizeGenesisRevertsIfOverpaidSeedEth() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        vm.expectRevert(Errors.GenesisExactSeedRequired.selector);
        controller.finalizeGenesis{value: 50.01 ether}();
    }

    // --- preflight() read-only mirror of finalizeGenesis preconditions ---

    function testPreflightAllBitsSetWhenReadyToFinalize() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        (uint256 status, uint256 requiredSeedEth) = controller.preflight();

        // Bits 0..10 must all be set: not finalized, duration > 0, t0 > 0, window
        // complete, paused, vault.pool() matches, router.weth() matches,
        // router.poolFor() matches, pool empty (totalSupply==0), pool no-donations,
        // expectedPool != self.
        uint256 expectedBits = (uint256(1) << 11) - 1;
        assertEq(status, expectedBits, "all preflight bits 0..10 must be set");
        assertEq(requiredSeedEth, 50 ether, "requiredSeedEth must mirror finalizeGenesis");
    }

    function testPreflightTreatsUndeployedPoolAsZeroSupply() public {
        address ghostPool = makeAddr("ghostPool");
        assertEq(ghostPool.code.length, 0, "ghost pool has no code");

        MockPoolFactory ghostFactory = new MockPoolFactory();
        MockAerodromeRouter ghostRouter = new MockAerodromeRouter(address(ghostFactory), address(weth));
        ghostFactory.setPool(ghostPool);
        ghostRouter.setPoolFor(address(weth), address(claim), false, address(ghostFactory), ghostPool);

        MockGenesisLPVault ghostVault = new MockGenesisLPVault(ghostPool);
        MockMineCoreGenesis ghostMineCore = new MockMineCoreGenesis(address(claim), block.timestamp, CLAIM_MINTED);
        LaunchController ghostController = new LaunchController(
            address(claim), address(ghostMineCore), address(ghostVault), address(ghostRouter), address(this)
        );

        vm.warp(ghostMineCore.emissionStartTime() + ghostMineCore.GENESIS_ACCRUAL_DURATION());

        (uint256 status,) = ghostController.preflight();
        assertEq(status & (1 << 8), 1 << 8, "undeployed pool has zero LP supply");
        assertEq(status & (1 << 9), 1 << 9, "undeployed pool balances are removable after creation");
    }

    function testPreflightTreatsSkimmablePoolBalancesAsFinalizable() public {
        SkimmableMockGenesisPool skimPool = new SkimmableMockGenesisPool(address(weth), address(claim));
        MockPoolFactory skimFactory = new MockPoolFactory();
        MockAerodromeRouter skimRouter = new MockAerodromeRouter(address(skimFactory), address(weth));
        skimFactory.setPool(address(skimPool));
        skimRouter.setPoolFor(address(weth), address(claim), false, address(skimFactory), address(skimPool));

        MockGenesisLPVault skimVault = new MockGenesisLPVault(address(skimPool));
        MockMineCoreGenesis skimMineCore = new MockMineCoreGenesis(address(claim), block.timestamp, CLAIM_MINTED);
        LaunchController skimController = new LaunchController(
            address(claim), address(skimMineCore), address(skimVault), address(skimRouter), address(this)
        );

        weth.deposit{value: 0.5 ether}();
        assertTrue(weth.transfer(address(skimPool), 0.5 ether));
        claim.mint(address(skimPool), 42e18);
        vm.warp(skimMineCore.emissionStartTime() + skimMineCore.GENESIS_ACCRUAL_DURATION());

        (uint256 status,) = skimController.preflight();
        assertEq(status & (1 << 8), 1 << 8, "pool has zero LP supply");
        assertEq(status & (1 << 9), 1 << 9, "zero-supply pool balances are skimmable");
    }

    function testPreflightDropsBitWhenWindowIncomplete() public {
        // No warp -> block.timestamp == emissionStartTime, window NOT complete.
        (uint256 status,) = controller.preflight();
        assertEq(status & (1 << 3), 0, "bit 3 (window complete) must be unset");
        assertGt(status & (1 << 0), 0, "bit 0 (!finalized) must be set");
    }

    function testPreflightDropsBitWhenTakeoversNotPaused() public {
        mineCore.setTakeoversPaused(false);
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        (uint256 status,) = controller.preflight();
        assertEq(status & (1 << 4), 0, "bit 4 (takeoversPaused) must be unset");
    }

    function testPreflightAfterFinalizeFlipsFinalizedBit() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());
        controller.finalizeGenesis{value: 50 ether}();

        (uint256 status,) = controller.preflight();
        assertEq(status & (1 << 0), 0, "bit 0 (!finalized) must clear after finalize");
        // bit 4 (takeoversPaused) clears too because finalize unpaused.
        assertEq(status & (1 << 4), 0, "bit 4 (takeoversPaused) clears post-finalize");
    }

    // --- sweep best-effort: misbehaving token must not brick finalize ---

    /// @notice The post-finalize residual sweep is best-effort. When a swept
    ///         token's `transfer` reverts the controller emits `SweepFailed` and
    ///         finalization completes, leaving the donation on the controller.
    ///         Without this the entire one-shot genesis would unwind on a
    ///         misbehaving donation, which is unrecoverable on a live deploy.
    function testFinalizeGenesisToleratesSweepRevertOnDonatedToken() public {
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());

        // Re-wire the controller against a conditionally-misbehaving WETH that
        // serves the seed flow normally (deposit + transfer to pool) but reverts
        // on the guardian-targeted sweep transfer. We deploy a fresh controller
        // bundle pointing at this token so the sweep path actually fires.
        ConditionallyRevertingWETH crWeth = new ConditionallyRevertingWETH();
        MockPoolFactory crFactory = new MockPoolFactory();
        MockAerodromeRouter crRouter = new MockAerodromeRouter(address(crFactory), address(crWeth));
        MockGenesisPool crPool = new MockGenesisPool();
        crFactory.setPool(address(crPool));
        crRouter.setPoolFor(address(crWeth), address(claim), false, address(crFactory), address(crPool));

        MockGenesisLPVault crVault = new MockGenesisLPVault(address(crPool));
        MockMineCoreGenesis crMineCore = new MockMineCoreGenesis(address(claim), block.timestamp, CLAIM_MINTED);

        LaunchController crController = new LaunchController(
            address(claim), address(crMineCore), address(crVault), address(crRouter), address(this)
        );
        crMineCore.setCollector(address(crController));
        crMineCore.setTakeoversPaused(true);

        vm.warp(crMineCore.emissionStartTime() + crMineCore.GENESIS_ACCRUAL_DURATION());

        // Donate WETH to the controller so the sweep step has a non-zero balance
        // to move (canonical seed wires WETH balance to zero before sweep).
        crWeth.mint(address(crController), 1 ether);

        // Configure the WETH to revert on any transfer to the guardian. The seed
        // transfer is to the pool address (different from guardian) so the seed
        // flow still succeeds.
        crWeth.setRevertOnTransferTo(address(this), true);

        vm.deal(address(this), 50 ether);
        crController.finalizeGenesis{value: 50 ether}();

        assertTrue(crController.genesisFinalized(), "finalize must complete despite sweep revert");
        // Donation persists on the controller because the sweep transfer reverted.
        assertEq(
            crWeth.balanceOf(address(crController)), 1 ether, "donated WETH stays on controller when sweep reverts"
        );
    }
}

/// @dev WETH-shaped mock that supports the seed flow (deposit + arbitrary transfer)
///      but conditionally reverts when the recipient matches a configured target.
///      Drives the best-effort sweep path in LaunchController._sweepToken without
///      breaking the canonical seed transfer to the pool.
contract ConditionallyRevertingWETH {
    string public constant name = "crWETH";
    string public constant symbol = "crWETH";
    uint8 public constant decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => bool) private _revertOnTransferTo;
    uint256 public totalSupply;

    function setRevertOnTransferTo(address target, bool shouldRevert) external {
        _revertOnTransferTo[target] = shouldRevert;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        totalSupply += amount;
    }

    function deposit() external payable {
        _balances[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function balanceOf(address holder) external view returns (uint256) {
        return _balances[holder];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (_revertOnTransferTo[to]) revert("sweep-target rejects ETH");
        require(_balances[msg.sender] >= amount, "balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (_revertOnTransferTo[to]) revert("sweep-target rejects ETH");
        require(_balances[from] >= amount, "balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

// ------------------------------------------------------------
// Local mocks
// ------------------------------------------------------------

contract MockMineCoreGenesis {
    MockERC20 public immutable claim;

    uint256 public emissionStartTime;
    uint256 public GENESIS_ACCRUAL_DURATION = 10 days;
    bool public takeoversPaused;

    uint256 public immutable claimMintedAmount;

    address public collector;
    bool public collected;

    constructor(address claim_, uint256 emissionStartTime_, uint256 claimMintedAmount_) {
        claim = MockERC20(claim_);
        emissionStartTime = emissionStartTime_;
        claimMintedAmount = claimMintedAmount_;
        takeoversPaused = true;
    }

    function setCollector(address c) external {
        collector = c;
    }

    function setGenesisAccrualDuration(uint256 duration) external {
        GENESIS_ACCRUAL_DURATION = duration;
    }

    function setTakeoversPaused(bool paused) external {
        takeoversPaused = paused;
    }

    address public lastGuardianSet;

    function setGuardian(address g) external {
        lastGuardianSet = g;
    }

    function collectGenesisKingClaim(address to) external returns (uint256 claimMinted) {
        require(msg.sender == collector, "MockMineCoreGenesis: only collector");
        require(block.timestamp >= emissionStartTime + GENESIS_ACCRUAL_DURATION, "MockMineCoreGenesis: too early");
        require(!collected, "MockMineCoreGenesis: already collected");
        collected = true;

        claim.mint(to, claimMintedAmount);
        return claimMintedAmount;
    }
}

contract MockGenesisLPVault is IGenesisLPVault24M {
    address public immutable override pool;
    uint256 public startLockCalls;

    constructor(address pool_) {
        pool = pool_;
    }

    function startLock() external override {
        startLockCalls += 1;
    }

    function extendLock(uint256) external override {}
    function withdrawLp() external override {}
    function rescueEth() external override {}

    function MIN_LP_LOCK() external pure override returns (uint256) {
        return 1e15;
    }

    function MIN_EXTENSION_DURATION() external pure override returns (uint256) {
        return 1 days;
    }

    function unlockTime() external pure override returns (uint256) {
        return 0;
    }

    function lpLockedAmount() external pure override returns (uint256) {
        return 0;
    }

    function lockStartTime() external pure override returns (uint256) {
        return 0;
    }

    function lpWithdrawRecipient() external pure override returns (address) {
        return address(0);
    }

    function INITIAL_LOCK_DURATION() external pure override returns (uint256) {
        return 730 days;
    }

    function MAX_EXTENSION() external pure override returns (uint256) {
        return 365 days;
    }
}

    contract MockPoolFactory is IPoolFactory {
        address public pool;
        bool public created;

        function setPool(address p) external {
            pool = p;
        }

        function getPool(address, address, bool) external view returns (address) {
            return created ? pool : address(0);
        }

        function createPool(address, address, bool) external returns (address) {
            created = true;
            return pool;
        }
    }

    contract MockGenesisPool is MockERC20, IAerodromePoolMint {
        uint256 public constant NEXT_LP_MINT = 123e18;

        constructor() MockERC20("MockGenesisLP", "MGLP") {}

        function mint(address to) external returns (uint256 liquidity) {
            liquidity = NEXT_LP_MINT;
            _mint(to, liquidity);
        }
    }

    /// @dev MockGenesisPool variant that implements skim() for testing the successful skim path.
    contract SkimmableMockGenesisPool is MockERC20, IAerodromePoolMint, IAerodromePoolSkim {
        uint256 public constant NEXT_LP_MINT = 123e18;

        address public immutable weth;
        address public immutable claimToken;

        constructor(address weth_, address claim_) MockERC20("SkimLP", "SKLP") {
            weth = weth_;
            claimToken = claim_;
        }

        function mint(address to) external returns (uint256 liquidity) {
            liquidity = NEXT_LP_MINT;
            _mint(to, liquidity);
        }

        function skim(address to) external {
            uint256 balW = IERC20(weth).balanceOf(address(this));
            uint256 balC = IERC20(claimToken).balanceOf(address(this));
            if (balW != 0) IERC20(weth).transfer(to, balW);
            if (balC != 0) IERC20(claimToken).transfer(to, balC);
        }
    }
