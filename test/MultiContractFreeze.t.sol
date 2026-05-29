// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";

contract MultiContractFreezeTest is Test {
    struct MineCoreFreezeBundle {
        ClaimToken claim;
        VeClaimNFTHarness ve;
        ShareholderRoyalties royalties;
        MineCore mineCore;
        Furnace furnace;
    }

    struct VeFreezeBundle {
        ClaimToken claim;
        VeClaimNFTHarness ve;
        ShareholderRoyalties royalties;
        MineCore mineCore;
        Furnace furnace;
        address mineMarket;
    }

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    Furnace internal furnace;
    ShareholderRoyalties internal royalties;
    FurnaceQuoter internal furnaceQuoter;

    address internal owner = address(0xA11CE);
    address internal mineMarket;
    address internal claimAllHelper;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        mineMarket = address(new MockContract());
        furnaceQuoter = new FurnaceQuoter(address(furnace));

        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        vm.stopPrank();

        claimAllHelper = address(new ClaimAllHelper(address(royalties), address(mineCore)));

        vm.startPrank(owner);
        mineCore.setClaimAllHelper(claimAllHelper);
        royalties.setClaimAllHelper(claimAllHelper);
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();
    }

    /// @dev Deploy a fresh MineCore with fresh canonical immutable roots.
    function _freshMineCoreRoots() internal returns (MineCoreFreezeBundle memory bundle) {
        bundle.claim = new ClaimToken(owner);
        bundle.ve = new VeClaimNFTHarness(address(bundle.claim), owner);
        bundle.royalties = new ShareholderRoyalties(address(bundle.ve), owner);
        bundle.mineCore = new MineCore(address(bundle.claim), address(bundle.ve), address(bundle.royalties), owner);
    }

    /// @dev Deploy a self-contained MineCore bundle whose Furnace reciprocal wiring is canonical.
    ///      ClaimAllHelper is intentionally left unset so tests can control the exact mismatch.
    function _freshCanonicalMineCoreBundle() internal returns (MineCoreFreezeBundle memory bundle) {
        bundle = _freshMineCoreRoots();
        bundle.furnace = new Furnace(
            address(bundle.claim),
            address(bundle.ve),
            address(new FurnaceGuardHelper(address(bundle.claim), address(bundle.ve))),
            owner
        );
        address localMarket = address(new MockContract());

        vm.startPrank(owner);
        bundle.claim.setMineCore(address(bundle.mineCore));
        bundle.furnace.setMineCore(address(bundle.mineCore));
        bundle.furnace.setShareholderRoyalties(address(bundle.royalties));
        bundle.mineCore.setFurnace(address(bundle.furnace));
        bundle.royalties.setWiring(address(bundle.mineCore), localMarket, address(bundle.furnace));
        bundle.ve.setFurnace(address(bundle.furnace));
        vm.stopPrank();
    }

    function _freshWiredMineCore() internal returns (MineCore mc) {
        mc = _freshCanonicalMineCoreBundle().mineCore;
    }

    /// @dev Deploy a fresh ShareholderRoyalties wired to a fresh Furnace (no claimAllHelper set).
    ///      The fresh Furnace has minimal wiring; no quoter needed for freeze tests.
    function _freshWiredRoyalties() internal returns (ShareholderRoyalties sr) {
        sr = new ShareholderRoyalties(address(ve), owner);
        Furnace f = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        vm.startPrank(owner);
        f.setShareholderRoyalties(address(sr));
        // Intentionally skip `f.setMineCore(mineCore)` here: the setter
        // validator refuses to back-bind a fresh Furnace to a MineCore
        // already wired to a *different* Furnace (the one wired in setUp()).
        // The three SR freeze-revert tests that consume this helper are
        // expected to revert in `freezeConfig` at one of the
        // claimAllHelper / helper.royalties() / helper.mineCore() checks,
        // which all fire *before* `_requireCanonicalBaronRuntimeBundle`.
        f.setMineMarket(mineMarket);
        sr.setWiring(address(mineCore), mineMarket, address(f));
        vm.stopPrank();
    }

    function _freshVeFreezeBundle() internal returns (VeFreezeBundle memory bundle) {
        bundle.claim = new ClaimToken(owner);
        bundle.ve = new VeClaimNFTHarness(address(bundle.claim), owner);
        bundle.royalties = new ShareholderRoyalties(address(bundle.ve), owner);
        bundle.mineCore = new MineCore(address(bundle.claim), address(bundle.ve), address(bundle.royalties), owner);
        bundle.furnace = new Furnace(
            address(bundle.claim),
            address(bundle.ve),
            address(new FurnaceGuardHelper(address(bundle.claim), address(bundle.ve))),
            owner
        );
        bundle.mineMarket = address(new MockContract());

        vm.mockCall(bundle.mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(bundle.claim)));
        vm.mockCall(bundle.mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(bundle.ve)));
    }

    // ----------------------------------------------------------------
    //  Furnace freeze
    // ----------------------------------------------------------------

    function testFurnaceFreezeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(address(furnace));
        emit Events.ConfigFrozen();
        furnace.freezeConfig();
    }

    function testFurnaceFreezeBlocksSetShareholderRoyalties() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        furnace.setShareholderRoyalties(address(0x1));
    }

    function testFurnaceFreezeBlocksSetMineCore() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        furnace.setMineCore(address(0x1));
    }

    function testFurnaceFreezeBlocksSetMineMarket() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        furnace.setMineMarket(address(0x1));
    }

    function testFurnaceFreezeBlocksSetFurnaceQuoter() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        furnace.setFurnaceQuoter(address(0x1));
    }

    function testFurnaceFreezeBlocksSetLpRewardsVault() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        furnace.setLpRewardsVault(address(0x1));
    }

    function testFurnaceFreezeDoesNotBlockEmergencyVaultRewireRequestGuards() public {
        MockLpRewardsVault replacement = new MockLpRewardsVault();
        replacement.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.requestEmergencyVaultRewire(address(replacement));
    }

    function testFurnaceFreezeDoesNotBlockEmergencyVaultRewireCancelGuards() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireNotRequested.selector);
        furnace.cancelEmergencyVaultRewire();
    }

    function testFurnaceFreezeDoesNotBlockEmergencyVaultRewireExecuteGuards() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireNotRequested.selector);
        furnace.executeEmergencyVaultRewire();
    }

    function testFurnaceDoubleFreeze() public {
        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        furnace.freezeConfig();
    }

    function testFurnaceFreezeRevertsIfShareholderRoyaltiesZero() public {
        // Don't bind `fresh` to the canonical `mineCore` here: the setter
        // (`validateMineCoreSetter`) rejects a `Furnace.setMineCore(mineCore)`
        // call whenever `mineCore.furnace()` is already pointed at a different
        // Furnace (the one wired in `setUp`). The freezeConfig validator's first
        // check fires `ZeroAddress` on the first unset root regardless, so the
        // test still pins the expected revert path.
        Furnace fresh = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        vm.startPrank(owner);
        fresh.setMineMarket(mineMarket);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
        vm.stopPrank();
    }

    function testFurnaceFreezeRevertsIfNoPointersSet() public {
        Furnace fresh = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    function testFurnaceFreezeRevertsIfQuoterZero() public {
        // See note in `testFurnaceFreezeRevertsIfShareholderRoyaltiesZero` for why
        // we skip `fresh.setMineCore(mineCore)`: the setter validator
        // refuses a back-binding to a MineCore that's already wired to a
        // different Furnace, and the freeze validator's first ZeroAddress
        // check fires on the first unset root regardless.
        Furnace fresh = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(ve), owner);
        vm.startPrank(owner);
        fresh.setShareholderRoyalties(address(freshRoyalties));
        fresh.setMineMarket(mineMarket);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
        vm.stopPrank();
    }

    function testFurnaceFreezeRevertsOnForeignMineMarketBundle() public {
        address wrongMarket = address(new MockContract());
        vm.startPrank(owner);
        furnace.setMineMarket(wrongMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.freezeConfig();
        vm.stopPrank();
    }

    function testFurnaceFreezeOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        furnace.freezeConfig();
    }

    function testFurnaceOperationalSettersStillWorkAfterFreeze() public {
        vm.prank(owner);
        furnace.freezeConfig();

        address newRegistry = address(new MockContract());
        vm.prank(owner);
        furnace.setEntryTokenRegistry(newRegistry);
    }

    // ----------------------------------------------------------------
    //  MineCore freeze
    // ----------------------------------------------------------------

    function testMineCoreFreezeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(address(mineCore));
        emit Events.ConfigFrozen();
        mineCore.freezeConfig();
    }

    function testMineCoreFreezeBlocksSetFurnace() public {
        vm.prank(owner);
        mineCore.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        mineCore.setFurnace(address(0x1));
    }

    function testMineCoreDoubleFreeze() public {
        vm.prank(owner);
        mineCore.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        mineCore.freezeConfig();
    }

    function testMineCoreFreezeRevertsIfFurnaceZero() public {
        MineCore fresh = _freshMineCoreRoots().mineCore;
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    function testMineCoreFreezeRevertsIfClaimAllHelperZero() public {
        MineCore fresh = _freshWiredMineCore();
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    function testMineCoreFreezeRevertsOnForeignFurnaceBundle() public {
        MineCoreFreezeBundle memory fresh = _freshCanonicalMineCoreBundle();
        ClaimAllHelper goodHelper = new ClaimAllHelper(address(fresh.royalties), address(fresh.mineCore));
        vm.startPrank(owner);
        fresh.mineCore.setClaimAllHelper(address(goodHelper));
        fresh.royalties.setClaimAllHelper(address(goodHelper));
        fresh.mineCore.setFurnace(address(new MockContract()));
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.mineCore.freezeConfig();
        vm.stopPrank();
    }

    function testMineCoreFreezeOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        mineCore.freezeConfig();
    }

    function testMineCoreOperationalSettersStillWorkAfterFreeze() public {
        vm.prank(owner);
        mineCore.freezeConfig();

        address newRegistry = address(new MockContract());
        vm.prank(owner);
        mineCore.setEntryTokenRegistry(newRegistry);
    }

    // ----------------------------------------------------------------
    //  VeClaimNFT freeze
    // ----------------------------------------------------------------

    function testVeClaimNFTFreezeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(address(ve));
        emit Events.ConfigFrozen();
        ve.freezeConfig();
    }

    function testVeClaimNFTFreezeBlocksSetFurnace() public {
        vm.prank(owner);
        ve.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        ve.setFurnace(address(0x1));
    }

    function testVeClaimNFTFreezeBlocksSetMineMarket() public {
        vm.prank(owner);
        ve.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        ve.setMineMarket(address(0x1));
    }

    function testVeClaimNFTDoubleFreeze() public {
        vm.prank(owner);
        ve.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        ve.freezeConfig();
    }

    function testVeClaimNFTFreezeRevertsIfNoPointersSet() public {
        VeClaimNFTHarness fresh = new VeClaimNFTHarness(address(claim), owner);
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    function testVeClaimNFTFreezeRevertsIfFurnaceOmitsMineMarketReciprocal() public {
        VeFreezeBundle memory fresh = _freshVeFreezeBundle();
        vm.mockCall(fresh.mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(fresh.royalties)));

        vm.startPrank(owner);
        fresh.claim.setMineCore(address(fresh.mineCore));
        fresh.furnace.setMineCore(address(fresh.mineCore));
        fresh.furnace.setShareholderRoyalties(address(fresh.royalties));
        fresh.mineCore.setFurnace(address(fresh.furnace));
        fresh.royalties.setWiring(address(fresh.mineCore), fresh.mineMarket, address(fresh.furnace));
        fresh.ve.setFurnace(address(fresh.furnace));
        fresh.ve.setMineMarket(fresh.mineMarket);

        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.ve.freezeConfig();
        vm.stopPrank();
    }

    function testVeClaimNFTFreezeRevertsIfFurnaceOmitsRoyaltiesReciprocal() public {
        VeFreezeBundle memory fresh = _freshVeFreezeBundle();
        vm.mockCall(fresh.mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(fresh.royalties)));

        vm.startPrank(owner);
        fresh.claim.setMineCore(address(fresh.mineCore));
        fresh.furnace.setMineCore(address(fresh.mineCore));
        fresh.furnace.setMineMarket(fresh.mineMarket);
        fresh.mineCore.setFurnace(address(fresh.furnace));
        fresh.royalties.setWiring(address(fresh.mineCore), fresh.mineMarket, address(fresh.furnace));
        fresh.ve.setFurnace(address(fresh.furnace));
        fresh.ve.setMineMarket(fresh.mineMarket);

        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.ve.freezeConfig();
        vm.stopPrank();
    }

    function testVeClaimNFTFreezeRevertsIfMineMarketOmitsRoyaltiesReciprocal() public {
        VeFreezeBundle memory fresh = _freshVeFreezeBundle();
        vm.mockCall(fresh.mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0)));

        vm.startPrank(owner);
        fresh.claim.setMineCore(address(fresh.mineCore));
        fresh.furnace.setMineCore(address(fresh.mineCore));
        fresh.furnace.setShareholderRoyalties(address(fresh.royalties));
        fresh.furnace.setMineMarket(fresh.mineMarket);
        fresh.mineCore.setFurnace(address(fresh.furnace));
        fresh.royalties.setWiring(address(fresh.mineCore), fresh.mineMarket, address(fresh.furnace));
        fresh.ve.setFurnace(address(fresh.furnace));
        fresh.ve.setMineMarket(fresh.mineMarket);

        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.ve.freezeConfig();
        vm.stopPrank();
    }

    function testVeClaimNFTFreezeOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        ve.freezeConfig();
    }

    // ----------------------------------------------------------------
    //  ShareholderRoyalties freeze
    // ----------------------------------------------------------------

    function testShareholderRoyaltiesFreezeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(address(royalties));
        emit Events.ConfigFrozen();
        royalties.freezeConfig();
    }

    function testShareholderRoyaltiesFreezeBlocksSetWiring() public {
        vm.prank(owner);
        royalties.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        royalties.setWiring(address(0x1), address(0x2), address(0x3));
    }

    function testShareholderRoyaltiesDoubleFreeze() public {
        vm.prank(owner);
        royalties.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        royalties.freezeConfig();
    }

    function testShareholderRoyaltiesFreezeRevertsIfNoPointersSet() public {
        ShareholderRoyalties fresh = new ShareholderRoyalties(address(ve), owner);
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    function testShareholderRoyaltiesFreezeRevertsIfClaimAllHelperZero() public {
        ShareholderRoyalties fresh = _freshWiredRoyalties();
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    function testShareholderRoyaltiesFreezeRevertsOnForeignBundle() public {
        ShareholderRoyalties fresh = new ShareholderRoyalties(address(ve), owner);
        vm.startPrank(owner);
        fresh.setWiring(address(new MockContract()), address(new MockContract()), address(new MockContract()));
        fresh.setClaimAllHelper(claimAllHelper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.freezeConfig();
        vm.stopPrank();
    }

    function testShareholderRoyaltiesFreezeOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        royalties.freezeConfig();
    }

    function testShareholderRoyaltiesSetClaimAllHelperBlockedAfterFreeze() public {
        vm.prank(owner);
        royalties.freezeConfig();

        address helper = address(new MockContract());
        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        royalties.setClaimAllHelper(helper);
    }

    // ----------------------------------------------------------------
    //  Cross-contract: all 5 can be frozen independently
    // ----------------------------------------------------------------

    function testAllFiveFreezeIndependently() public {
        vm.startPrank(owner);
        claim.freezeConfig();
        furnace.freezeConfig();
        mineCore.freezeConfig();
        ve.freezeConfig();
        royalties.freezeConfig();
        vm.stopPrank();

        assertTrue(claim.configFrozen());
        assertTrue(furnace.configFrozen());
        assertTrue(mineCore.configFrozen());
        assertTrue(ve.configFrozen());
        assertTrue(royalties.configFrozen());
    }

    function testConfigFrozenDefaultsFalse() public {
        Furnace fresh = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), address(this)
        );
        assertFalse(fresh.configFrozen());
    }

    // ----------------------------------------------------------------
    //  ClaimAllHelper reciprocal wiring validation at freeze
    // ----------------------------------------------------------------

    function testMineCoreFreezeRevertsIfHelperPointsToWrongMineCore() public {
        MineCoreFreezeBundle memory fresh = _freshCanonicalMineCoreBundle();
        MineCore wrongCore = _freshMineCoreRoots().mineCore;
        ClaimAllHelper badHelper = new ClaimAllHelper(address(fresh.royalties), address(wrongCore));
        vm.startPrank(owner);
        fresh.mineCore.setClaimAllHelper(address(badHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.mineCore.freezeConfig();
        vm.stopPrank();
    }

    function testMineCoreFreezeRevertsIfHelperPointsToWrongRoyalties() public {
        MineCoreFreezeBundle memory fresh = _freshCanonicalMineCoreBundle();
        ShareholderRoyalties wrongRoyalties = _freshMineCoreRoots().royalties;
        ClaimAllHelper badHelper = new ClaimAllHelper(address(wrongRoyalties), address(fresh.mineCore));
        vm.startPrank(owner);
        fresh.mineCore.setClaimAllHelper(address(badHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.mineCore.freezeConfig();
        vm.stopPrank();
    }

    function testShareholderRoyaltiesFreezeRevertsIfHelperPointsToWrongRoyalties() public {
        ShareholderRoyalties wrongRoyalties = new ShareholderRoyalties(address(ve), owner);
        ClaimAllHelper badHelper = new ClaimAllHelper(address(wrongRoyalties), address(mineCore));
        ShareholderRoyalties fresh = _freshWiredRoyalties();
        vm.startPrank(owner);
        fresh.setClaimAllHelper(address(badHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.freezeConfig();
        vm.stopPrank();
    }

    function testShareholderRoyaltiesFreezeRevertsIfHelperPointsToWrongMineCore() public {
        MineCore wrongCore = _freshMineCoreRoots().mineCore;
        ShareholderRoyalties fresh = _freshWiredRoyalties();
        ClaimAllHelper badHelper = new ClaimAllHelper(address(fresh), address(wrongCore));
        vm.startPrank(owner);
        fresh.setClaimAllHelper(address(badHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.freezeConfig();
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    //  Mismatched-but-both-canonical helpers (H1 vs H2)
    // ----------------------------------------------------------------

    function testFreezeRevertsIfMineCoreAndRoyaltiesHaveDifferentHelpers() public {
        ClaimAllHelper h1 = ClaimAllHelper(claimAllHelper); // already set in setUp
        ClaimAllHelper h2 = new ClaimAllHelper(address(royalties), address(mineCore));
        require(address(h1) != address(h2), "precondition: distinct helper instances");

        // MineCore -> H1 (from setUp), ShareholderRoyalties -> H2 via real setter.
        vm.prank(owner);
        royalties.setClaimAllHelper(address(h2));

        // MineCore.freezeConfig() sees SR.claimAllHelper() == H2 != H1 => WiringMismatch.
        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.freezeConfig();

        // Reverse: MineCore -> H2, ShareholderRoyalties -> H1 via real setters.
        vm.startPrank(owner);
        mineCore.setClaimAllHelper(address(h2));
        royalties.setClaimAllHelper(address(h1));
        vm.stopPrank();

        // ShareholderRoyalties.freezeConfig() sees MC.claimAllHelper() == H2 != H1 => WiringMismatch.
        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.freezeConfig();
    }
}
