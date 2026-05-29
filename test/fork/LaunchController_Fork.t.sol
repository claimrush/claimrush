// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LaunchController} from "src/genesis/LaunchController.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {IAerodromePoolMint} from "src/interfaces/IAerodromePoolMint.sol";
import {IAerodromePoolSkim} from "src/interfaces/IAerodromePoolSkim.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

import {AerodromeForkBase, ForkClaimToken} from "./AerodromeForkBase.t.sol";

/// @dev Mock MineCore for genesis fork tests. Fulfills LaunchController's constructor
///      and finalizeGenesis wiring requirements.
contract MockMineCoreFork {
    address public immutable claim;
    uint256 public emissionStartTime;
    uint256 public constant GENESIS_ACCRUAL_DURATION = 10 days;
    bool public takeoversPaused = true;
    address public guardian;

    ForkClaimToken internal _claimToken;
    uint256 public genesisClaimToMint;

    constructor(address _claim, uint256 _emissionStartTime, uint256 _claimToMint) {
        claim = _claim;
        emissionStartTime = _emissionStartTime;
        _claimToken = ForkClaimToken(_claim);
        genesisClaimToMint = _claimToMint;
    }

    function collectGenesisKingClaim(address to) external returns (uint256) {
        _claimToken.mint(to, genesisClaimToMint);
        return genesisClaimToMint;
    }

    function setTakeoversPaused(bool paused) external {
        takeoversPaused = paused;
    }

    function setGuardian(address _guardian) external {
        guardian = _guardian;
    }
}

/// @dev Mock GenesisLPVault24M for fork tests.
contract MockGenesisLPVaultFork {
    address public immutable pool;
    uint256 public startLockCalls;

    constructor(address _pool) {
        pool = _pool;
    }

    function startLock() external {
        startLockCalls++;
    }
}

