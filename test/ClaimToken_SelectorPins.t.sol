// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";

interface IMineCoreSelectorPins {
    function claim() external view returns (address);
    function emissionStartTime() external view returns (uint256);
    function GENESIS_ACCRUAL_DURATION() external view returns (uint256);
}

contract ClaimTokenSelectorHarness is ClaimToken {
    constructor() ClaimToken(address(0xA11CE)) {}

    function selClaim() external pure returns (bytes4) {
        return _SEL_CLAIM;
    }

    function selEmissionStartTime() external pure returns (bytes4) {
        return _SEL_EMISSION_START_TIME;
    }

    function selGenesisAccrualDuration() external pure returns (bytes4) {
        return _SEL_GENESIS_ACCRUAL_DURATION;
    }
}

contract ClaimToken_SelectorPins is Test {
    ClaimTokenSelectorHarness internal harness;

    function setUp() public {
        harness = new ClaimTokenSelectorHarness();
    }

    function testClaimTokenMineCoreIdentitySelectorsPinned() public view {
        assertEq(harness.selClaim(), bytes4(0x4e71d92d), "claim() selector changed");
        assertEq(harness.selEmissionStartTime(), bytes4(0xb55e511d), "emissionStartTime() selector changed");
        assertEq(harness.selGenesisAccrualDuration(), bytes4(0xad0d7df1), "GENESIS_ACCRUAL_DURATION() selector changed");
    }

    function testMineCoreSelectorParityPinned() public pure {
        assertEq(IMineCoreSelectorPins.claim.selector, bytes4(0x4e71d92d), "MineCore claim() selector changed");
        assertEq(
            IMineCoreSelectorPins.emissionStartTime.selector,
            bytes4(0xb55e511d),
            "MineCore emissionStartTime() selector changed"
        );
        assertEq(
            IMineCoreSelectorPins.GENESIS_ACCRUAL_DURATION.selector,
            bytes4(0xad0d7df1),
            "MineCore GENESIS_ACCRUAL_DURATION() selector changed"
        );
    }

    function testClaimTokenEventTopicsPinned() public pure {
        assertEq(
            keccak256("MineCoreChanged(address,address)"),
            bytes32(0x6feef750fa5dff8840e5532fab6a2c2cb49e5d9c09050a55ac4cb55fc5a1c699),
            "MineCoreChanged topic changed"
        );
        assertEq(
            keccak256("ConfigFrozen()"),
            bytes32(0xfe8292577024c8a70fcfbe74211dedb793d98ac31e1aefeb3a57b726b28bec3f),
            "ConfigFrozen topic changed"
        );
        assertEq(
            keccak256("Transfer(address,address,uint256)"),
            bytes32(0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef),
            "Transfer topic changed"
        );
        assertEq(
            keccak256("Approval(address,address,uint256)"),
            bytes32(0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925),
            "Approval topic changed"
        );
        assertEq(
            keccak256("OwnershipTransferred(address,address)"),
            bytes32(0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0),
            "OwnershipTransferred topic changed"
        );
        assertEq(
            keccak256("OwnershipTransferStarted(address,address)"),
            bytes32(0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700),
            "OwnershipTransferStarted topic changed"
        );
    }
}
