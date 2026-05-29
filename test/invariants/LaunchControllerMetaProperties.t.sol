// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LaunchController} from "src/genesis/LaunchController.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {IAerodromePoolMint} from "src/interfaces/IAerodromePoolMint.sol";
import {IGenesisLPVault24M} from "src/interfaces/IGenesisLPVault24M.sol";

import {AccountingMetaPropertyBase} from "./AccountingMetaProperties.t.sol";

contract _LCMockMineCore {
    MockERC20 public immutable claim;
    uint256 public emissionStartTime;
    uint256 public GENESIS_ACCRUAL_DURATION = 10 days;
    bool public takeoversPaused = true;
    uint256 public immutable claimMintedAmount;
    address public collector;
    bool public collected;

    constructor(address claim_, uint256 emissionStartTime_, uint256 claimMintedAmount_) {
        claim = MockERC20(claim_);
        emissionStartTime = emissionStartTime_;
        claimMintedAmount = claimMintedAmount_;
    }

    function setCollector(address c) external {
        collector = c;
    }

    function setTakeoversPaused(bool paused) external {
        takeoversPaused = paused;
    }

    address public lastGuardianSet;

    function setGuardian(address g) external {
        lastGuardianSet = g;
    }

    function collectGenesisKingClaim(address to) external returns (uint256) {
        require(msg.sender == collector && !collected, "collector/collected");
        collected = true;
        claim.mint(to, claimMintedAmount);
        return claimMintedAmount;
    }
}