contract LaunchControllerForkTest is AerodromeForkBase {
    using SafeERC20 for IERC20;
    uint256 internal constant GENESIS_CLAIM_MINTED = 500_000e18;

    MockMineCoreFork internal mockMineCore;
    MockGenesisLPVaultFork internal mockLpVault;
    LaunchController internal controller;
    address internal guardian;

    function setUp() public override {
        super.setUp();

        guardian = deployer;

        vm.startPrank(deployer);

        // MineCore: emission started 11 days ago so accrual window is complete
        uint256 emissionStart = block.timestamp - 11 days;
        mockMineCore = new MockMineCoreFork(address(claimToken), emissionStart, GENESIS_CLAIM_MINTED);

        // GenesisLPVault: points at the expected pool
        mockLpVault = new MockGenesisLPVaultFork(pool);

        // LaunchController: uses DexAdapter as the router
        controller = new LaunchController(
            address(claimToken), address(mockMineCore), address(mockLpVault), address(dexAdapter), guardian
        );

        vm.stopPrank();
    }

    // --- Pool creation via real factory ---

    function test_createPool_deterministicAddress() public view {
        address fromFactory = IPoolFactory(AERODROME_FACTORY).getPool(WETH, address(claimToken), false);
        assertEq(fromFactory, pool, "pool from factory matches");
        assertEq(controller.expectedPool(), pool, "controller expectedPool matches");
    }

    // --- Real mint LP math ---

    function test_mint_realGeometricMean() public {
        uint256 wethAmount = 50 ether;
        uint256 claimAmount = GENESIS_CLAIM_MINTED;

        _dealWeth(address(this), wethAmount);
        _dealClaim(address(this), claimAmount);

        IERC20(WETH).safeTransfer(pool, wethAmount);
        IERC20(address(claimToken)).safeTransfer(pool, claimAmount);

        uint256 lpMinted = IAerodromePoolMint(pool).mint(address(this));

        // Aerodrome volatile pool: initial LP = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
        uint256 expectedApprox = Math.sqrt(wethAmount * claimAmount);
        assertGt(lpMinted, 0, "LP minted > 0");
        // Allow MINIMUM_LIQUIDITY (1000 wei) to be deducted
        assertApproxEqRel(lpMinted, expectedApprox, 0.01e18, "LP ~ sqrt(weth * claim)");
    }

    // --- Real skim semantics ---

    function test_skim_removesOnlyExcess() public {
        // Seed the pool first so reserves are tracked
        _seedPool(50 ether, 100_000e18);

        // Donate extra tokens
        uint256 donateWeth = 1 ether;
        uint256 donateClaim = 10_000e18;
        _dealWeth(pool, donateWeth);
        _dealClaim(pool, donateClaim);

        uint256 wethBefore = IERC20(WETH).balanceOf(pool);
        uint256 claimBefore = claimToken.balanceOf(pool);

        IAerodromePoolSkim(pool).skim(bob);

        uint256 wethAfter = IERC20(WETH).balanceOf(pool);
        uint256 claimAfter = claimToken.balanceOf(pool);

        // Only the donated excess is removed, not the reserves
        assertApproxEqAbs(wethBefore - wethAfter, donateWeth, 1, "only donated WETH skimmed");
        assertApproxEqAbs(claimBefore - claimAfter, donateClaim, 1, "only donated CLAIM skimmed");
    }

    // --- Full finalizeGenesis flow ---

    function test_finalizeGenesis_fullFlow() public {
        // Required seed ETH: 50 ether * GENESIS_ACCRUAL_DURATION / 10 days = 50 ether
        uint256 requiredSeedEth = 50 ether;
        vm.deal(guardian, requiredSeedEth);

        // Verify pre-conditions
        assertFalse(controller.genesisFinalized(), "not yet finalized");
        assertTrue(mockMineCore.takeoversPaused(), "takeovers paused pre-genesis");

        uint256 lpVaultLpBefore = IERC20(pool).balanceOf(address(mockLpVault));

        vm.prank(guardian);
        controller.finalizeGenesis{value: requiredSeedEth}();

        // Post-conditions
        assertTrue(controller.genesisFinalized(), "finalized");
        assertFalse(mockMineCore.takeoversPaused(), "takeovers unpaused");
        assertEq(mockLpVault.startLockCalls(), 1, "startLock called once");
        assertEq(controller.genesisClaimMinted(), GENESIS_CLAIM_MINTED, "claim minted recorded");

        // LP tokens went to the genesis vault
        uint256 lpVaultLpAfter = IERC20(pool).balanceOf(address(mockLpVault));
        uint256 lpMinted = lpVaultLpAfter - lpVaultLpBefore;
        assertGt(lpMinted, 0, "LP minted to vault");
        assertEq(controller.genesisLpMinted(), lpMinted, "recorded LP matches actual");

        // LP amount should be roughly sqrt(seedEth * genesisClaimMinted)
        uint256 expectedApprox = Math.sqrt(requiredSeedEth * GENESIS_CLAIM_MINTED);
        assertApproxEqRel(lpMinted, expectedApprox, 0.01e18, "LP ~ sqrt(ETH * CLAIM)");

        // Guardian was rotated on MineCore
        assertEq(mockMineCore.guardian(), guardian, "guardian rotated");

        // Controller should be empty
        assertEq(IERC20(WETH).balanceOf(address(controller)), 0, "controller WETH = 0");
        assertEq(claimToken.balanceOf(address(controller)), 0, "controller CLAIM = 0");
    }

    function test_finalizeGenesis_cannotRunTwice() public {
        vm.deal(guardian, 50 ether);
        vm.prank(guardian);
        controller.finalizeGenesis{value: 50 ether}();

        vm.deal(guardian, 50 ether);
        vm.prank(guardian);
        vm.expectRevert();
        controller.finalizeGenesis{value: 50 ether}();
    }

    function test_finalizeGenesis_skimsDonationsBeforeSeeding() public {
        // Donate tokens to pool address before genesis
        _dealWeth(pool, 0.1 ether);
        _dealClaim(pool, 1000e18);

        uint256 requiredSeedEth = 50 ether;
        vm.deal(guardian, requiredSeedEth);

        // Genesis should succeed — it skims donations first
        vm.prank(guardian);
        controller.finalizeGenesis{value: requiredSeedEth}();

        assertTrue(controller.genesisFinalized(), "finalized despite donations");
    }
}
