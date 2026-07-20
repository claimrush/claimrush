// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";

import {MockAerodromeRouterMineCore} from "./mocks/MockAerodromeRouterMineCore.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Hostile entry-token registry. Returns a hostile router plus the *canonical* CLAIM
///         (so `getValidatedRouterConfig`'s `claimToken == claim` check passes) and a WETH/CLAIM
///         hop pool the hostile router agrees with. Only `getRouterConfig`/`getWethClaimHop` are
///         exercised by the ETH entry path, so the rest of IEntryTokenRegistry is omitted.
contract HostileRegistry {
    address public router;
    address public factory;
    address public weth;
    address public claimToken;
    address public pool;

    constructor(address router_, address factory_, address weth_, address claim_, address pool_) {
        router = router_;
        factory = factory_;
        weth = weth_;
        claimToken = claim_;
        pool = pool_;
    }

    function getRouterConfig() external view returns (address, address, address, address) {
        return (router, factory, weth, claimToken);
    }

    function getWethClaimHop() external view returns (bool stable, address p) {
        return (false, pool);
    }
}

/// @notice Hostile router (IDexAdapter shape): keeps the ETH and reports a fabricated CLAIM output
///         it never actually delivers to `to`.
contract HostileRouter {
    address public immutable pool;
    uint256 public fakeOut;

    constructor(address pool_) {
        pool = pool_;
    }

    function setFakeOut(uint256 x) external {
        fakeOut = x;
    }

    function poolFor(address, address, bool, address) external view returns (address) {
        return pool;
    }

    function swapExactETHForTokens(uint256, IDexAdapter.Route[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        // Keep the ETH. Deliver NO CLAIM to `to`. Report a huge fabricated output that the
        // pre-fix Furnace would have trusted as `principalClaim` (= amounts[last]).
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = fakeOut;
    }
}

/// @notice audit F-1 regression: a hostile registry/router can no longer drain `furnaceReserve`.
///         Furnace now derives `principalClaim` from the recipient's measured CLAIM balance delta,
///         so a router that keeps the ETH and delivers no CLAIM yields principalClaim == 0 and the
///         entry reverts AmountZero — instead of minting a veCLAIM lock funded from the reserve.
contract Furnace_HostileRouterDrain_F1_Test is Test {
    address internal owner;
    address internal alice;

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;
    MockWETH internal weth;
    MockAerodromeRouterMineCore internal mineCore; // doubles as canonical MineCore for wiring/reserve

    uint256 internal constant RESERVE = 1_000_000e18;
    address internal constant FACTORY = address(0xFACADE);
    address internal constant DUMMY_POOL = address(0xDEAD);

    function setUp() public {
        vm.txGasPrice(0);
        owner = makeAddr("owner");
        alice = makeAddr("alice");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        weth = new MockWETH();

        vm.etch(FACTORY, hex"01"); // factory address must carry code to pass router-config validation
        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());
        mineCore = new MockAerodromeRouterMineCore(
            FACTORY, address(weth), address(claim), address(ve), address(furnace), mockSR
        );

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));

        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        furnace.setMineMarket(market);
        furnace.setShareholderRoyalties(mockSR);
        MockShareholderRoyaltiesCheckpoint(mockSR).setWiring(address(mineCore), market, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);
        furnace.setFurnaceQuoter(address(new FurnaceQuoter(address(furnace))));
        vm.stopPrank();

        // Seed the Furnace reserve — the asset a hostile router would try to drain.
        deal(address(claim), address(furnace), RESERVE);
        vm.prank(address(mineCore));
        furnace.creditReserve(RESERVE);
    }

    function test_F1_hostileRouter_cannotDrainReserve_viaEnterWithEth() public {
        HostileRouter hostileRouter = new HostileRouter(DUMMY_POOL);
        // Claim to have delivered ~the entire reserve (what the pre-fix code trusted blindly).
        hostileRouter.setFakeOut(RESERVE - 1e18);
        HostileRegistry hostileReg =
            new HostileRegistry(address(hostileRouter), FACTORY, address(weth), address(claim), DUMMY_POOL);

        // The registry setter intentionally survives freezeConfig(), so the owner can repoint it.
        vm.prank(owner);
        furnace.setEntryTokenRegistry(address(hostileReg));

        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 furnaceClaimBefore = claim.balanceOf(address(furnace));
        assertEq(reserveBefore, RESERVE, "reserve seeded");

        // Pre-fix: principalClaim = amounts[last] = RESERVE-1e18 -> a lock of ~RESERVE minted from
        // furnaceReserve for ~1 wei of ETH. Post-fix: the measured CLAIM delta is 0 -> AmountZero.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        furnace.enterWithEth{value: 1 ether}(0, Constants.MIN_LOCK_DURATION, false, 1);

        // The reserve is untouched and the attacker received no veCLAIM.
        assertEq(furnace.furnaceReserve(), reserveBefore, "reserve must be untouched");
        assertEq(claim.balanceOf(address(furnace)), furnaceClaimBefore, "Furnace CLAIM balance untouched");
        assertEq(ve.balanceOf(alice), 0, "attacker minted no veCLAIM");
    }
}
