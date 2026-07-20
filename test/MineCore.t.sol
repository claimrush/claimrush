// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {MineCoreQuoter} from "src/MineCoreQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationActionTypes} from "src/lib/DelegationActionTypes.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {UpgradeableProtocolBase} from "src/lib/UpgradeableProtocolBase.sol";
import {MineCoreProxy} from "src/lib/RuntimeProxyWrappers.sol";

import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockGenesisGuardian} from "./mocks/MockGenesisGuardian.sol";
import {MockMineCoreFurnaceNoRoyaltiesGetter} from "./mocks/MockMineCoreFurnaceNoRoyaltiesGetter.sol";

/// @dev Receiver that returns a large blob of returndata on ETH receive.
///      Used to ensure the caller is not vulnerable to "return bombs".
contract ReturnBombReceiverMineCore {
    MineCoreHarness internal immutable mineCore;

    constructor(MineCoreHarness mc) {
        mineCore = mc;
    }

    function withdrawKing() external {
        mineCore.withdrawKingBalance();
    }

    function withdrawRefundToSelf() external {
        mineCore.withdrawRefundBalance(address(this));
    }

    // No `receive()` on purpose: empty calldata hits fallback.
    fallback() external payable {
        assembly {
            let ptr := mload(0x40)
            // Return a large blob (65,536 bytes).
            return(ptr, 0x10000)
        }
    }
}

