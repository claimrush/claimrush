// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Furnace} from "src/Furnace.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockContract} from "./mocks/MockContract.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract Constructor7702Router {
    address public immutable defaultFactory;
    address public immutable weth;
    address public immutable pool;

    constructor(address factory_, address weth_, address pool_) {
        defaultFactory = factory_;
        weth = weth_;
        pool = pool_;
    }

    function poolFor(address, address, bool, address) external view returns (address) {
        return pool;
    }
}

contract Constructor7702RejectionTest is Test {
    address internal owner = makeAddr("owner");

    function _etch7702(address target) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", address(this)));
        assertEq(target.code.length, 23, "designator length");
    }

    function _roots()
        internal
        returns (MockERC20 claim, VeClaimNFT ve, ShareholderRoyalties royalties, MockContract helper)
    {
        claim = new MockERC20("CLAIM", "CLAIM");
        ve = new VeClaimNFT(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        helper = new MockContract();
    }

    function testFurnaceConstructorRejectsDelegatedClaim() public {
        (, VeClaimNFT ve,, MockContract helper) = _roots();
        address delegated = makeAddr("delegatedClaim");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new Furnace(delegated, address(ve), address(helper), owner);
    }

    function testFurnaceConstructorRejectsDelegatedVe() public {
        (MockERC20 claim,,, MockContract helper) = _roots();
        address delegated = makeAddr("delegatedVe");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new Furnace(address(claim), delegated, address(helper), owner);
    }

    function testFurnaceConstructorRejectsDelegatedHelper() public {
        (MockERC20 claim, VeClaimNFT ve,,) = _roots();
        address delegated = makeAddr("delegatedHelper");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new Furnace(address(claim), address(ve), delegated, owner);
    }

    function testMarketRouterConstructorRejectsDelegatedClaim() public {
        (, VeClaimNFT ve, ShareholderRoyalties royalties,) = _roots();
        address delegated = makeAddr("delegatedMarketClaim");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new MarketRouter(delegated, address(ve), address(royalties), owner);
    }

    function testMarketRouterConstructorRejectsDelegatedVe() public {
        (MockERC20 claim,, ShareholderRoyalties royalties,) = _roots();
        address delegated = makeAddr("delegatedMarketVe");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new MarketRouter(address(claim), delegated, address(royalties), owner);
    }

    function testMarketRouterConstructorRejectsDelegatedRoyalties() public {
        (MockERC20 claim, VeClaimNFT ve,,) = _roots();
        address delegated = makeAddr("delegatedMarketRoyalties");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new MarketRouter(address(claim), address(ve), delegated, owner);
    }

    function testMarketRouterSetGuardianRejectsDelegatedEOA() public {
        (MockERC20 claim, VeClaimNFT ve, ShareholderRoyalties royalties,) = _roots();
        MarketRouter router = new MarketRouter(address(claim), address(ve), address(royalties), owner);

        address delegated = makeAddr("delegatedMarketGuardian");
        _etch7702(delegated);

        // owner can rotate guardian normally — establish baseline before exercising the rejection.
        address normalEoa = makeAddr("normalEoaGuardian");
        vm.prank(owner);
        router.setGuardian(normalEoa);
        assertEq(router.guardian(), normalEoa, "baseline rotation OK");

        // 7702-delegated EOA must be rejected, not silently installed.
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        router.setGuardian(delegated);

        // And from the existing guardian path too — both auth roads MUST reject.
        vm.prank(normalEoa);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        router.setGuardian(delegated);

        assertEq(router.guardian(), normalEoa, "guardian unchanged after rejection");
    }

    function testShareholderRoyaltiesConstructorRejectsDelegatedVe() public {
        address delegated = makeAddr("delegatedRoyaltiesVe");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new ShareholderRoyalties(delegated, owner);
    }

    function testVeConstructorRejectsDelegatedClaimToken() public {
        address delegated = makeAddr("delegatedVeClaim");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new VeClaimNFT(delegated, owner);
    }

    function testLpVaultConstructorRejectsDelegatedWeth() public {
        (MockERC20 claim, VeClaimNFT ve,, MockContract helper) = _roots();
        Furnace furnace = new Furnace(address(claim), address(ve), address(helper), owner);
        MockContract factory = new MockContract();
        address pool = makeAddr("lpPool");
        address delegated = makeAddr("delegatedWeth");
        _etch7702(delegated);
        Constructor7702Router router = new Constructor7702Router(address(factory), delegated, pool);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LpStakingVault7D(
            pool,
            delegated,
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            address(factory),
            false,
            owner
        );
    }

    function testLpVaultConstructorRejectsDelegatedClaim() public {
        (MockERC20 claim, VeClaimNFT ve,, MockContract helper) = _roots();
        Furnace furnace = new Furnace(address(claim), address(ve), address(helper), owner);
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockContract factory = new MockContract();
        address pool = makeAddr("lpPool");
        address delegated = makeAddr("delegatedLpClaim");
        _etch7702(delegated);
        Constructor7702Router router = new Constructor7702Router(address(factory), address(weth), pool);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LpStakingVault7D(
            pool,
            address(weth),
            delegated,
            address(ve),
            address(furnace),
            address(router),
            address(factory),
            false,
            owner
        );
    }

    function testLpVaultConstructorRejectsDelegatedVe() public {
        (MockERC20 claim, VeClaimNFT ve,, MockContract helper) = _roots();
        Furnace furnace = new Furnace(address(claim), address(ve), address(helper), owner);
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockContract factory = new MockContract();
        address pool = makeAddr("lpPool");
        address delegated = makeAddr("delegatedLpVe");
        _etch7702(delegated);
        Constructor7702Router router = new Constructor7702Router(address(factory), address(weth), pool);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LpStakingVault7D(
            pool,
            address(weth),
            address(claim),
            delegated,
            address(furnace),
            address(router),
            address(factory),
            false,
            owner
        );
    }

    function testLpVaultConstructorRejectsDelegatedFurnace() public {
        (MockERC20 claim, VeClaimNFT ve,,) = _roots();
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockContract factory = new MockContract();
        address pool = makeAddr("lpPool");
        address delegated = makeAddr("delegatedLpFurnace");
        _etch7702(delegated);
        Constructor7702Router router = new Constructor7702Router(address(factory), address(weth), pool);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LpStakingVault7D(
            pool, address(weth), address(claim), address(ve), delegated, address(router), address(factory), false, owner
        );
    }

    function testLpVaultConstructorRejectsDelegatedRouter() public {
        (MockERC20 claim, VeClaimNFT ve,, MockContract helper) = _roots();
        Furnace furnace = new Furnace(address(claim), address(ve), address(helper), owner);
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockContract factory = new MockContract();
        address pool = makeAddr("lpPool");
        address delegated = makeAddr("delegatedLpRouter");
        _etch7702(delegated);

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new LpStakingVault7D(
            pool,
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            delegated,
            address(factory),
            false,
            owner
        );
    }

    /* ------------------------------------------------------------------ */
    /*  ShareholderRoyalties.setWiring + setClaimAllHelper                 */
    /*                                                                     */
    /*  Constructor-time rejection alone is not enough for these wiring    */
    /*  setters: a 7702-delegated EOA can pass the existing `code.length`  */
    /*  check AND the reciprocal selector probes during the wiring/freeze  */
    /*  transaction (delegate code can return whatever it wants), then     */
    /*  later revoke or rotate. After `freezeConfig()` makes the wiring    */
    /*  immutable, that rotation breaks the canonical-bundle check         */
    /*  permanently and strands every shareholder ETH path. These tests    */
    /*  pin the same `_rejectDelegatedEOA` rejection on every setter slot  */
    /*  that ends up in royalties storage.                                 */
    /* ------------------------------------------------------------------ */

    function testRoyaltiesSetWiringRejectsDelegatedMineCore() public {
        (, VeClaimNFT ve, ShareholderRoyalties royalties,) = _roots();
        address normalCore = address(new MockContract());
        address normalMarket = address(new MockContract());
        address normalFurnace = address(new MockContract());
        address delegated = makeAddr("delegatedRoyaltiesMineCore");
        _etch7702(delegated);

        // Baseline: a normal contract triple is accepted (proves we're testing
        // the new check, not an unrelated revert path).
        vm.prank(owner);
        royalties.setWiring(normalCore, normalMarket, normalFurnace);

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        royalties.setWiring(delegated, normalMarket, normalFurnace);

        // ve linkage untouched because setWiring reverted before storing.
        assertEq(address(royalties.ve()), address(ve));
    }

    function testRoyaltiesSetWiringRejectsDelegatedMineMarket() public {
        (,, ShareholderRoyalties royalties,) = _roots();
        address normalCore = address(new MockContract());
        address normalFurnace = address(new MockContract());
        address delegated = makeAddr("delegatedRoyaltiesMineMarket");
        _etch7702(delegated);

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        royalties.setWiring(normalCore, delegated, normalFurnace);
    }

    function testRoyaltiesSetWiringRejectsDelegatedFurnace() public {
        (,, ShareholderRoyalties royalties,) = _roots();
        address normalCore = address(new MockContract());
        address normalMarket = address(new MockContract());
        address delegated = makeAddr("delegatedRoyaltiesFurnace");
        _etch7702(delegated);

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        royalties.setWiring(normalCore, normalMarket, delegated);
    }

    function testRoyaltiesSetClaimAllHelperRejectsDelegatedEOA() public {
        (,, ShareholderRoyalties royalties,) = _roots();
        address normalHelper = address(new MockContract());
        address delegated = makeAddr("delegatedRoyaltiesClaimAllHelper");
        _etch7702(delegated);

        // Baseline: setting a normal contract works.
        vm.prank(owner);
        royalties.setClaimAllHelper(normalHelper);
        assertEq(royalties.claimAllHelper(), normalHelper);

        // 7702-delegated EOA must be rejected — leaves prior helper intact.
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        royalties.setClaimAllHelper(delegated);

        assertEq(royalties.claimAllHelper(), normalHelper, "helper unchanged after rejection");
    }
}
