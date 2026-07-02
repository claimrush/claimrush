// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockKingAutoLockFurnace} from "./mocks/MockKingAutoLockFurnace.sol";

/// @dev Furnace mock that always reverts on enterWithClaimFor.
contract RevertingFurnace {
    address public claim;
    address public ve;
    address public mineCore;
    address public shareholderRoyalties;

    constructor(address claim_, address ve_, address mineCore_, address royalties_) {
        claim = claim_;
        ve = ve_;
        mineCore = mineCore_;
        shareholderRoyalties = royalties_;
    }

    function enterWithClaimFor(address, uint256, uint256, uint256, bool, uint256) external pure returns (uint256) {
        revert("FURNACE_REVERTS");
    }

    function creditReserve(uint256) external {}

    // Satisfy wiring checks.
    function delegationHub() external pure returns (address) {
        return address(0);
    }

    function entryTokenRegistry() external pure returns (address) {
        return address(0);
    }
}

/// @dev ERC20-like that rejects transfers (simulates a token that reverts transfer).
contract RejectingClaimReceiver {
    receive() external payable {}
}

/// @notice Exercises the paths through _settlePrevKingClaim (King-stream CLAIM is always locked).
/// @dev Paths:
///   1. claimAmount == 0 (early return)
///   2. gasleft() < SETTLE_CLAIM_MIN_GAS (gas guard -> pending credit, force-locked on withdrawal)
///   3. default (no selection) -> create-once autoMax lock
///   4. invalid selected/pinned target -> fresh autoMax lock fallback
///   5. furnace == address(0) or not reciprocally wired -> pending credit
///   6. enterWithClaimFor succeeds (lock created/topped up)
///   7. enterWithClaimFor reverts -> pending credit (no liquid)
contract MineCoreAutoLockPathsTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    address internal mineMarket = address(0xBABA);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        vm.etch(mineMarket, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        EntryTokenRegistry registry = new EntryTokenRegistry(owner);
        MockWETH weth = new MockWETH();
        vm.etch(address(0xFAc7), hex"00");
        MockAerodromeRouter router = new MockAerodromeRouter(address(0xFAc7), address(weth));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineMarket(mineMarket);
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(address(registry));
        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        EntryTokenRegistry mineCoreRegistry = new EntryTokenRegistry(owner);
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        registry.setRouterConfig(address(router), router.defaultFactory(), router.weth(), address(claim));
        vm.stopPrank();

        // Seed furnace reserve.
        uint256 seed = 1_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), seed);
        vm.prank(address(mineCore));
        furnace.creditReserve(seed);
    }

    function _takeover(address user) internal {
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(user, price);
        vm.prank(user);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function _assertClaimSolvency() internal view {
        uint256 tracked = mineCore.totalPendingKingClaim();
        uint256 balance = IERC20(address(claim)).balanceOf(address(mineCore));
        assertLe(tracked, balance, "CLAIM solvency violated");
    }

    // -----------------------------------------------------------------------
    // Default (no config) -> forced create-once autoMax lock
    // -----------------------------------------------------------------------

    /// @notice Default path: with no config, the dethroned king's CLAIM is force-locked into a fresh
    ///         create-once autoMax veNFT. There is no liquid payout.
    function test_autoLock_default_forcesLock() public {
        _takeover(alice);
        vm.warp(block.timestamp + 30 minutes);

        uint256 claimBefore = IERC20(address(claim)).balanceOf(alice);
        _takeover(bob); // dethrones alice
        uint256 claimAfter = IERC20(address(claim)).balanceOf(alice);

        // alice took 1 of the last-100 takeovers -> 1% liquid slice, the remaining 99% is force-locked.
        uint256 mined = mineCore.getReignInfo(1).totalClaimMined;
        uint256 expLiquid = (mined * mineCore.kingLiquidShareBps(alice)) / 10_000;
        assertGt(expLiquid, 0, "single-takeover liquid slice is positive");
        assertEq(claimAfter - claimBefore, expLiquid, "alice receives only her takeover-window liquid share");

        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertGt(pinnedTokenId, 0, "a create-once lock should be pinned by default");
        assertEq(ve.ownerOf(pinnedTokenId), alice, "alice owns the pinned lock");

        (,, bool autoMax,) = ve.getLockInfo(pinnedTokenId);
        assertTrue(autoMax, "default lock should be autoMax");

        _assertClaimSolvency();
    }

    // -----------------------------------------------------------------------
    // Path 7: auto-lock enabled, enterWithClaimFor succeeds
    // -----------------------------------------------------------------------

    /// @notice Auto-lock success path: CLAIM routed through Furnace into veNFT.
    function test_autoLock_enabled_success() public {
        _takeover(alice);

        // Enable auto-lock for alice: create-once, 30 days, no autoMax.
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(30 days), false, 1);

        vm.warp(block.timestamp + 30 minutes);

        uint256 claimBefore = IERC20(address(claim)).balanceOf(alice);
        vm.recordLogs();
        _takeover(bob); // dethrones alice, triggers auto-lock

        // Alice receives only her 1% takeover-window liquid slice; the locked remainder goes to Furnace.
        uint256 claimAfter = IERC20(address(claim)).balanceOf(alice);
        uint256 mined = mineCore.getReignInfo(1).totalClaimMined;
        uint256 expLiquid = (mined * mineCore.kingLiquidShareBps(alice)) / 10_000;
        assertEq(claimAfter - claimBefore, expLiquid, "alice receives only her takeover-window liquid share");

        // Verify pinnedTokenId was set.
        (bool enabled,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(enabled, "auto-lock should still be enabled");
        assertGt(pinnedTokenId, 0, "pinnedTokenId should be set after create-once");

        _assertClaimSolvency();
    }

    // -----------------------------------------------------------------------
    // Destination resolution failure -> fresh autoMax lock fallback (never liquid)
    // -----------------------------------------------------------------------

    /// @notice Auto-lock with an invalid pinned target -> resolution fails -> a fresh autoMax lock is
    ///         created instead. King-stream CLAIM is never paid out liquid.
    function test_autoLock_invalidTarget_fallbackFreshLock() public {
        _takeover(alice);

        // Enable auto-lock, then pin to a nonexistent token so resolveKingAutoLockDestination fails.
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(30 days), false, 1);
        mineCore.setKingAutoLockPinnedTokenIdForTest(alice, 99999);

        vm.warp(block.timestamp + 30 minutes);

        uint256 claimBefore = IERC20(address(claim)).balanceOf(alice);
        _takeover(bob);
        uint256 claimAfter = IERC20(address(claim)).balanceOf(alice);

        // Only the 1% liquid slice is paid; the locked remainder replaces the stale pin with a fresh autoMax lock.
        uint256 mined = mineCore.getReignInfo(1).totalClaimMined;
        uint256 expLiquid = (mined * mineCore.kingLiquidShareBps(alice)) / 10_000;
        assertEq(claimAfter - claimBefore, expLiquid, "alice receives only her takeover-window liquid share");

        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertGt(pinnedTokenId, 0, "a fresh pin should replace the stale one");
        assertTrue(pinnedTokenId != 99999, "stale pin must not be reused");
        assertEq(ve.ownerOf(pinnedTokenId), alice, "alice owns the fresh lock");

        (,, bool autoMax,) = ve.getLockInfo(pinnedTokenId);
        assertTrue(autoMax, "fallback lock should be autoMax");

        _assertClaimSolvency();
    }

    // -----------------------------------------------------------------------
    // Solvency across all paths
    // -----------------------------------------------------------------------

    /// @notice Fuzz: rapid takeovers with mixed auto-lock configs maintain CLAIM solvency.
    function testFuzz_autoLock_mixedConfigs_claimSolvency(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];

        for (uint256 i = 0; i < 8; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            address user = users[uint256(h) % 3];

            // Random auto-lock config toggle.
            if (uint8(uint256(h >> 8)) % 3 == 0) {
                vm.prank(user);
                (bool ok,) = address(mineCore)
                    .call(
                        abi.encodeWithSignature(
                            "setKingAutoLockConfig(bool,uint256,uint32,bool,uint256)",
                            true,
                            0,
                            uint32(30 days),
                            false,
                            1
                        )
                    );
                ok;
            } else if (uint8(uint256(h >> 8)) % 3 == 1) {
                vm.prank(user);
                (bool ok,) = address(mineCore)
                    .call(
                        abi.encodeWithSignature(
                            "setKingAutoLockConfig(bool,uint256,uint32,bool,uint256)", false, 0, 0, false, 0
                        )
                    );
                ok;
            }

            // Advance time.
            uint256 dt = (uint256(uint16(uint256(h >> 16))) % 2 hours) + 1;
            vm.warp(block.timestamp + dt);

            // Takeover.
            address current = mineCore.currentKing();
            if (current != address(0) && user == current) continue;

            uint256 price = mineCore.getCurrentTakeoverPrice();
            vm.deal(user, price);
            vm.prank(user);
            mineCore.takeover{value: price}(type(uint256).max);

            _assertClaimSolvency();
        }
    }
}
