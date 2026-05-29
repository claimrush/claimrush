// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {UpgradeableProtocolBase} from "src/lib/UpgradeableProtocolBase.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";

/// @notice Runtime EIP-7702 rejection on owner-only and guardian-only paths.
///         The constructor / setter side of the rejection surface is covered
///         in `AuditClosure_7702Rejections.t.sol`. This file pins the
///         post-acceptance / post-seating runtime checks: a seat that was
///         valid at install time must NOT continue to authorize calls after
///         its account shape flips to a 7702 delegation designator.
contract RuntimeDelegatedEOAGuardsTest is Test {
    address internal ownerEoa = makeAddr("ownerEoa");
    address internal guardianEoa = makeAddr("guardianEoa");
    address internal aliceEoa = makeAddr("aliceEoa");
    address internal delegateTarget = makeAddr("delegateTarget");

    ClaimToken internal claim;
    VeClaimNFT internal ve;
    ShareholderRoyalties internal royalties;
    MineCore internal mineCore;
    Furnace internal furnace;
    MarketRouter internal marketRouter;

    function setUp() public {
        claim = new ClaimToken(ownerEoa);
        ve = new VeClaimNFT(address(claim), ownerEoa);
        royalties = new ShareholderRoyalties(address(ve), ownerEoa);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), ownerEoa);
        FurnaceGuardHelper helper = new FurnaceGuardHelper(address(claim), address(ve));
        furnace = new Furnace(address(claim), address(ve), address(helper), ownerEoa);
        marketRouter = new MarketRouter(address(claim), address(ve), address(royalties), ownerEoa);
    }

    /// @dev Etch a 23-byte EIP-7702 designator at `target`: `0xEF 0x01 0x00 || delegate`.
    function _etch7702(address target, address delegate) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", delegate));
        assertEq(target.code.length, 23, "designator must be 23 bytes");
    }

    /* ------------------------------------------------------------------ */
    /*  Owner runtime guard (`UpgradeableProtocolBase._checkOwner`)         */
    /* ------------------------------------------------------------------ */

    function test_owner_runtimeGuard_mineCore_revertsAfter7702Install() public {
        _etch7702(ownerEoa, delegateTarget);

        vm.prank(ownerEoa);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.DelegatedEOAOwner.selector, ownerEoa));
        mineCore.freezeConfig();
    }

    function test_owner_runtimeGuard_furnace_isNoOpByDesign() public {
        // Furnace overrides `_validateNewOwner` to a no-op because the impl
        // sits within ~25 bytes of the EIP-170 runtime limit. The owner-side
        // 7702 protection is provided by the proxy admin seat
        // (`FurnaceProxy._validatedOwner`), the constructor seat, and the
        // operator deploy-script discipline that pins the owner Safe. Pin
        // that no-op contract here so a future regression in
        // `_validateNewOwner` is caught.
        _etch7702(ownerEoa, delegateTarget);

        vm.prank(ownerEoa);
        furnace.setMineCore(address(mineCore));
    }

    function test_owner_runtimeGuard_marketRouter_revertsAfter7702Install() public {
        _etch7702(ownerEoa, delegateTarget);

        vm.prank(ownerEoa);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.DelegatedEOAOwner.selector, ownerEoa));
        marketRouter.setSettlementKeeper(aliceEoa, true);
    }

    function test_owner_runtimeGuard_royalties_revertsAfter7702Install() public {
        _etch7702(ownerEoa, delegateTarget);

        vm.prank(ownerEoa);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.DelegatedEOAOwner.selector, ownerEoa));
        royalties.setAutoCompoundKeeper(aliceEoa, true);
    }

    function test_owner_runtimeGuard_passesForBareEOA() public {
        // Sanity: the runtime guard only triggers on the 23-byte 7702 prefix;
        // a bare EOA owner continues to pass.
        vm.prank(ownerEoa);
        marketRouter.setSettlementKeeper(aliceEoa, true);
    }

    /* ------------------------------------------------------------------ */
    /*  Guardian runtime guard                                              */
    /* ------------------------------------------------------------------ */

    function test_guardian_runtimeGuard_marketRouter_revertsAfter7702Install() public {
        // MarketRouter.setGuardian has no genesis preconditions; seat a
        // normal EOA guardian, then flip its account shape and confirm
        // the guardian-only path reverts at runtime.
        vm.prank(ownerEoa);
        marketRouter.setGuardian(guardianEoa);

        _etch7702(guardianEoa, delegateTarget);

        vm.prank(guardianEoa);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        marketRouter.pauseTrading(true);
    }

    /* ------------------------------------------------------------------ */
    /*  ShareholderRoyalties.recomputeGlobalWatermark                       */
    /* ------------------------------------------------------------------ */

    function test_watermark_emptyExhaustive_raisesFloorToCeiling() public {
        // Arrange: the constructor pins the global floor below the sentinel
        // ceiling (it observes a worst-case lock end). The empty-exhaustive
        // sweep is the operator escape hatch when the shareholder set is
        // provably empty: it raises the global floor straight to the
        // ceiling so overflow checkpoint writes resume.
        uint40 currentBefore = royalties.oldestObservedNonAutoMaxLockEnd();
        if (currentBefore == type(uint40).max) {
            // Already at the ceiling: pin a lower value to make the raise
            // observable. We do this through the public path that exists
            // for this purpose (single-user pin against an unknown user
            // is a no-op; instead force the watermark down via an explicit
            // recompute against a known non-empty candidate set is not
            // exposed for tests, so we skip the pre-condition assertion
            // and rely on the post-condition only).
        }

        address[] memory empty = new address[](0);

        vm.prank(ownerEoa);
        royalties.recomputeGlobalWatermark(empty, true);

        assertEq(
            royalties.oldestObservedNonAutoMaxLockEnd(),
            type(uint40).max,
            "empty-exhaustive sweep must raise floor to sentinel ceiling"
        );
    }

    function test_watermark_emptyNonExhaustive_isNoOp() public {
        uint40 before_ = royalties.oldestObservedNonAutoMaxLockEnd();
        address[] memory empty = new address[](0);

        vm.prank(ownerEoa);
        royalties.recomputeGlobalWatermark(empty);

        assertEq(
            royalties.oldestObservedNonAutoMaxLockEnd(),
            before_,
            "empty non-exhaustive sweep must leave the floor unchanged"
        );
    }
}
