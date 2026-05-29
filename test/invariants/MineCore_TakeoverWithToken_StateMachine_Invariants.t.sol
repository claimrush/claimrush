// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";

import {MockVe} from "../mocks/MockVe.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";

contract TakeoverTokenRefundRejector {
    receive() external payable {
        revert("refund reject");
    }
}

contract TakeoverTokenGasBombReceiver {
    uint256 internal a;
    uint256 internal b;

    receive() external payable {
        // Consume enough gas to break the 30k stipend payout.
        a = block.number;
        b = block.timestamp;
    }
}

/// @notice State-machine style fuzz that specifically targets MineCore.takeoverWithToken()
///         and its dependency on EntryTokenRegistry route wiring.
contract MineCoreTakeoverWithTokenStateMachineInvariants is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    EntryTokenRegistry internal reg;
    MockAerodromeRouter internal router;
    MockWETH internal weth;
    MockERC20 internal entry;

    address internal owner;
    address internal factory;
    address internal pool;
    bool internal stable;

    bool internal tokenEnabled;
    bool internal poolGood;

    TakeoverTokenGasBombReceiver internal gasBomb;
    TakeoverTokenRefundRejector internal refundRejector;

    address[] internal actors;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        factory = makeAddr("factory");
        stable = false;

        // Tokens + router
        weth = new MockWETH();
        entry = new MockERC20("EntryToken", "ENTRY");
        router = new MockAerodromeRouter(factory, address(weth));
        pool = makeAddr("POOL_ENTRY_WETH");
        vm.etch(pool, hex"00");
        router.setPoolFor(address(entry), address(weth), stable, factory, pool);

        // Ensure MockWETH can always pay withdrawals even if WETH is minted in swaps.
        vm.deal(address(weth), 1_000_000 ether);

        // Core contracts
        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        reg = new EntryTokenRegistry(owner);

        // factory is a bare address; give it bytecode so it passes NotAContract checks in setRouterConfig.
        vm.etch(factory, hex"00");

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));

        mineCore.setEntryTokenRegistry(address(reg));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));

        vm.startPrank(owner);

        // Registry wiring for takeoverWithToken
        reg.setRouterConfig(address(router), factory, address(weth), address(claim));
        // (tokenClaimHop unused for takeovers; set to zero)
        reg.setTokenConfig(address(entry), true, false, false, address(0), stable, pool);
        vm.stopPrank();

        tokenEnabled = true;
        poolGood = true;

        // Ensure ve aggregate is non-zero so shareholder math stays in a normal range.
        ve.setTotalVeCached(1234);

        gasBomb = new TakeoverTokenGasBombReceiver();
        refundRejector = new TakeoverTokenRefundRejector();

        // Actors
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(address(gasBomb));
        actors.push(address(refundRejector));

        // Unlimited approvals for takeoverWithToken transferFrom.
        for (uint256 i = 0; i < actors.length; ++i) {
            vm.prank(actors[i]);
            entry.approve(address(mineCore), type(uint256).max);
            vm.prank(actors[i]);
            weth.approve(address(mineCore), type(uint256).max);
        }
    }

    function testFuzz_stateMachine_takeoverWithToken_registryWiring(uint256 seed) public {
        _seedNonZeroCredits();

        uint256 steps = 18;
        for (uint256 i = 0; i < steps; ++i) {
            bytes32 h = keccak256(abi.encode(seed, i));

            // time advances affect takeover price + accrual accounting
            vm.warp(block.timestamp + 1 + (uint256(h) % 600));

            uint8 action = uint8(uint256(h) % 6);
            address actor = actors[uint256(uint8(uint256(h >> 8))) % actors.length];

            if (action == 0) {
                _attemptEntryTokenTakeover(actor, uint256(h >> 16) % 0.25 ether);
            } else if (action == 1) {
                _attemptWethTakeover(actor);
            } else if (action == 2) {
                _setTokenEnabled(false);
            } else if (action == 3) {
                _setTokenEnabled(true);
            } else if (action == 4) {
                _breakPoolMapping();
            } else {
                _restorePoolMapping();
            }

            _assertRegistryRouteWiring();
            _assertLiabilitiesCovered();
        }

        _assertLiabilitiesCovered();
    }

    // ------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------

    function _attemptEntryTokenTakeover(address actor, uint256 extraEth) internal {
        address current = mineCore.currentKing();
        if (current != address(0) && actor == current) return;

        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 amountIn = price + extraEth;
        if (amountIn == 0) amountIn = 1;

        entry.mint(actor, amountIn);

        bool expectOk = tokenEnabled && poolGood;

        // Build the exact route MineCore should pass to the router.
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(entry), to: address(weth), stable: stable, factory: factory});
        bytes32 expectedRoutesHash = keccak256(abi.encode(routes));
        uint256 expectedDeadline = block.timestamp + Constants.SWAP_DEADLINE_SECONDS;

        vm.prank(actor);
        (bool ok,) = address(mineCore)
            .call(abi.encodeCall(MineCore.takeoverWithToken, (address(entry), amountIn, 1, type(uint256).max)));

        if (expectOk) {
            assertTrue(ok, "expected entry-token takeover success");

            // Router was called with the deterministic, allowlisted 1-hop route.
            assertEq(router.lastAmountIn(), amountIn, "router.amountIn");
            assertEq(router.lastAmountOutMin(), 1, "router.amountOutMin");
            assertEq(router.lastTo(), address(mineCore), "router.to");
            assertEq(router.lastDeadline(), expectedDeadline, "router.deadline");
            assertEq(router.lastRoutesHash(), expectedRoutesHash, "router.routesHash");

            // MineCore should not retain any swap tokens after _swapTokenToEth.
            assertEq(entry.balanceOf(address(mineCore)), 0, "mineCore.entry dust");
            assertEq(weth.balanceOf(address(mineCore)), 0, "mineCore.weth dust");
        } else {
            assertFalse(ok, "expected entry-token takeover revert");
        }
    }

    function _attemptWethTakeover(address actor) internal {
        address current = mineCore.currentKing();
        if (current != address(0) && actor == current) return;

        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (price == 0) price = 1;

        // Acquire WETH via deposit so withdraw path is fully realistic.
        vm.deal(actor, price);
        vm.prank(actor);
        weth.deposit{value: price}();

        vm.prank(actor);
        (bool ok,) = address(mineCore)
            .call(abi.encodeCall(MineCore.takeoverWithToken, (address(weth), price, 1, type(uint256).max)));
        assertTrue(ok, "expected WETH takeover success");
        assertEq(weth.balanceOf(address(mineCore)), 0, "mineCore.weth dust (weth path)");
    }

    function _setTokenEnabled(bool enabled) internal {
        if (tokenEnabled == enabled) return;
        // setTokenEnabled(true) re-validates router.poolFor(...) against the stored tokenWeth pool.
        bool expectOk = !enabled || poolGood;

        vm.prank(owner);
        (bool ok,) = address(reg).call(abi.encodeCall(reg.setTokenEnabled, (address(entry), enabled)));

        assertEq(ok, expectOk);
        if (ok) {
            tokenEnabled = enabled;
        }
    }

    function _breakPoolMapping() internal {
        if (!poolGood) return;
        // Ensure the poolFor result differs from the allowlisted pool stored in the registry.
        address badPool = makeAddr("POOL_ENTRY_WETH_BAD");
        if (badPool == pool) badPool = address(uint160(uint256(keccak256("POOL_ENTRY_WETH_BAD2"))));
        vm.etch(badPool, hex"00");
        router.setPoolFor(address(entry), address(weth), stable, factory, badPool);
        poolGood = false;
    }

    function _restorePoolMapping() internal {
        if (poolGood) return;
        router.setPoolFor(address(entry), address(weth), stable, factory, pool);
        poolGood = true;
    }

    // ------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------

    function _assertRegistryRouteWiring() internal {
        // If disabled, resolveTakeoverRoute must not return a usable route.
        if (!tokenEnabled) {
            vm.expectRevert(Errors.TokenNotEnabled.selector);
            reg.resolveTakeoverRoute(address(entry));
            return;
        }

        // resolveTakeoverRoute validates pools at resolution time.
        if (!poolGood) {
            vm.expectRevert(Errors.InvalidPool.selector);
            reg.resolveTakeoverRoute(address(entry));
            return;
        }

        IEntryTokenRegistry.RegistryRoute[] memory route = reg.resolveTakeoverRoute(address(entry));
        assertEq(route.length, 1, "takeover route length");
        assertEq(route[0].tokenIn, address(entry), "route.tokenIn");
        assertEq(route[0].tokenOut, address(weth), "route.tokenOut");
        assertEq(route[0].stable, stable, "route.stable");
        assertEq(route[0].pool, pool, "route.pool");

        (address r, address f, address wn, address ct) = reg.getRouterConfig();
        assertEq(r, address(router), "router");
        assertEq(f, factory, "factory");
        assertEq(wn, address(weth), "wrappedNative");
        assertEq(ct, address(claim), "claimToken");
    }

    function _assertLiabilitiesCovered() internal {
        uint256 liability;
        for (uint256 i = 0; i < actors.length; ++i) {
            liability += mineCore.kingEthBalance(actors[i]);
            liability += mineCore.refundEthBalance(actors[i]);
        }
        assertLe(liability, address(mineCore).balance, "liabilities not covered");
    }

    // ------------------------------------------------------------
    // Seed
    // ------------------------------------------------------------

    function _seedNonZeroCredits() internal {
        // 1) Gas-bomb king ensures at least one failed payout that becomes kingEthBalance credit.
        uint256 p0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(address(gasBomb), p0);
        vm.prank(address(gasBomb));
        mineCore.takeover{value: p0}(type(uint256).max);

        // 2) Entry-token dethrone should attempt to pay gasBomb with stipend, fail, and credit.
        vm.warp(block.timestamp + 1);
        uint256 p1 = mineCore.getCurrentTakeoverPrice();
        entry.mint(actors[0], p1);
        vm.prank(actors[0]);
        mineCore.takeoverWithToken(address(entry), p1, 1, type(uint256).max);

        // 3) Refund-rejector overpays via entry token to create refundEthBalance credit.
        vm.warp(block.timestamp + 1);
        uint256 p2 = mineCore.getCurrentTakeoverPrice();
        uint256 extra = 0.123 ether;
        uint256 amountIn = p2 + extra;
        entry.mint(address(refundRejector), amountIn);
        vm.prank(address(refundRejector));
        mineCore.takeoverWithToken(address(entry), amountIn, 1, type(uint256).max);

        assertGt(mineCore.kingEthBalance(address(gasBomb)), 0, "seed: king credit");
        assertGt(mineCore.refundEthBalance(address(refundRejector)), 0, "seed: refund credit");

        _assertLiabilitiesCovered();
    }
}