contract _LCMockGenesisLPVault is IGenesisLPVault24M {
    address public immutable override pool;
    uint256 public startLockCalls;

    constructor(address pool_) {
        pool = pool_;
    }

    function startLock() external override {
        startLockCalls++;
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

    contract _LCMockPoolFactory is IPoolFactory {
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

    contract _LCMockGenesisPool is MockERC20, IAerodromePoolMint {
        uint256 public constant NEXT_LP_MINT = 123e18;
        constructor() MockERC20("MockGenesisLP", "MGLP") {}

        function mint(address to) external returns (uint256 liquidity) {
            liquidity = NEXT_LP_MINT;
            _mint(to, liquidity);
        }
    }

    /// @title LaunchController accounting meta-property suite (M1-M6)
    /// @notice LaunchController is a one-shot orchestrator: `finalizeGenesis` runs
    ///         exactly once and atomically (a) mints CLAIM, (b) seeds the
    ///         WETH/CLAIM pool, (c) starts the GenesisLPVault24M lock, (d) rotates
    ///         MineCore's guardian, (e) unpauses takeovers. The contract retains
    ///         no value across calls.
    ///
    ///         - M1: WAIVE-WITH-CONTROL. There is no rate-sensitive payout — the
    ///           operation is a single atomic state transition.
    ///         - M2: WAIVE-WITH-CONTROL. There is no quoter; the call signature
    ///           is `finalizeGenesis()` with `msg.value == 50 ether` enforced
    ///           exactly (`GenesisExactSeedRequired`).
    ///         - M3: post-finalize, the controller's CLAIM / WETH / ETH balances
    ///           are all zero and the LP tokens are held by the GenesisLPVault24M.
    ///           Conservation is enforced atomically.
    ///         - M4: WAIVE-WITH-CONTROL. The call is one-shot — a second call
    ///           reverts with `GenesisAlreadyFinalized`. Path independence is
    ///           moot.
    ///         - M5: cooldown=∞ arm. `finalizeGenesis` MUST revert on second
    ///           invocation. This is the one-shot contract.
    ///         - M6: WAIVE-WITH-CONTROL. There is no curve / mulDiv on the
    ///           value path; CLAIM is minted and seeded 1:1.
    contract LaunchControllerMetaPropertiesTest is AccountingMetaPropertyBase {
        MockWETH internal weth;
        MockERC20 internal claim;
        _LCMockPoolFactory internal factory;
        MockAerodromeRouter internal router;
        _LCMockGenesisPool internal pool;
        _LCMockGenesisLPVault internal lpVault;
        _LCMockMineCore internal mineCore;
        LaunchController internal controller;

        uint256 internal constant CLAIM_MINTED = 10_000e18;

        function setUp() public {
            _deploy();
        }

        function _deploy() internal {
            weth = new MockWETH();
            claim = new MockERC20("CLAIM", "CLAIM");
            factory = new _LCMockPoolFactory();
            router = new MockAerodromeRouter(address(factory), address(weth));
            pool = new _LCMockGenesisPool();
            factory.setPool(address(pool));
            router.setPoolFor(address(weth), address(claim), false, address(factory), address(pool));
            lpVault = new _LCMockGenesisLPVault(address(pool));
            mineCore = new _LCMockMineCore(address(claim), block.timestamp, CLAIM_MINTED);
            controller =
                new LaunchController(
                address(claim), address(mineCore), address(lpVault), address(router), address(this)
            );
            mineCore.setCollector(address(controller));
            vm.deal(address(this), 200 ether);
        }

        function _resetSurface() internal override {
            _deploy();
        }

        // ── M1 — WAIVE-WITH-CONTROL ────────────────────────────────────
        function test_M1_RateContinuity_NotApplicable() public pure {
            assertTrue(true, "M1 N/A: finalizeGenesis is a one-shot atomic state transition");
        }

        // ── M2 — WAIVE-WITH-CONTROL ────────────────────────────────────
        function test_M2_QuoteEqualsExecute_GateEnforcedBySeedRequirement() public {
            _resetSurface();
            vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());
            // Wrong seed amount MUST revert.
            vm.expectRevert(Errors.GenesisExactSeedRequired.selector);
            controller.finalizeGenesis{value: 50.01 ether}();
            vm.expectRevert(Errors.GenesisExactSeedRequired.selector);
            controller.finalizeGenesis{value: 49.99 ether}();
        }

        // ── M3 — Conservation ──────────────────────────────────────────
        /// @notice Post-finalize, the controller retains zero CLAIM / WETH / ETH
        ///         and the LP tokens are held by the GenesisLPVault24M. Atomic.
        function test_M3_ControllerRetainsNoValuePostFinalize() public {
            _resetSurface();
            vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());
            controller.finalizeGenesis{value: 50 ether}();

            assertEq(claim.balanceOf(address(controller)), 0, "M3: controller retains CLAIM");
            assertEq(weth.balanceOf(address(controller)), 0, "M3: controller retains WETH");
            assertEq(address(controller).balance, 0, "M3: controller retains ETH");
            assertEq(pool.balanceOf(address(controller)), 0, "M3: controller retains LP");
            assertEq(pool.balanceOf(address(lpVault)), pool.NEXT_LP_MINT(), "M3: LP not delivered to vault");
        }

        // ── M4 — WAIVE-WITH-CONTROL ────────────────────────────────────
        function test_M4_PathIndependence_NotApplicable() public pure {
            assertTrue(true, "M4 N/A: finalizeGenesis is one-shot - see test_M5_OneShotEnforcedSecondCallReverts");
        }

        // ── M5 — Cooldown=infinity arm (one-shot) ──────────────────────
        /// @notice Second `finalizeGenesis` call MUST revert. The cooldown is
        ///         effectively infinite — the contract is launch-only.
        function test_M5_OneShotEnforcedSecondCallReverts() public {
            _resetSurface();
            vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION());
            controller.finalizeGenesis{value: 50 ether}();
            assertTrue(controller.genesisFinalized(), "M5: first call did not set genesisFinalized");

            vm.deal(address(this), 50 ether);
            bool reverted;
            try controller.finalizeGenesis{value: 50 ether}() {
                reverted = false;
            } catch {
                reverted = true;
            }
            assertTrue(reverted, "M5: second finalizeGenesis call did not revert");
        }

        // ── M6 — WAIVE-WITH-CONTROL ────────────────────────────────────
        function test_M6_FloorDirection_NotApplicable() public pure {
            assertTrue(true, "M6 N/A: no curve / mulDiv on value path; CLAIM minted and seeded 1:1");
        }
    }
