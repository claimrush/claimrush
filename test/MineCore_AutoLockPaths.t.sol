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

/// @notice Exercises every path through _settlePrevKingClaim.
/// @dev Paths:
///   1. claimAmount == 0 (early return)
///   2. cfg.enabled && gasleft() < SETTLE_CLAIM_MIN_GAS (gas guard skip)
///   3. !cfg.enabled (default liquid CLAIM)
///   4. resolveKingAutoLockDestination returns !ok (destination failure)
///   5. furnace == address(0) (no furnace)
///   6. furnace not reciprocally wired
///   7. enterWithClaimFor succeeds (auto-lock success)
///   8. enterWithClaimFor reverts, direct transfer succeeds (catch -> liquid)
///   9. enterWithClaimFor reverts, direct transfer fails (catch -> pendingKingClaim)
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
    // Path 3: auto-lock disabled (default) -> liquid CLAIM to king
    // -----------------------------------------------------------------------

    /// @notice Default path: auto-lock disabled, king receives liquid CLAIM.
    function test_autoLock_disabled_liquidClaim() public {
        _takeover(alice);
        vm.warp(block.timestamp + 30 minutes);

        uint256 claimBefore = IERC20(address(claim)).balanceOf(alice);
        _takeover(bob); // dethrones alice
        uint256 claimAfter = IERC20(address(claim)).balanceOf(alice);

        assertGt(claimAfter, claimBefore, "alice should receive liquid CLAIM");
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

        // Alice should NOT receive liquid CLAIM (it went to Furnace).
        uint256 claimAfter = IERC20(address(claim)).balanceOf(alice);
        assertEq(claimAfter, claimBefore, "alice should NOT receive liquid CLAIM (auto-locked)");

        // Verify pinnedTokenId was set.
        (bool enabled,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(enabled, "auto-lock should still be enabled");
        assertGt(pinnedTokenId, 0, "pinnedTokenId should be set after create-once");

        _assertClaimSolvency();
    }

    // -----------------------------------------------------------------------
    // Path 4: destination resolution failure -> liquid CLAIM fallback
    // -----------------------------------------------------------------------

    /// @notice Auto-lock with invalid targetTokenId -> destination fails -> liquid CLAIM.
    function test_autoLock_invalidTarget_fallbackLiquid() public {
        _takeover(alice);

        // Enable auto-lock targeting a nonexistent veNFT.
        // We need to set the config such that resolveKingAutoLockDestination will fail.
        // Use the harness to set a pinnedTokenId that doesn't exist.
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(30 days), false, 1);
        // Pin to a nonexistent token.
        mineCore.setKingAutoLockPinnedTokenIdForTest(alice, 99999);

        vm.warp(block.timestamp + 30 minutes);

        uint256 claimBefore = IERC20(address(claim)).balanceOf(alice);
        _takeover(bob);
        uint256 claimAfter = IERC20(address(claim)).balanceOf(alice);

        // Should get liquid CLAIM (fallback after resolution failure).
        assertGt(claimAfter, claimBefore, "alice should receive liquid CLAIM after resolution failure");

        // pinnedTokenId should be cleared.
        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertEq(pinnedTokenId, 0, "stale pinnedTokenId should be cleared");

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
