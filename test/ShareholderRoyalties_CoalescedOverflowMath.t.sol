// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockContract} from "./mocks/MockContract.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {ShareholderRoyaltiesHarness} from "./mocks/ShareholderRoyaltiesHarness.sol";

contract ShareholderRoyalties_CoalescedOverflowMathTest is Test {
    address internal owner;
    address internal alice;

    function _deployRoyalties() internal returns (ShareholderRoyaltiesHarness royalties, MockVe ve) {
        address mineCore = address(new MockContract());
        address mineMarket = address(new MockContract());
        address furnace = address(new MockContract());
        address claimToken = address(new MockContract());

        ve = new MockVe();
        royalties = new ShareholderRoyaltiesHarness(address(ve), owner);

        ve.setFurnace(furnace);
        ve.setMineMarket(mineMarket);
        ve.setClaimToken(claimToken);

        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(royalties)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, furnace);
    }

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
    }

    function testCoalescedOverflowCanRevertDecayingLockAccrual() public {
        (ShareholderRoyaltiesHarness royalties, MockVe ve) = _deployRoyalties();
        uint40 pinnedTs = uint40(block.timestamp + 100);
        uint256 lockEnd = uint256(pinnedTs) + 50;

        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 1_000e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);

        // Model a coalesced overflow tail whose timestamp stayed pinned at `pinnedTs`
        // while the cumulative indices advanced using later flush timestamps.
        uint256 deltaBeforeExpiry = Constants.ACC * 1;
        uint256 deltaAfterExpiry = Constants.ACC * 2;
        uint256 cumulative = deltaBeforeExpiry + deltaAfterExpiry;
        uint256 timeWeighted = deltaBeforeExpiry * uint256(pinnedTs + 20) + deltaAfterExpiry * uint256(pinnedTs + 80);

        royalties.forceSetOverflowArrayLength(1);
        royalties.setOverflowCheckpointAt(0, pinnedTs, cumulative, timeWeighted);
        royalties.setEthPerVe(cumulative);
        royalties.setEthPerVeTimeWeighted(timeWeighted);

        vm.expectRevert(Errors.InvariantViolation.selector);
        royalties.checkpointUser(alice);
    }

    function testCoalescedOverflowCanSilentlyUnderpayDecayingLock() public {
        (ShareholderRoyaltiesHarness preciseRoyalties, MockVe preciseVe) = _deployRoyalties();
        (ShareholderRoyaltiesHarness coalescedRoyalties, MockVe coalescedVe) = _deployRoyalties();

        uint40 pinnedTs = uint40(block.timestamp + 100);
        uint40 flushBeforeExpiry = pinnedTs + 20;
        uint40 flushAfterExpiry = pinnedTs + 80;
        uint256 lockEnd = uint256(pinnedTs) + 50;

        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 1_000e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        preciseVe.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        coalescedVe.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);

        uint256 deltaBeforeExpiry = Constants.ACC * 2;
        uint256 deltaAfterExpiry = Constants.ACC * 1;
        uint256 cumulative = deltaBeforeExpiry + deltaAfterExpiry;
        uint256 timeWeighted =
            deltaBeforeExpiry * uint256(flushBeforeExpiry) + deltaAfterExpiry * uint256(flushAfterExpiry);

        preciseRoyalties.forceSetOverflowArrayLength(2);
        preciseRoyalties.setOverflowCheckpointAt(
            0, flushBeforeExpiry, deltaBeforeExpiry, deltaBeforeExpiry * uint256(flushBeforeExpiry)
        );
        preciseRoyalties.setOverflowCheckpointAt(1, flushAfterExpiry, cumulative, timeWeighted);
        preciseRoyalties.setEthPerVe(cumulative);
        preciseRoyalties.setEthPerVeTimeWeighted(timeWeighted);
        // Seed `indexedEthOwed` to back the engineered accrual so the per-checkpoint
        // clamp (`wholeAccrued = min(wholeAccrued, indexedEthOwed)`) does not clip to
        // zero. This test asserts the relative behaviour of the time-weighted
        // accrual under coalesced vs precise histories, not the disjoint-buckets
        // accounting; the indexed-bucket headroom is intentionally over-provisioned.
        preciseRoyalties.setIndexedEthOwed(type(uint128).max);

        coalescedRoyalties.forceSetOverflowArrayLength(1);
        coalescedRoyalties.setOverflowCheckpointAt(0, pinnedTs, cumulative, timeWeighted);
        coalescedRoyalties.setEthPerVe(cumulative);
        coalescedRoyalties.setEthPerVeTimeWeighted(timeWeighted);
        coalescedRoyalties.setIndexedEthOwed(type(uint128).max);

        preciseRoyalties.checkpointUser(alice);
        coalescedRoyalties.checkpointUser(alice);

        uint256 preciseClaim = preciseRoyalties.claimableEth(alice);
        uint256 coalescedClaim = coalescedRoyalties.claimableEth(alice);

        assertGt(preciseClaim, 0, "precise history should produce a positive claim");
        assertLt(coalescedClaim, preciseClaim, "coalesced history should underpay this lock");
    }
}
