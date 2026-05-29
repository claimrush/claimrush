// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {DexAdapter} from "src/DexAdapter.sol";
import {Errors} from "src/lib/Errors.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Furnace} from "src/Furnace.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Coverage for the v1.0.0 EIP-7702 rejection surface introduced
///         on the keeper allowlists, the delegation-hub session seat, the
///         `ShareholderRoyalties` initializer, and the four Ownable-based
///         constructors (`ClaimToken`, `DexAdapter`, `VeClaimNFT`,
///         `LpStakingVault7D`). Models a delegated EOA with `vm.etch` of
///         a 23-byte `0xEF0100 || target` designator.
contract AuditClosure7702RejectionsTest is Test {
    address internal owner = makeAddr("owner");
    address internal eoa = makeAddr("delegatedEoa");

    /// @dev Etch an EIP-7702 designator at `target`: `0xEF 0x01 0x00 || delegate`.
    function _etch7702(address target, address delegate) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", delegate));
        assertEq(target.code.length, 23, "7702 designator must be exactly 23 bytes");
    }

    /* ------------------------------------------------------------------ */
    /*  DelegationHub: delegate seat                                       */
    /* ------------------------------------------------------------------ */

    function testDelegationHubRejectsDelegatedDelegateOnSeat() public {
        DelegationHub hub = new DelegationHub();
        address user = makeAddr("user");
        _etch7702(eoa, address(this));

        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(user);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        hub.setSession(eoa, DelegationPermissions.P_TAKEOVER_FOR, expiry);
    }

    function testDelegationHubAllowsRevocationOfDelegatedSeat() public {
        DelegationHub hub = new DelegationHub();
        address user = makeAddr("user");
        // Seat the session against a normal EOA first.
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(user);
        hub.setSession(eoa, DelegationPermissions.P_TAKEOVER_FOR, expiry);

        // Target then becomes a delegated EOA. Revocation must still succeed.
        _etch7702(eoa, address(this));
        vm.prank(user);
        hub.revokeSession(eoa);

        (uint256 perms, uint256 storedExpiry) = hub.getSession(user, eoa);
        assertEq(perms, 0);
        assertEq(storedExpiry, 0);
    }

    function testDelegationHubAcceptsNormalEoaDelegate() public {
        DelegationHub hub = new DelegationHub();
        address user = makeAddr("user");
        address normalEoa = makeAddr("normalEoa");
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(user);
        hub.setSession(normalEoa, DelegationPermissions.P_TAKEOVER_FOR, expiry);

        (uint256 perms,) = hub.getSession(user, normalEoa);
        assertEq(perms, DelegationPermissions.P_TAKEOVER_FOR);
    }

    /* ------------------------------------------------------------------ */
    /*  Keeper allowlists                                                  */
    /* ------------------------------------------------------------------ */

    function _roots()
        internal
        returns (MockERC20 claim, VeClaimNFT ve, ShareholderRoyalties royalties, MockContract helper)
    {
        claim = new MockERC20("CLAIM", "CLAIM");
        ve = new VeClaimNFT(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        helper = new MockContract();
    }

    function testMarketRouterSetSettlementKeeperRejectsDelegatedEOA() public {
        (MockERC20 claim, VeClaimNFT ve, ShareholderRoyalties royalties,) = _roots();
        MarketRouter router = new MarketRouter(address(claim), address(ve), address(royalties), owner);

        _etch7702(eoa, address(this));
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        router.setSettlementKeeper(eoa, true);
    }

    function testMarketRouterSetSettlementKeeperAllowsRevocationOfDelegatedSeat() public {
        (MockERC20 claim, VeClaimNFT ve, ShareholderRoyalties royalties,) = _roots();
        MarketRouter router = new MarketRouter(address(claim), address(ve), address(royalties), owner);

        // Seat normally first.
        vm.prank(owner);
        router.setSettlementKeeper(eoa, true);
        assertTrue(router.isSettlementKeeper(eoa));

        // Address subsequently becomes a delegated EOA; revoke must still succeed.
        _etch7702(eoa, address(this));
        vm.prank(owner);
        router.setSettlementKeeper(eoa, false);
        assertFalse(router.isSettlementKeeper(eoa));
    }

    function testShareholderRoyaltiesSetAutoCompoundKeeperRejectsDelegatedEOA() public {
        (,, ShareholderRoyalties royalties,) = _roots();
        _etch7702(eoa, address(this));
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        royalties.setAutoCompoundKeeper(eoa, true);
    }

    function testShareholderRoyaltiesSetAutoCompoundKeeperAllowsRevocation() public {
        (,, ShareholderRoyalties royalties,) = _roots();
        vm.prank(owner);
        royalties.setAutoCompoundKeeper(eoa, true);
        assertTrue(royalties.isAutoCompoundKeeper(eoa));

        _etch7702(eoa, address(this));
        vm.prank(owner);
        royalties.setAutoCompoundKeeper(eoa, false);
        assertFalse(royalties.isAutoCompoundKeeper(eoa));
    }

    /* ------------------------------------------------------------------ */
    /*  ShareholderRoyalties initializer                                   */
    /* ------------------------------------------------------------------ */

    function testShareholderRoyaltiesConstructorRejectsDelegatedInitialOwner() public {
        (, VeClaimNFT ve,,) = _roots();
        address delegated = makeAddr("delegatedRoyaltiesOwner");
        _etch7702(delegated, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new ShareholderRoyalties(address(ve), delegated);
    }

    /* ------------------------------------------------------------------ */
    /*  ClaimToken constructor                                             */
    /* ------------------------------------------------------------------ */

    function testClaimTokenConstructorRejectsDelegatedInitialOwner() public {
        address delegated = makeAddr("delegatedClaimTokenOwner");
        _etch7702(delegated, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new ClaimToken(delegated);
    }

    function testClaimTokenConstructorRejectsZeroOwner() public {
        // Sanity: pre-existing Ownable zero check still holds.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ClaimToken(address(0));
    }

    /* ------------------------------------------------------------------ */
    /*  DexAdapter constructor                                             */
    /* ------------------------------------------------------------------ */

    function testDexAdapterConstructorRejectsDelegatedInitialOwner() public {
        address factory = address(0xFACA01);
        address wrappedNative = address(0xBEEF01);
        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        MockAerodromeRouter router = new MockAerodromeRouter(factory, wrappedNative);

        address delegated = makeAddr("delegatedDexAdapterOwner");
        _etch7702(delegated, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new DexAdapter(address(router), delegated);
    }

    /* ------------------------------------------------------------------ */
    /*  VeClaimNFT constructor                                             */
    /* ------------------------------------------------------------------ */

    function testVeClaimNFTConstructorRejectsDelegatedInitialOwner() public {
        MockERC20 claim = new MockERC20("CLAIM", "CLAIM");
        address delegated = makeAddr("delegatedVeOwner");
        _etch7702(delegated, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new VeClaimNFT(address(claim), delegated);
    }

    /* ------------------------------------------------------------------ */
    /*  LpStakingVault7D constructor + setHarvestKeeper                    */
    /* ------------------------------------------------------------------ */

    function _lpVaultRoots()
        internal
        returns (
            MockERC20 claim,
            MockERC20 weth,
            VeClaimNFT ve,
            Furnace furnace,
            MockAerodromeRouter router,
            address pool,
            address factory
        )
    {
        claim = new MockERC20("CLAIM", "CLAIM");
        weth = new MockERC20("WETH", "WETH");
        ve = new VeClaimNFT(address(claim), owner);
        MockContract helper = new MockContract();
        furnace = new Furnace(address(claim), address(ve), address(helper), owner);
        factory = address(new MockContract());
        pool = makeAddr("lpPool");
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claim), false, factory, pool);
    }

    function testLpStakingVault7DConstructorRejectsDelegatedInitialOwner() public {
        (
            MockERC20 claim,
            MockERC20 weth,
            VeClaimNFT ve,
            Furnace furnace,
            MockAerodromeRouter router,
            address pool,
            address factory
        ) = _lpVaultRoots();

        address delegated = makeAddr("delegatedLpVaultOwner");
        _etch7702(delegated, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LpStakingVault7D(
            pool,
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            delegated
        );
    }

    function testLpStakingVault7DSetHarvestKeeperRejectsDelegatedEOA() public {
        (
            MockERC20 claim,
            MockERC20 weth,
            VeClaimNFT ve,
            Furnace furnace,
            MockAerodromeRouter router,
            address pool,
            address factory
        ) = _lpVaultRoots();

        LpStakingVault7D vault = new LpStakingVault7D(
            pool, address(weth), address(claim), address(ve), address(furnace), address(router), factory, false, owner
        );

        _etch7702(eoa, address(this));
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        vault.setHarvestKeeper(eoa, true);
    }

    function testLpStakingVault7DSetHarvestKeeperAllowsRevocation() public {
        (
            MockERC20 claim,
            MockERC20 weth,
            VeClaimNFT ve,
            Furnace furnace,
            MockAerodromeRouter router,
            address pool,
            address factory
        ) = _lpVaultRoots();

        LpStakingVault7D vault = new LpStakingVault7D(
            pool, address(weth), address(claim), address(ve), address(furnace), address(router), factory, false, owner
        );

        vm.prank(owner);
        vault.setHarvestKeeper(eoa, true);
        assertTrue(vault.isHarvestKeeper(eoa));

        _etch7702(eoa, address(this));
        vm.prank(owner);
        vault.setHarvestKeeper(eoa, false);
        assertFalse(vault.isHarvestKeeper(eoa));
    }
}
