// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, Vm} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {Events} from "src/lib/Events.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";

contract VeClaimNFT_MetadataRefreshTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();
        srMock.setWiring(mineCore, mineMarket, furnace, address(ve));

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("delegationHub()"), abi.encode(address(0)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(0)));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();

        vm.prank(mineCore);
        claim.mint(alice, 20_000e18);

        vm.prank(alice);
        claim.approve(address(ve), type(uint256).max);
    }

    function _createLock(uint256 amount, uint256 duration, bool autoMax) internal returns (uint256 tokenId) {
        vm.prank(alice);
        tokenId = ve.createLock(amount, duration, autoMax);
    }

    function _assertNoMetadataUpdate(Vm.Log[] memory logs) internal pure {
        bytes32 metadataUpdateTopic = keccak256("MetadataUpdate(uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length != 0) {
                assertTrue(logs[i].topics[0] != metadataUpdateTopic, "Unexpected MetadataUpdate emission");
            }
        }
    }

    function test_addToLock_emitsMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.addToLock(tokenId, 100e18);
    }

    function test_setAutoMax_emitsMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.setAutoMax(tokenId, true);
    }

    function test_extendLockToFor_emitsMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.prank(furnace);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.extendLockToFor(alice, tokenId, block.timestamp + 60 days);
    }

    function test_mergeLocks_emitsMetadataUpdateForDestination() public {
        // v1.0.0: external user merge lives on Furnace (`mergeLocksWithBonus`); the
        // VeClaimNFT lock-math + `MetadataUpdate(intoTokenId)` emit it covers is
        // exercised through the Furnace-only `mergeLocksFor` sibling.
        uint256 fromTokenId = _createLock(1_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(1_000e18, Constants.MAX_LOCK_DURATION, false);

        vm.prank(furnace);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(intoTokenId);
        ve.mergeLocksFor(alice, fromTokenId, intoTokenId);
    }

    function test_setListed_true_emitsMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.prank(mineMarket);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.setListed(tokenId, true);
    }

    function test_setListed_false_emitsMetadataUpdateWhenStateChanges() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.prank(mineMarket);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.setListed(tokenId, false);
    }

    function test_createLock_doesNotEmitMetadataUpdate() public {
        vm.recordLogs();
        vm.prank(alice);
        ve.createLock(1_000e18, 30 days, false);

        _assertNoMetadataUpdate(vm.getRecordedLogs());
    }

    function test_setAutoMax_refreshSameValueTrue_doesNotEmitMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, Constants.MAX_LOCK_DURATION, true);

        vm.recordLogs();
        vm.prank(alice);
        ve.setAutoMax(tokenId, true);

        _assertNoMetadataUpdate(vm.getRecordedLogs());
    }

    function test_extendLockToFor_autoMax_doesNotEmitMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, Constants.MAX_LOCK_DURATION, true);

        vm.recordLogs();
        vm.prank(furnace);
        ve.extendLockToFor(alice, tokenId, block.timestamp + 60 days);

        _assertNoMetadataUpdate(vm.getRecordedLogs());
    }

    function test_setAutoMax_noopFalse_doesNotEmitMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.recordLogs();
        vm.prank(alice);
        ve.setAutoMax(tokenId, false);

        _assertNoMetadataUpdate(vm.getRecordedLogs());
    }

    function test_setListed_false_idempotent_emitsMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        // Redundant delist on an already-delisted lock must still emit
        // MetadataUpdate so indexers have a reconciliation signal even when
        // the original delist event was dropped.
        vm.prank(mineMarket);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.setListed(tokenId, false);
    }

    function test_setListed_false_redundantAfterTrueFalse_emitsMetadataUpdate() public {
        uint256 tokenId = _createLock(1_000e18, 30 days, false);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);
        vm.prank(mineMarket);
        ve.setListed(tokenId, false);

        vm.prank(mineMarket);
        vm.expectEmit(false, false, false, true);
        emit Events.MetadataUpdate(tokenId);
        ve.setListed(tokenId, false);
    }
}
