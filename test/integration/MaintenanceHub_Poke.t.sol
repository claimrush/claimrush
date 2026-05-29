// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {MarketRouter} from "src/MarketRouter.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MaintenanceHub} from "src/MaintenanceHub.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockAerodromeRouter} from "test/mocks/MockAerodromeRouter.sol";
import {MockWETH} from "test/mocks/MockWETH.sol";

// ------------------------------------------------------------
// Local mocks
// ------------------------------------------------------------

contract MockStakingVault_Bounty {
    MockWETH internal immutable weth;

    bool public shouldRevert;
    uint256 public bountyWeth;

    constructor(MockWETH weth_) {
        weth = weth_;
    }

    function setConfig(bool shouldRevert_, uint256 bountyWeth_) external {
        shouldRevert = shouldRevert_;
        bountyWeth = bountyWeth_;
    }

    function harvestFeesToRewards(uint256, uint256) external {
        if (shouldRevert) revert("MockStakingVault: revert");
        uint256 b = bountyWeth;
        if (b > 0) {
            require(weth.transfer(msg.sender, b), "WETH_TRANSFER_FAILED");
        }
    }
}

// ------------------------------------------------------------
// Integration tests
// ------------------------------------------------------------

contract MaintenanceHubPokeIT is Test {
    bytes32 internal constant LOCK_CREATED_SIG = keccak256("LockCreated(address,uint256,uint256,uint256,bool)");
    address internal constant FACTORY = address(0xFACADE);

    ClaimToken public claim;
    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;

    VeClaimNFT internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MarketRouter internal market;

    MockStakingVault_Bounty internal staking;
    MaintenanceHub internal hub;

    address internal alice;
    address internal keeper;

    function setUp() public {
        vm.txGasPrice(0);

        alice = makeAddr("alice");
        keeper = makeAddr("keeper");

        claim = new ClaimToken(address(this));
        vm.mockCall(address(this), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(address(this), abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        claim.setMineCore(address(this));

        weth = new MockWETH();
        router = new MockAerodromeRouter(FACTORY, address(weth));

        registry = new EntryTokenRegistry(address(this));
        vm.etch(FACTORY, hex"00"); // give FACTORY bytecode so NotAContract() check passes
        registry.setRouterConfig(address(router), FACTORY, address(weth), address(claim));

        ve = new VeClaimNFT(address(claim), address(this));
        royalties = new ShareholderRoyalties(address(ve), address(this));
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), address(this)
        );
        market = new MarketRouter(address(claim), address(ve), address(royalties), address(this));

        // Wire core relationships.
        vm.mockCall(address(this), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(this), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(this), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(this), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(address(this), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(bytes4(keccak256("getFurnaceEmissionRateAt(uint256)"))),
            abi.encode(Constants.FURNACE_EMISSION_LAUNCH_RATE)
        );

        furnace.setMineCore(address(this));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        vm.mockCall(address(this), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(address(0)));
        furnace.setEntryTokenRegistry(address(registry));
        furnace.setFurnaceQuoter(address(new FurnaceQuoter(address(furnace))));

        royalties.setWiring(address(this), address(market), address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));

        // Seed Furnace reserve for bonus math.
        uint256 reserveSeed = 50_000_000e18;
        claim.mint(address(furnace), reserveSeed);
        furnace.creditReserve(reserveSeed);

        // MaintenanceHub harvest endpoint (mocked).
        staking = new MockStakingVault_Bounty(weth);

        // Fund bounty source.
        weth.mint(address(staking), 100e18);

        hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        // Opt in so this fixture can exercise grace-window settlement through the permissionless hub.
        market.setSettlementKeeper(address(hub), true);

        // Alice funds + approvals for global offers.
        claim.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        claim.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function testPoke_doesNotBypassSettlementKeeperGraceWhenHubIsNotAllowlisted() public {
        market.setSettlementKeeper(address(hub), false);

        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = offerId;

        vm.prank(keeper);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 1}));

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);

        assertTrue(active, "grace-window offer should remain active when hub is not a settlement keeper");
        assertEq(fundsRemaining, budget, "offer budget should remain escrowed");
        assertEq(claim.balanceOf(address(market)), budget, "escrowed CLAIM should stay in MarketRouter");
    }

    function testPoke_executesAutoFurnace_andSkipsStakingHarvest() public {
        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(
            1, // targetBonusBps (must be > 0 per MED-01)
            budget,
            30 days, // durationSeconds (ignored when createAutoMax=true)
            true, // createAutoMax
            0, // offerTtlSeconds (default)
            0, // destinationLockId (create new)
            0 // slippageBps
        );

        // Configure staking mock bounty (must be ignored: MaintenanceHub does not harvest staking).
        uint256 stakingBounty = 1e18;
        staking.setConfig(false, stakingBounty);

        uint256[] memory ids = new uint256[](2);
        ids[0] = offerId;
        ids[1] = 999_999_999; // invalid id to force a caught revert

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 10});

        uint256 keeperWethBefore = weth.balanceOf(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        hub.poke(args);

        // Offer should be closed and escrow drained.
        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);

        assertFalse(active);
        assertEq(fundsRemaining, 0);
        assertEq(claim.balanceOf(address(market)), 0);

        // No staking harvest via MaintenanceHub, so no bounty should be forwarded.
        assertEq(weth.balanceOf(address(hub)), 0);
        assertEq(weth.balanceOf(keeper), keeperWethBefore);

        // A new lock should be created for Alice, and it should be AutoMax.
        (uint256 tokenId, uint256 amountLocked, uint256 lockEnd, bool autoMax) = _firstLockCreatedFor(alice);
        assertEq(ve.ownerOf(tokenId), alice);
        assertTrue(autoMax);

        // AutoMax lockEnd is effective and should be "now + MAX".
        assertEq(lockEnd, block.timestamp + Constants.MAX_LOCK_DURATION);

        // AutoMax ve math: ve == amount.
        assertEq(ve.veBalanceOf(alice), amountLocked);
    }

    function testPoke_skipsAutoFurnaceDuringGraceWhenHubIsNotSettlementKeeper() public {
        market.setSettlementKeeper(address(hub), false);

        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(
            1, // targetBonusBps (must be > 0 per MED-01)
            budget,
            30 days, // durationSeconds (ignored when createAutoMax=true)
            true, // createAutoMax
            0, // offerTtlSeconds (default)
            0, // destinationLockId (create new)
            0 // slippageBps
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = offerId;

        vm.prank(keeper);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 1}));

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertTrue(active, "grace-window execution should be skipped without the hub allowlist");
        assertEq(fundsRemaining, budget, "best-effort poke should leave the offer untouched");
    }

    function testPoke_flushesPendingShareholderEthBeforeNewAutoFurnaceEntry() public {
        address incumbent = makeAddr("incumbent");
        uint256 incumbentAmount = 10_000e18;
        _mintApproveAndCreateLock(incumbent, incumbentAmount, Constants.MAX_LOCK_DURATION, true);

        uint256 backlogLocks = Constants.MAX_SLOPE_CHANGES_PER_CALL + 1;
        _seedExpiredSlopeBacklog(backlogLocks, Constants.MIN_LOCK_AMOUNT);

        vm.deal(address(this), 1 ether);
        royalties.addPendingShareholderETH{value: 1 ether}(1);

        // addPendingShareholderETH flushes immediately, so most ETH is already indexed.
        assertLe(royalties.pendingShareholderETH(), 100_000, "dust after immediate flush");

        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(
            1,
            budget,
            30 days,
            true,
            0, // offerTtlSeconds (default)
            0,
            0 // slippageBps
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = offerId;

        vm.prank(keeper);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 1}));

        royalties.checkpointUser(incumbent);
        royalties.checkpointUser(alice);

        (uint256 incumbentClaimable,,) = royalties.getShareholderState(incumbent);
        (uint256 aliceClaimable,,) = royalties.getShareholderState(alice);

        assertEq(aliceClaimable, 0, "new auto-furnace entrant captured pre-existing pending ETH");
        assertApproxEqAbs(incumbentClaimable, 1 ether, 100_000, "incumbent should receive pre-existing pending ETH");
        assertLe(royalties.pendingShareholderETH(), 100_000, "pending should be flushed before entry");

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertFalse(active);
        assertEq(fundsRemaining, 0);
    }

    function testPoke_bestEffort_doesNotRevert_whenTradingPaused() public {
        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(
            1,
            budget,
            30 days,
            true,
            0, // offerTtlSeconds (default)
            0,
            0 // slippageBps
        );

        // Pause trading so executeAutoFurnace will revert.
        market.pauseTrading(true);

        staking.setConfig(false, 1e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = offerId;

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 1});

        uint256 keeperWethBefore = weth.balanceOf(keeper);

        // MUST NOT revert.
        vm.prank(keeper);
        hub.poke(args);

        // Offer should remain active (no state changes from the reverted executeAutoFurnace).
        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);

        assertTrue(active);
        assertEq(fundsRemaining, budget);

        // No staking harvest via MaintenanceHub, so bounty remains unchanged.
        assertEq(weth.balanceOf(address(hub)), 0);
        assertEq(weth.balanceOf(keeper), keeperWethBefore);
    }

    function _mintApproveAndCreateLock(address user, uint256 amount, uint256 duration, bool autoMax)
        internal
        returns (uint256 tokenId)
    {
        claim.mint(user, amount);

        vm.startPrank(user);
        claim.approve(address(furnace), amount);
        tokenId = furnace.enterWithClaim(amount, 0, duration, autoMax, 1);
        vm.stopPrank();
    }

    function _seedExpiredSlopeBacklog(uint256 totalLocks, uint256 perLock) internal {
        address[9] memory users = [
            makeAddr("backlog-user-1"),
            makeAddr("backlog-user-2"),
            makeAddr("backlog-user-3"),
            makeAddr("backlog-user-4"),
            makeAddr("backlog-user-5"),
            makeAddr("backlog-user-6"),
            makeAddr("backlog-user-7"),
            makeAddr("backlog-user-8"),
            makeAddr("backlog-user-9")
        ];

        uint256 remaining = totalLocks;
        uint256 uniqueDurationOffset = 0;
        uint256 startTs = block.timestamp;

        for (uint256 u = 0; u < users.length; ++u) {
            if (remaining == 0) break;

            uint256 count = remaining > Constants.MAX_VE_NFTS_PER_USER ? Constants.MAX_VE_NFTS_PER_USER : remaining;
            remaining -= count;

            claim.mint(users[u], perLock * count);

            vm.startPrank(users[u]);
            claim.approve(address(furnace), perLock * count);
            for (uint256 i = 0; i < count; ++i) {
                furnace.enterWithClaim(perLock, 0, Constants.MIN_LOCK_DURATION + uniqueDurationOffset, false, 1);
                uniqueDurationOffset += 1;
            }
            vm.stopPrank();
        }

        assertEq(remaining, 0, "failed to seed expired slope backlog");
        vm.warp(startTs + Constants.MIN_LOCK_DURATION + totalLocks + 1);
    }

    function _firstLockCreatedFor(address expectedUser)
        internal
        returns (uint256 tokenId, uint256 amount, uint256 lockEnd, bool autoMax)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(ve)) continue;
            if (l.topics.length < 3) continue;
            if (l.topics[0] != LOCK_CREATED_SIG) continue;

            address user = address(uint160(uint256(l.topics[1])));
            if (user != expectedUser) continue;

            tokenId = uint256(l.topics[2]);
            (amount, lockEnd, autoMax) = abi.decode(l.data, (uint256, uint256, bool));
            return (tokenId, amount, lockEnd, autoMax);
        }

        assertTrue(false, "no LockCreated event found");
    }
}