/// @dev Minimal MineCore-shaped contract that passes ClaimToken's pre-freeze identity check.
///      Used to model an accidental pre-freeze `ClaimToken.setMineCore(...)` reset away from
///      the live MineCore without changing the LaunchController fingerprint.
contract MockClaimTokenMineCoreResetTarget {
    address public immutable claim;

    constructor(address claim_) {
        claim = claim_;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}

contract MineCoreTest is Test {
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);
        ve.setClaimToken(address(claim));

        // Allow MineCore to mint CLAIM.
        vm.prank(owner);
        claim.setMineCore(address(mineCore));
    }

    function _deployValidRegistry() internal returns (address registryAddr) {
        MockWETH weth = new MockWETH();
        address factory = address(0xFACA);
        vm.etch(factory, hex"00");

        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(weth));
        EntryTokenRegistry reg = new EntryTokenRegistry(owner);

        vm.prank(owner);
        reg.setRouterConfig(address(router), factory, address(weth), address(claim));

        registryAddr = address(reg);
    }

    function _wireCanonicalFurnaceWithHub(address hub) internal returns (Furnace furnace) {
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        MockContract mineMarket = new MockContract();

        vm.startPrank(owner);
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(mineMarket));
        furnace.setShareholderRoyalties(address(royalties));
        ve.setMineMarket(address(mineMarket));
        ve.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), address(mineMarket), address(furnace));
        // MineCore must learn about the furnace and the canonical hub BEFORE we wire
        // the furnace-side hub pointer, because Furnace.setDelegationHub now runs
        // FurnaceGuardHelper.requireCanonicalDelegationHub which staticcalls
        // mineCore.furnace() / .delegationHub() / .claim() / .ve() and demands they
        // already match the canonical bundle.
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(hub);
        furnace.setDelegationHub(hub);
        vm.stopPrank();
    }

    function _authorize(DelegationHub hub, address user, address delegate, uint256 perms) internal {
        vm.prank(user);
        hub.setSession(delegate, perms, uint64(block.timestamp + 1 days));
    }

    function _unpauseTakeovers() internal {
        mineCore.setGenesisKingClaimCollectedForTest(true);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
    }

    function _newGenesisGuardian(address mineCoreRoot, address claimRoot) internal returns (MockGenesisGuardian g) {
        g = new MockGenesisGuardian();
        g.setRoots(mineCoreRoot, claimRoot);
    }

    function _newGenesisGuardian() internal returns (MockGenesisGuardian g) {
        return _newGenesisGuardian(address(mineCore), address(claim));
    }

    function _deployFreshMineCoreBundle(address initialOwner)
        internal
        returns (ClaimToken freshClaim, MockVe freshVe, ShareholderRoyalties freshRoyalties, MineCoreHarness freshCore)
    {
        freshClaim = new ClaimToken(owner);
        freshVe = new MockVe();
        freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        freshCore = new MineCoreHarness(address(freshClaim), address(freshVe), address(freshRoyalties), initialOwner);

        vm.prank(owner);
        freshClaim.setMineCore(address(freshCore));
        freshVe.setClaimToken(address(freshClaim));
    }

    function _configureTokenTakeoverRoute()
        internal
        returns (MockAerodromeRouter router, MockWETH weth, MockERC20 tokenIn)
    {
        weth = new MockWETH();
        tokenIn = new MockERC20("Token In", "TIN");

        address factory = address(0xFACA);
        vm.etch(factory, hex"00");
        router = new MockAerodromeRouter(factory, address(weth));
        EntryTokenRegistry registry = new EntryTokenRegistry(owner);

        address pool = address(0xBEEF);
        router.setPoolFor(address(tokenIn), address(weth), false, factory, pool);
        vm.etch(pool, hex"00");

        vm.startPrank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
        registry.setTokenConfig(address(tokenIn), true, false, false, address(0), false, pool);
        mineCore.setEntryTokenRegistry(address(registry));
        vm.stopPrank();

        vm.deal(address(weth), 100 ether);
    }

    function _proxyAdminOf(address proxy) internal view returns (ProxyAdmin admin) {
        admin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT)))));
    }

    function testTakeoversStartPausedByDefault() public {
        assertTrue(mineCore.takeoversPaused());
    }

    function testGuardianCannotUnpauseBeforeGenesisKingClaimCollected() public {
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisKingClaimNotCollected.selector);
        mineCore.setTakeoversPaused(false);
        assertTrue(mineCore.takeoversPaused());
    }

    function testGuardianCanUnpauseAfterGenesisKingClaimCollected() public {
        mineCore.setGenesisKingClaimCollectedForTest(true);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
        assertFalse(mineCore.takeoversPaused());
    }

    function testGetTakeoverPriceGenesisIsFloor() public {
        assertEq(mineCore.getCurrentTakeoverPrice(), Constants.TAKEOVER_PRICE_FLOOR);
        assertEq(mineCore.getTakeoverPrice(block.timestamp + 1 days), Constants.TAKEOVER_PRICE_FLOOR);
    }

    function testGetTakeoverPriceLinearDecayFromReference() public {
        uint256 start = block.timestamp;
        uint256 referencePrice = 1 ether;

        mineCore.setReignStateForTest(alice, start, referencePrice, start);

        // At start: reference price.
        assertEq(mineCore.getTakeoverPrice(start), referencePrice);

        // Halfway through decay window.
        // New formula: price = max(floor, referencePrice * (1 - t / decayPeriod))
        uint256 tHalf = start + (Constants.TAKEOVER_DECAY_PERIOD / 2);
        uint256 decayed = (referencePrice * (Constants.TAKEOVER_DECAY_PERIOD / 2)) / Constants.TAKEOVER_DECAY_PERIOD;
        uint256 expectedHalf = referencePrice - decayed;
        if (expectedHalf < Constants.TAKEOVER_PRICE_FLOOR) expectedHalf = Constants.TAKEOVER_PRICE_FLOOR;
        assertEq(mineCore.getTakeoverPrice(tHalf), expectedHalf);

        // At/after full window: floor.
        uint256 tEnd = start + Constants.TAKEOVER_DECAY_PERIOD;
        assertEq(mineCore.getTakeoverPrice(tEnd), Constants.TAKEOVER_PRICE_FLOOR);
        assertEq(mineCore.getTakeoverPrice(tEnd + 1), Constants.TAKEOVER_PRICE_FLOOR);
    }

    function testSetTakeoversPausedOnlyGuardianAndClampsAccrual() public {
        // Ensure block.timestamp is safely > 100 for the test setup arithmetic.
        vm.warp(1000);

        // Alice reigns with a realistic accrual cursor (= reign start).
        mineCore.setReignStateForTest(alice, block.timestamp - 100, 1 ether, block.timestamp - 100);
        mineCore.setGenesisKingClaimCollectedForTest(true);

        // Non-guardian cannot toggle.
        vm.prank(bob);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        mineCore.setTakeoversPaused(false);

        // Unpause to the live state; with no prior tracked pause the cursor is unchanged.
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
        assertFalse(mineCore.takeoversPaused());
        uint256 cursorBefore = mineCore.currentReignLastAccrualTime();
        assertEq(cursorBefore, 900, "unpause without a tracked pause preserves the cursor");

        // audit F-2: pausing mid-reign must NOT advance the cursor (pre-pause accrual is preserved).
        vm.warp(block.timestamp + 123); // t = 1123
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);
        assertTrue(mineCore.takeoversPaused());
        assertEq(mineCore.currentReignLastAccrualTime(), cursorBefore, "pause must not discard accrual");

        // audit F-2: unpause advances the cursor by exactly the paused duration (only paused time excluded).
        vm.warp(block.timestamp + 50); // paused 50s; t = 1173
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
        assertEq(mineCore.currentReignLastAccrualTime(), cursorBefore + 50, "unpause excludes only paused time");
    }

    function testSetTakeoversPaused_doubleToggleClampNeverGoesBackwards() public {
        vm.warp(1000);

        mineCore.setReignStateForTest(alice, block.timestamp - 100, 1 ether, block.timestamp - 100);
        mineCore.setGenesisKingClaimCollectedForTest(true);

        // Unpause to the live state; cursor unchanged (no prior tracked pause).
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
        uint256 c0 = mineCore.currentReignLastAccrualTime();
        assertEq(c0, 900, "cursor preserved through initial unpause");

        // audit F-2: pause must not advance the cursor.
        vm.warp(1100);
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);
        uint256 c1 = mineCore.currentReignLastAccrualTime();
        assertEq(c1, c0, "pause does not advance the cursor");
        assertGe(c1, c0);

        // audit F-2: unpause after 100s paused advances the cursor by exactly that duration.
        vm.warp(1200);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
        uint256 c2 = mineCore.currentReignLastAccrualTime();
        assertEq(c2, c0 + 100, "unpause advances by the paused duration only");
        assertGe(c2, c1);

        // Pause again: cursor still does not move.
        vm.warp(1300);
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);
        uint256 c3 = mineCore.currentReignLastAccrualTime();
        assertEq(c3, c2, "pause does not advance the cursor");
        assertGe(c3, c2);

        // Monotonic non-decreasing throughout (never goes backwards).
        assertGe(c3, c0);
    }

    function testPauseDoesNotFreezeTakeoverPriceDecay() public {
        vm.warp(1000);

        mineCore.setReignStateForTest(alice, block.timestamp, 1 ether, block.timestamp);
        mineCore.setGenesisKingClaimCollectedForTest(true);

        vm.prank(owner);
        mineCore.setTakeoversPaused(false);

        vm.warp(1100);
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        vm.warp(1100 + Constants.TAKEOVER_DECAY_PERIOD + 1);
        assertEq(mineCore.getTakeoverPrice(block.timestamp), Constants.TAKEOVER_PRICE_FLOOR);
    }

    function testTakeoverRevertsWhileGenesisPaused() public {
        uint256 floor = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, floor);

        vm.prank(alice);
        vm.expectRevert(Errors.TakeoversPaused.selector);
        mineCore.takeover{value: floor}(type(uint256).max);
    }

    function testSetLockingPausedRevertsWhenFurnaceNotSet() public {
        // New MineCore instance with no Furnace wired.
        MineCoreHarness mc;
        (,,, mc) = _deployFreshMineCoreBundle(owner);

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        mc.setLockingPaused(true);
    }

    function testSetLockingPausedForwardsToFurnaceWhenGuardianIsMineCore() public {
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));

        vm.startPrank(owner);
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));

        // Wire Furnace into MineCore.
        mineCore.setFurnace(address(furnace));

        // Complete reciprocal wiring for the bundle.
        ve.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        vm.stopPrank();

        // W-01: setMineCore atomically sets guardian = mineCore, so forwarding works immediately.
        vm.prank(owner);
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(owner);
        mineCore.setLockingPaused(false);
        assertTrue(!furnace.lockingPaused());
    }

    function testCurrentGuardianCanRotateGuardianAfterGenesisClaimConsumed() public {
        // Full reciprocal wiring (furnace, registry, helper, hub) for a realistic deployment shape.
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        address mineMarket = address(this);
        vm.prank(owner);
        furnace.setFurnaceQuoter(address(quoter));

        address registryAddr = _deployValidRegistry();
        address furnaceRegistryAddr = _deployValidRegistry();
        address helperAddr = address(new ClaimAllHelper(address(royalties), address(mineCore)));
        address hubAddr = address(new MockContract());
        MockGenesisGuardian launchController = _newGenesisGuardian();

        vm.startPrank(owner);
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(furnaceRegistryAddr);
        furnace.setMineMarket(mineMarket);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        royalties.setClaimAllHelper(helperAddr);

        // MineCore reciprocals must be wired BEFORE Furnace.setDelegationHub so
        // FurnaceGuardHelper.requireCanonicalDelegationHub can confirm
        // mineCore.{furnace,delegationHub,claim,ve} all match.
        mineCore.setFurnace(address(furnace));
        mineCore.setEntryTokenRegistry(registryAddr);
        mineCore.setClaimAllHelper(helperAddr);
        mineCore.setDelegationHub(hubAddr);
        furnace.setDelegationHub(hubAddr);
        mineCore.setGuardian(address(launchController));

        vm.stopPrank();

        mineCore.setGenesisKingClaimCollectedForTest(true);

        address newGuardian = address(0xCAFE);
        vm.prank(address(launchController));
        mineCore.setGuardian(newGuardian);
        assertEq(mineCore.guardian(), newGuardian);
    }

    function testCurrentGuardianCanRotateGuardianWhileTakeoversPausedAfterGenesisClaimConsumed() public {
        // Full reciprocal wiring (furnace, registry, helper, hub) for a realistic deployment shape.
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        address mineMarket = address(this);
        vm.prank(owner);
        furnace.setFurnaceQuoter(address(quoter));

        address registryAddr = _deployValidRegistry();
        address furnaceRegistryAddr = _deployValidRegistry();
        address helperAddr = address(new ClaimAllHelper(address(royalties), address(mineCore)));
        address hubAddr = address(new MockContract());
        MockGenesisGuardian launchController = _newGenesisGuardian();

        vm.startPrank(owner);
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(furnaceRegistryAddr);
        furnace.setMineMarket(mineMarket);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        royalties.setClaimAllHelper(helperAddr);

        // MineCore reciprocals must be wired BEFORE Furnace.setDelegationHub.
        mineCore.setFurnace(address(furnace));
        mineCore.setEntryTokenRegistry(registryAddr);
        mineCore.setClaimAllHelper(helperAddr);
        mineCore.setDelegationHub(hubAddr);
        furnace.setDelegationHub(hubAddr);
        mineCore.setGuardian(address(launchController));

        vm.stopPrank();

        mineCore.setGenesisKingClaimCollectedForTest(true);

        vm.prank(address(launchController));
        mineCore.setTakeoversPaused(true);
        assertTrue(mineCore.takeoversPaused());

        address newGuardian = address(0xBEEF);
        vm.prank(address(launchController));
        mineCore.setGuardian(newGuardian);
        assertEq(mineCore.guardian(), newGuardian);
        assertTrue(mineCore.takeoversPaused(), "rotation must not unpause takeovers");
    }

    function testOwnerCanRotateGuardianWhileTakeoversPausedAfterGenesisClaimConsumed() public {
        // Full reciprocal wiring (furnace, registry, helper, hub) for a realistic deployment shape.
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        address mineMarket = address(this);
        vm.prank(owner);
        furnace.setFurnaceQuoter(address(quoter));

        address registryAddr = _deployValidRegistry();
        address furnaceRegistryAddr = _deployValidRegistry();
        address helperAddr = address(new ClaimAllHelper(address(royalties), address(mineCore)));
        address hubAddr = address(new MockContract());
        MockGenesisGuardian launchController = _newGenesisGuardian();

        vm.startPrank(owner);
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(furnaceRegistryAddr);
        furnace.setMineMarket(mineMarket);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        royalties.setClaimAllHelper(helperAddr);

        // MineCore reciprocals must be wired BEFORE Furnace.setDelegationHub.
        mineCore.setFurnace(address(furnace));
        mineCore.setEntryTokenRegistry(registryAddr);
        mineCore.setClaimAllHelper(helperAddr);
        mineCore.setDelegationHub(hubAddr);
        furnace.setDelegationHub(hubAddr);
        mineCore.setGuardian(address(launchController));

        vm.stopPrank();

        mineCore.setGenesisKingClaimCollectedForTest(true);

        vm.prank(address(launchController));
        mineCore.setTakeoversPaused(true);
        assertTrue(mineCore.takeoversPaused());

        address newGuardian = address(0xBEEF);
        vm.prank(owner);
        mineCore.setGuardian(newGuardian);
        assertEq(mineCore.guardian(), newGuardian);
        assertTrue(mineCore.takeoversPaused(), "rotation must not unpause takeovers");
    }

    function testSetGuardianPreGenesisOnlyOwnerAndNonZero() public {
        MockGenesisGuardian launchController = _newGenesisGuardian();

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setGuardian(address(launchController));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        mineCore.setGuardian(address(0));

        // Pre-genesis the guardian handoff must go to a contract LaunchController-style guardian.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        mineCore.setGuardian(address(0xCAFE));

        vm.prank(owner);
        mineCore.setGuardian(address(launchController));
        assertEq(mineCore.guardian(), address(launchController));
    }

    function testPreGenesisCurrentGuardianCannotInstallContractGuardianWhenOwnerDiffers() public {
        address newOwner = address(0xBEEF);
        MockGenesisGuardian launchController = _newGenesisGuardian();

        vm.prank(owner);
        mineCore.transferOwnership(newOwner);

        vm.prank(newOwner);
        mineCore.acceptOwnership();

        assertEq(mineCore.owner(), newOwner);
        assertEq(mineCore.guardian(), owner);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setGuardian(address(launchController));

        vm.prank(newOwner);
        mineCore.setGuardian(address(launchController));
        assertEq(mineCore.guardian(), address(launchController));
    }

    function testPreGenesisContractInitialOwnerCanInstallContractGuardian() public {
        MockContract contractOwner = new MockContract();
        ClaimToken splitOwnerClaim;
        MineCoreHarness splitOwnerCore;
        (splitOwnerClaim,,, splitOwnerCore) = _deployFreshMineCoreBundle(address(contractOwner));

        MockGenesisGuardian splitOwnerLaunchController =
            _newGenesisGuardian(address(splitOwnerCore), address(splitOwnerClaim));

        assertEq(splitOwnerCore.owner(), address(contractOwner));
        assertEq(splitOwnerCore.guardian(), address(contractOwner));

        vm.prank(address(contractOwner));
        splitOwnerCore.setGuardian(address(splitOwnerLaunchController));
        assertEq(splitOwnerCore.guardian(), address(splitOwnerLaunchController));
    }

    function testPreGenesisGuardianRejectsNonLaunchControllerLikeContract() public {
        MockContract nonGuardian = new MockContract();
        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setGuardian(address(nonGuardian));
    }

    function testPreGenesisGuardianRejectsMineCoreRootMismatch() public {
        MockGenesisGuardian launchController = _newGenesisGuardian(address(0xBEEF), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setGuardian(address(launchController));
    }

    function testPreGenesisGuardianRejectsClaimRootMismatch() public {
        MockGenesisGuardian launchController = _newGenesisGuardian(address(mineCore), address(0xCAFE));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setGuardian(address(launchController));
    }

    function testPreGenesisGuardianRotationLocksAfterContractHandoff() public {
        MockGenesisGuardian launchController = _newGenesisGuardian();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        MockGenesisGuardian anotherGuardianA = new MockGenesisGuardian();
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisGuardianLocked.selector);
        mineCore.setGuardian(address(anotherGuardianA));

        MockGenesisGuardian anotherGuardianB = new MockGenesisGuardian();
        vm.prank(address(launchController));
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setGuardian(address(anotherGuardianB));
    }

    function testPostGenesisGuardianCanRotateAfterClaimCollection() public {
        MockGenesisGuardian launchController = _newGenesisGuardian();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);
        launchController.collectGenesisKingClaim(mineCore, address(launchController));

        vm.prank(owner);
        mineCore.setGuardian(address(0xCAFE));
        assertEq(mineCore.guardian(), address(0xCAFE));
    }

    function testPostGenesisGuardianRejectsDelegatedEOA() public {
        // Bring MineCore into the post-genesis branch.
        MockGenesisGuardian launchController = _newGenesisGuardian();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);
        launchController.collectGenesisKingClaim(mineCore, address(launchController));

        // Etch a 7702 designator (EF0100 || 20-byte target) at a candidate guardian.
        address delegatedGuardian = address(0x77027702);
        vm.etch(delegatedGuardian, abi.encodePacked(hex"ef0100", address(this)));
        assertEq(delegatedGuardian.code.length, 23, "7702 designator must be exactly 23 bytes");

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        mineCore.setGuardian(delegatedGuardian);
    }

    function testSetFurnaceAndEntryTokenRegistryOnlyOwnerAndNonZero() public {
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        vm.prank(owner);
        furnace.setFurnaceQuoter(address(quoter));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        mineCore.setFurnace(address(furnace));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        mineCore.setFurnace(address(0));

        vm.prank(owner);
        mineCore.setFurnace(address(furnace));
        assertEq(address(mineCore.furnace()), address(furnace));

        address registry = address(new MockEntryTokenRegistry());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        mineCore.setEntryTokenRegistry(registry);

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        mineCore.setEntryTokenRegistry(address(0));

        vm.prank(owner);
        mineCore.setEntryTokenRegistry(registry);
        assertEq(mineCore.entryTokenRegistry(), registry);
    }

    function testTakeoverWithTokenRevertsIfRegistryRouterConfigNotSet() public {
        // Wire a registry mock that returns an all-zero router config.
        address registry = address(new MockEntryTokenRegistry());
        vm.prank(owner);
        mineCore.setEntryTokenRegistry(registry);
        _unpauseTakeovers();

        // Ensure we are past emission start so takeover price is in its normal regime.
        vm.warp(mineCore.emissionStartTime() + 1);

        // minEthOut > 0 check fires before the registry router check.
        vm.expectRevert(Errors.AmountZero.selector);
        vm.prank(alice);
        mineCore.takeoverWithToken(address(0xBEEF), 1, 0, type(uint256).max);
    }

    function testMineCoreQuoterRevertsIfRegistryRouterConfigNotSet() public {
        MineCoreQuoter quoter = new MineCoreQuoter(address(mineCore));

        address registry = address(new MockEntryTokenRegistry());
        vm.prank(owner);
        mineCore.setEntryTokenRegistry(registry);
        _unpauseTakeovers();

        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        quoter.quoteTakeoverWithToken(address(0xBEEF), 1);

        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        quoter.resolveTakeoverRoute(address(0xBEEF));
    }

    function testProxyInitializeSucceedsBeforeClaimTokenMineCoreIsWired() public {
        ClaimToken freshClaim = new ClaimToken(owner);
        MockVe freshVe = new MockVe();
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        freshVe.setClaimToken(address(freshClaim));

        MineCore impl = new MineCore(address(freshClaim), address(freshVe), address(freshRoyalties), address(0));
        MineCoreProxy proxy = new MineCoreProxy(address(impl), owner, abi.encodeCall(MineCore.initialize, (owner)));
        MineCoreHarness proxyCore = MineCoreHarness(payable(address(proxy)));

        assertEq(freshClaim.mineCore(), address(0), "ClaimToken should still be unwired at proxy init time");
        assertEq(proxyCore.owner(), owner, "proxy initialize should succeed before ClaimToken.setMineCore");
        assertEq(proxyCore.guardian(), owner, "initializer should set guardian");

        vm.prank(owner);
        freshClaim.setMineCore(address(proxyCore));
        assertEq(freshClaim.mineCore(), address(proxyCore), "post-init wiring should still succeed");
    }

    function testProxyInitializeRevertsIfClaimTokenMineCoreAlreadyPointsElsewhere() public {
        ClaimToken freshClaim = new ClaimToken(owner);
        MockVe freshVe = new MockVe();
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        freshVe.setClaimToken(address(freshClaim));

        MineCoreHarness foreignCore =
            new MineCoreHarness(address(freshClaim), address(freshVe), address(freshRoyalties), owner);
        vm.prank(owner);
        freshClaim.setMineCore(address(foreignCore));

        MineCore impl = new MineCore(address(freshClaim), address(freshVe), address(freshRoyalties), address(0));
        vm.expectRevert(Errors.WiringMismatch.selector);
        new MineCoreProxy(address(impl), owner, abi.encodeCall(MineCore.initialize, (owner)));
    }

    function testImplementationConstructorSelfLocksProxylessInitialize() public {
        ClaimToken freshClaim = new ClaimToken(owner);
        MockVe freshVe = new MockVe();
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        freshVe.setClaimToken(address(freshClaim));

        MineCore impl = new MineCore(address(freshClaim), address(freshVe), address(freshRoyalties), address(0));

        vm.expectRevert(UpgradeableProtocolBase.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    function testUpgradeAndCallCannotReinitializeInitializedProxy() public {
        ClaimToken freshClaim = new ClaimToken(owner);
        MockVe freshVe = new MockVe();
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        freshVe.setClaimToken(address(freshClaim));

        MineCore impl = new MineCore(address(freshClaim), address(freshVe), address(freshRoyalties), address(0));
        MineCoreProxy proxy = new MineCoreProxy(address(impl), owner, abi.encodeCall(MineCore.initialize, (owner)));
        ProxyAdmin admin = _proxyAdminOf(address(proxy));

        MineCore nextImpl = new MineCore(address(freshClaim), address(freshVe), address(freshRoyalties), address(0));

        vm.prank(owner);
        vm.expectRevert(UpgradeableProtocolBase.InvalidInitialization.selector);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            address(nextImpl),
            abi.encodeCall(MineCore.initialize, (bob))
        );
    }

    function testTransparentProxyOwnerIsNotRuntimeAdmin() public {
        ClaimToken freshClaim = new ClaimToken(owner);
        MockVe freshVe = new MockVe();
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        freshVe.setClaimToken(address(freshClaim));

        MineCore impl = new MineCore(address(freshClaim), address(freshVe), address(freshRoyalties), address(0));
        MineCoreProxy proxy = new MineCoreProxy(address(impl), owner, abi.encodeCall(MineCore.initialize, (owner)));
        MineCoreHarness proxyCore = MineCoreHarness(payable(address(proxy)));
        ProxyAdmin admin = _proxyAdminOf(address(proxy));

        assertEq(admin.owner(), owner, "proxy admin ownership should live on the dedicated ProxyAdmin");

        vm.prank(owner);
        assertEq(proxyCore.owner(), owner, "EOA owner should still reach implementation selectors");

        vm.prank(address(admin));
        vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        proxyCore.owner();
    }

    function testCollectGenesisKingClaimGuardsAndMintsExpected() public {
        MockGenesisGuardian launchController = _newGenesisGuardian();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();

        // Must be guardian.
        vm.warp(end);
        vm.prank(bob);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        mineCore.collectGenesisKingClaim(bob);

        // Reverts before the window ends.
        vm.warp(end - 1);
        vm.expectRevert(Errors.GenesisWindowNotEnded.selector);
        launchController.collectGenesisKingClaim(mineCore, alice);

        // Succeeds at end.
        vm.warp(end);
        uint256 expected = _kingEmitted(0, mineCore.GENESIS_ACCRUAL_DURATION());

        uint256 minted = launchController.collectGenesisKingClaim(mineCore, alice);
        assertEq(minted, expected);
        assertEq(claim.balanceOf(alice), expected);
        assertEq(mineCore.genesisKingClaimMinted(), expected);
        assertTrue(mineCore.genesisKingClaimCollected());

        // One-shot.
        vm.expectRevert(Errors.GenesisKingClaimAlreadyCollected.selector);
        launchController.collectGenesisKingClaim(mineCore, alice);
    }

    function testCollectGenesisKingClaimRevertsOnZeroAddress() public {
        MockGenesisGuardian launchController = _newGenesisGuardian();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        vm.expectRevert(Errors.ZeroAddress.selector);
        launchController.collectGenesisKingClaim(mineCore, address(0));
    }

    function testCollectGenesisKingClaimRejectsEoaGuardian() public {
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        mineCore.collectGenesisKingClaim(alice);
    }

    function testCollectGenesisKingClaimRejectsNonCanonicalContractGuardianUntilOwnerHandoff() public {
        MockContract contractOwner = new MockContract();
        ClaimToken splitOwnerClaim;
        MineCoreHarness splitOwnerCore;
        (splitOwnerClaim,,, splitOwnerCore) = _deployFreshMineCoreBundle(address(contractOwner));

        uint256 end = splitOwnerCore.emissionStartTime() + splitOwnerCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        vm.expectRevert(Errors.WiringMismatch.selector);
        contractOwner.collectGenesisKingClaim(splitOwnerCore, alice);

        MockGenesisGuardian splitOwnerLaunchController =
            _newGenesisGuardian(address(splitOwnerCore), address(splitOwnerClaim));

        vm.prank(address(contractOwner));
        splitOwnerCore.setGuardian(address(splitOwnerLaunchController));

        uint256 expected = _kingEmitted(0, splitOwnerCore.GENESIS_ACCRUAL_DURATION());
        uint256 minted = splitOwnerLaunchController.collectGenesisKingClaim(splitOwnerCore, alice);
        assertEq(minted, expected);
        assertEq(splitOwnerClaim.balanceOf(alice), expected);
        assertTrue(splitOwnerCore.genesisKingClaimCollected());
    }

    function testClaimTokenMineCoreResetDoesNotInvalidateCanonicalGuardianFingerprint() public {
        MockGenesisGuardian launchController = _newGenesisGuardian();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        MockClaimTokenMineCoreResetTarget foreignCore = new MockClaimTokenMineCoreResetTarget(address(claim));
        vm.prank(owner);
        claim.setMineCore(address(foreignCore));

        // Canonical-guardian detection is based on the LaunchController's immutable MineCore + CLAIM
        // roots, not on the mutable ClaimToken.mineCore() pointer. The pre-genesis lock therefore
        // remains engaged even after the mint authority has drifted away.
        MockGenesisGuardian replacement = _newGenesisGuardian();
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisGuardianLocked.selector);
        mineCore.setGuardian(address(replacement));

        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        vm.expectRevert(Errors.OnlyMineCore.selector);
        launchController.collectGenesisKingClaim(mineCore, alice);

        assertFalse(mineCore.genesisKingClaimCollected(), "mint revert must roll back the one-shot flag");
        assertEq(mineCore.guardian(), address(launchController), "canonical guardian fingerprint should remain stable");
    }

    function testTakeoverWithTokenAndDeadlineUsesCallerSuppliedDeadline() public {
        DelegationHub hub = new DelegationHub();
        _wireCanonicalFurnaceWithHub(address(hub));
        (MockAerodromeRouter router,, MockERC20 tokenIn) = _configureTokenTakeoverRoute();
        _unpauseTakeovers();

        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(mineCore), 1 ether);

        vm.warp(mineCore.emissionStartTime() + 1);
        uint256 deadline = block.timestamp + 77;
        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.prank(alice);
        mineCore.takeoverWithTokenAndDeadline(address(tokenIn), 1 ether, floor, type(uint256).max, deadline);

        assertEq(router.lastDeadline(), deadline);
        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.currentReignId(), 1);
    }

    function testTakeoverWithTokenAndDeadlineRevertsWhenExpired() public {
        _unpauseTakeovers();
        vm.warp(mineCore.emissionStartTime() + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.DeadlineExpired.selector);
        mineCore.takeoverWithTokenAndDeadline(address(0xBEEF), 1 ether, 1, type(uint256).max, block.timestamp - 1);
    }

    function testRescueClaimOnlyTransfersSurplusOverPendingKingClaim() public {
        uint256 tracked = 4 ether;
        uint256 surplus = 6 ether;
        address receiver = address(0xCAFE);

        mineCore.setPendingKingClaimForTest(alice, tracked);

        vm.prank(address(mineCore));
        claim.mint(address(mineCore), tracked + surplus);

        vm.prank(owner);
        mineCore.rescueClaim(receiver);

        assertEq(claim.balanceOf(receiver), surplus);
        assertEq(claim.balanceOf(address(mineCore)), tracked);
        assertEq(mineCore.pendingKingClaim(alice), tracked);
        assertEq(mineCore.totalPendingKingClaim(), tracked);
    }

    function testFreezeConfigBlocksSetClaimAllHelperDirectly() public {
        DelegationHub hub = new DelegationHub();
        _wireCanonicalFurnaceWithHub(address(hub));

        ClaimAllHelper helper = new ClaimAllHelper(address(royalties), address(mineCore));
        ClaimAllHelper helper2 = new ClaimAllHelper(address(royalties), address(mineCore));

        vm.startPrank(owner);
        royalties.setClaimAllHelper(address(helper));
        mineCore.setClaimAllHelper(address(helper));
        mineCore.freezeConfig();
        vm.expectRevert(Errors.ConfigFrozen.selector);
        mineCore.setClaimAllHelper(address(helper2));
        vm.stopPrank();

        assertTrue(mineCore.configFrozen());
        assertEq(mineCore.claimAllHelper(), address(helper));
    }

    function testFreezeConfigBlocksSetFurnaceButNotEntryTokenRegistry() public {
        DelegationHub hub = new DelegationHub();
        Furnace currentFurnace = _wireCanonicalFurnaceWithHub(address(hub));
        ClaimAllHelper helper = new ClaimAllHelper(address(royalties), address(mineCore));

        address registryA = address(new MockEntryTokenRegistry());
        address registryB = address(new MockEntryTokenRegistry());

        vm.startPrank(owner);
        royalties.setClaimAllHelper(address(helper));
        mineCore.setClaimAllHelper(address(helper));
        mineCore.setEntryTokenRegistry(registryA);
        mineCore.freezeConfig();

        Furnace replacement = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        vm.expectRevert(Errors.ConfigFrozen.selector);
        mineCore.setFurnace(address(replacement));

        mineCore.setEntryTokenRegistry(registryB);
        vm.stopPrank();

        assertEq(mineCore.entryTokenRegistry(), registryB, "entryTokenRegistry should remain mutable post-freeze");
        assertEq(address(mineCore.furnace()), address(currentFurnace), "canonical furnace pointer must stay frozen");
    }

    function testTakeoverForRevertsWhenMineCoreDelegationHubDiffersFromCanonicalFurnaceHub() public {
        DelegationHub canonicalHub = new DelegationHub();
        DelegationHub evilHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(evilHub));

        _unpauseTakeovers();
        _authorize(evilHub, alice, bob, DelegationPermissions.P_TAKEOVER_FOR);

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeoverFor{value: price}(alice, type(uint256).max);

        assertEq(mineCore.currentKing(), address(0));
    }

    function testTakeoverForSucceedsWhenCanonicalHubAgrees() public {
        DelegationHub canonicalHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(canonicalHub));

        _unpauseTakeovers();
        _authorize(
            canonicalHub,
            alice,
            bob,
            DelegationPermissions.P_TAKEOVER_FOR | DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER
        );

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price);

        vm.prank(bob);
        mineCore.takeoverFor{value: price}(alice, type(uint256).max);

        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.currentReignId(), 1);
        assertEq(mineCore.reignEthRecipient(1), bob);
        assertEq(mineCore.reignClaimRecipient(1), bob);
    }

    function testSetCurrentReignRecipientsRevertsWhenMineCoreDelegationHubDiffersFromCanonicalFurnaceHub() public {
        DelegationHub canonicalHub = new DelegationHub();
        DelegationHub evilHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(evilHub));

        mineCore.setReignStateForTest(alice, block.timestamp, 1 ether, block.timestamp);
        _authorize(
            evilHub,
            alice,
            bob,
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT
        );

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setCurrentReignRecipients(bob, bob);

        assertEq(mineCore.reignEthRecipient(0), address(0));
        assertEq(mineCore.reignClaimRecipient(0), address(0));
    }

    function testSetCurrentReignRecipientsRevertsWhenMineCoreFurnaceOmitsRoyaltiesGetterEvenIfHubMatches() public {
        DelegationHub canonicalHub = new DelegationHub();
        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        MockMineCoreFurnaceNoRoyaltiesGetter foreignFurnace = new MockMineCoreFurnaceNoRoyaltiesGetter(
            address(claim), address(ve), address(mineCore), address(canonicalHub)
        );

        vm.prank(owner);
        mineCore.setFurnace(address(foreignFurnace));

        vm.prank(owner);
        mineCore.setDelegationHub(address(canonicalHub));

        mineCore.setReignStateForTest(alice, block.timestamp, 1 ether, block.timestamp);
        _authorize(
            canonicalHub,
            alice,
            bob,
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT
        );

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setCurrentReignRecipients(bob, bob);

        assertEq(mineCore.reignEthRecipient(0), address(0));
        assertEq(mineCore.reignClaimRecipient(0), address(0));
    }

    function testSetCurrentReignRecipientsDelegatedSucceedsWhenCanonicalHubAgrees() public {
        DelegationHub canonicalHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(canonicalHub));

        mineCore.setReignStateForTest(alice, block.timestamp, 1 ether, block.timestamp);
        _authorize(
            canonicalHub,
            alice,
            bob,
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT
        );

        vm.prank(bob);
        mineCore.setCurrentReignRecipients(bob, bob);

        assertEq(mineCore.reignEthRecipient(0), bob);
        assertEq(mineCore.reignClaimRecipient(0), bob);
    }

    function testSetCurrentReignRecipientsDelegatedEmitsRoutingAndSessionUsageEvents() public {
        DelegationHub canonicalHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(canonicalHub));

        mineCore.setReignStateForTest(alice, block.timestamp, 1 ether, block.timestamp);

        vm.prank(alice);
        mineCore.setCurrentReignRecipients(alice, alice);

        _authorize(canonicalHub, alice, bob, DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY);

        vm.recordLogs();
        vm.prank(bob);
        mineCore.setCurrentReignRecipients(bob, alice);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 routingSig = keccak256("ReignRecipientsSet(uint256,address,address,address)");
        bytes32 sessionSig = keccak256("DelegationSessionUsed(address,address,uint8,uint256,uint256,uint256)");

        bool foundRouting;
        bool foundSession;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 4 && logs[i].topics[0] == routingSig) {
                foundRouting = true;
                assertEq(uint256(logs[i].topics[1]), 0, "reignId");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), alice, "king");
                assertEq(address(uint160(uint256(logs[i].topics[3]))), bob, "ethRecipient");

                address claimRecipient = abi.decode(logs[i].data, (address));
                assertEq(claimRecipient, alice, "claimRecipient");
            }

            if (logs[i].topics.length >= 4 && logs[i].topics[0] == sessionSig) {
                foundSession = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice, "user");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), bob, "delegate");
                assertEq(
                    uint256(logs[i].topics[3]),
                    uint256(DelegationActionTypes.MINECORE_SET_REIGN_RECIPIENTS),
                    "actionType"
                );

                (uint256 permsUsed, uint256 refId, uint256 timestamp) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(permsUsed, DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY, "permsUsed");
                assertEq(refId, 0, "refId");
                assertEq(timestamp, block.timestamp, "timestamp");
            }
        }

        assertTrue(foundRouting, "ReignRecipientsSet event not found");
        assertTrue(foundSession, "DelegationSessionUsed event not found");
    }

    function testWithdrawKingBalanceResistsReturnBomb() public {
        ReturnBombReceiverMineCore bomb = new ReturnBombReceiverMineCore(mineCore);

        uint256 amount = 1 ether;
        mineCore.setKingEthBalanceForTest(address(bomb), amount);
        vm.deal(address(mineCore), amount);

        uint256 before = address(bomb).balance;
        bomb.withdrawKing();

        assertEq(address(bomb).balance, before + amount);
        assertEq(mineCore.kingEthBalance(address(bomb)), 0);
    }

    function testWithdrawRefundBalanceResistsReturnBomb() public {
        ReturnBombReceiverMineCore bomb = new ReturnBombReceiverMineCore(mineCore);

        uint256 amount = 0.5 ether;
        mineCore.setRefundEthBalanceForTest(address(bomb), amount);
        vm.deal(address(mineCore), amount);

        uint256 before = address(bomb).balance;
        bomb.withdrawRefundToSelf();

        assertEq(address(bomb).balance, before + amount);
        assertEq(mineCore.refundEthBalance(address(bomb)), 0);
    }

    function _kingRateAt(uint256 t) internal pure returns (uint256) {
        if (t >= Constants.EMISSION_DECAY_PERIOD) return Constants.KING_EMISSION_FLOOR;

        uint256 diff = Constants.KING_EMISSION_LAUNCH_RATE - Constants.KING_EMISSION_FLOOR;
        return Constants.KING_EMISSION_LAUNCH_RATE - (diff * t) / Constants.EMISSION_DECAY_PERIOD;
    }

    function _kingEmitted(uint256 t0, uint256 t1) internal pure returns (uint256) {
        uint256 r0 = _kingRateAt(t0);
        uint256 r1 = _kingRateAt(t1);
        return ((r0 + r1) * (t1 - t0)) / 2;
    }

    // ---- Emission integral precision ----

    /// @dev Verify the trapezoidal integral loses at most 1 wei per accrual interval
    ///      across representative decay-region intervals.
    function testKingEmittedPrecisionBound() public view {
        uint256 start = mineCore.emissionStartTime();
        uint256 D = Constants.EMISSION_DECAY_PERIOD;

        // Test several intervals within the decay region.
        uint256[4] memory offsets = [uint256(0), D / 4, D / 2, D - 1];
        for (uint256 i = 0; i < offsets.length; i++) {
            uint256 ts0 = start + offsets[i];
            uint256 ts1 = ts0 + 60; // 60-second interval

            if (ts1 > start + D) continue;

            uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);

            // Manually compute expected value with higher-precision check.
            uint256 r0 = _kingRateAt(offsets[i]);
            uint256 r1 = _kingRateAt(offsets[i] + 60);
            uint256 exact = (r0 + r1) * 60;
            uint256 expected = exact / 2;

            // Loss is at most 1 wei (the remainder of the final /2 division).
            assertGe(emitted, expected);
            assertLe(emitted, expected + 1);
        }
    }

    /// @dev Verify floor-region emission is exact (no rounding loss).
    function testKingEmittedFloorRegionExact() public view {
        uint256 start = mineCore.emissionStartTime();
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 RF = Constants.KING_EMISSION_FLOOR;

        uint256 ts0 = start + D + 100;
        uint256 ts1 = ts0 + 3600;

        uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);
        assertEq(emitted, RF * 3600);
    }

    // ---- Furnace emission integral coverage ----

    function _furnaceRateAt(uint256 t) internal pure returns (uint256) {
        if (t >= Constants.EMISSION_DECAY_PERIOD) return Constants.FURNACE_EMISSION_FLOOR;

        uint256 diff = Constants.FURNACE_EMISSION_LAUNCH_RATE - Constants.FURNACE_EMISSION_FLOOR;
        return Constants.FURNACE_EMISSION_LAUNCH_RATE - (diff * t) / Constants.EMISSION_DECAY_PERIOD;
    }

    /// @dev Verify the furnace emission trapezoidal integral loses at most 1 wei per interval.
    function testFurnaceEmittedPrecisionBound() public view {
        uint256 start = mineCore.emissionStartTime();
        uint256 D = Constants.EMISSION_DECAY_PERIOD;

        uint256[4] memory offsets = [uint256(0), D / 4, D / 2, D - 1];
        for (uint256 i = 0; i < offsets.length; i++) {
            uint256 ts0 = start + offsets[i];
            uint256 ts1 = ts0 + 60;

            if (ts1 > start + D) continue;

            uint256 emitted = mineCore.furnaceEmittedExposed(ts0, ts1);

            uint256 r0 = _furnaceRateAt(offsets[i]);
            uint256 r1 = _furnaceRateAt(offsets[i] + 60);
            uint256 expected = (r0 + r1) * 60 / 2;

            assertGe(emitted, expected, "furnace emitted too low");
            assertLe(emitted, expected + 1, "furnace emitted too high");
        }
    }

    /// @dev Verify furnace floor-region emission is exact (no rounding loss).
    function testFurnaceEmittedFloorRegionExact() public view {
        uint256 start = mineCore.emissionStartTime();
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 RF = Constants.FURNACE_EMISSION_FLOOR;

        uint256 ts0 = start + D + 100;
        uint256 ts1 = ts0 + 3600;

        uint256 emitted = mineCore.furnaceEmittedExposed(ts0, ts1);
        assertEq(emitted, RF * 3600);
    }

    // ---- Boundary-crossing emission integral coverage ----

    /// @dev Verify king emission integral across the decay→floor boundary.
    ///      The interval [floorTs - 600, floorTs + 600] straddles the transition.
    function testKingEmittedBoundaryCrossing() public view {
        uint256 start = mineCore.emissionStartTime();
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 RF = Constants.KING_EMISSION_FLOOR;
        uint256 floorTs = start + D;

        uint256 ts0 = floorTs - 600;
        uint256 ts1 = floorTs + 600;

        uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);

        // Manually compute: decay part [ts0, floorTs] + floor part [floorTs, ts1].
        uint256 r0 = _kingRateAt(D - 600);
        uint256 decayPart = (r0 + RF) * 600 / 2;
        uint256 floorPart = RF * 600;
        uint256 expected = decayPart + floorPart;

        // At most 1 wei rounding from the /2 in the decay trapezoid.
        assertGe(emitted, expected, "king boundary emitted too low");
        assertLe(emitted, expected + 1, "king boundary emitted too high");
    }

    /// @dev Verify furnace emission integral across the decay→floor boundary.
    function testFurnaceEmittedBoundaryCrossing() public view {
        uint256 start = mineCore.emissionStartTime();
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 RF = Constants.FURNACE_EMISSION_FLOOR;
        uint256 floorTs = start + D;

        uint256 ts0 = floorTs - 600;
        uint256 ts1 = floorTs + 600;

        uint256 emitted = mineCore.furnaceEmittedExposed(ts0, ts1);

        uint256 r0 = _furnaceRateAt(D - 600);
        uint256 decayPart = (r0 + RF) * 600 / 2;
        uint256 floorPart = RF * 600;
        uint256 expected = decayPart + floorPart;

        assertGe(emitted, expected, "furnace boundary emitted too low");
        assertLe(emitted, expected + 1, "furnace boundary emitted too high");
    }

    /// @dev Verify emission integrals return 0 for zero-length and inverted intervals.
    function testEmittedZeroAndInvertedIntervals() public {
        vm.warp(1000);
        MineCoreHarness mc;
        (,,, mc) = _deployFreshMineCoreBundle(owner);
        uint256 start = mc.emissionStartTime();
        uint256 mid = start + Constants.EMISSION_DECAY_PERIOD / 2;

        // Zero-length.
        assertEq(mc.kingEmittedExposed(mid, mid), 0);
        assertEq(mc.furnaceEmittedExposed(mid, mid), 0);

        // Inverted (ts1 < ts0).
        assertEq(mc.kingEmittedExposed(mid, mid - 1), 0);
        assertEq(mc.furnaceEmittedExposed(mid, mid - 1), 0);

        // Before emissionStartTime.
        assertEq(mc.kingEmittedExposed(start - 100, start - 50), 0);
        assertEq(mc.furnaceEmittedExposed(start - 100, start - 50), 0);
    }
}
