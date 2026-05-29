// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";

contract ClaimTokenWiringProbeSinkRegressionTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA);
    address internal constant BOB = address(0xB);

    ClaimToken internal token;
    address internal mineCore;
    address internal wiringProbe;

    function setUp() public {
        token = new ClaimToken(OWNER);
        wiringProbe = _computeCreateNonce1Address(address(token));
        assertGt(wiringProbe.code.length, 0, "computed probe address mismatch");

        mineCore = address(new MockMineCoreSinkView(address(token)));
        vm.prank(OWNER);
        token.setMineCore(mineCore);

        vm.prank(mineCore);
        token.mint(ALICE, 100e18);
    }

    function test_transfer_toWiringProbe_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(Errors.TransfersRestricted.selector);
        token.transfer(wiringProbe, 1e18);
    }

    function test_transferFrom_toWiringProbe_reverts() public {
        vm.prank(ALICE);
        token.approve(BOB, 100e18);

        vm.prank(BOB);
        vm.expectRevert(Errors.TransfersRestricted.selector);
        token.transferFrom(ALICE, wiringProbe, 1e18);
    }

    function test_mint_toWiringProbe_reverts() public {
        vm.prank(mineCore);
        vm.expectRevert(Errors.TransfersRestricted.selector);
        token.mint(wiringProbe, 1e18);
    }

    function test_setMineCore_toWiringProbe_reverts() public {
        ClaimToken fresh = new ClaimToken(OWNER);
        address freshProbe = _computeCreateNonce1Address(address(fresh));
        assertGt(freshProbe.code.length, 0, "computed probe address mismatch");

        vm.prank(OWNER);
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.setMineCore(freshProbe);
    }

    function test_ethTransfer_toWiringProbe_reverts() public {
        vm.deal(ALICE, 1 ether);

        vm.prank(ALICE);
        (bool ok,) = payable(wiringProbe).call{value: 1 wei}("");
        assertFalse(ok, "probe must reject direct ETH");
        assertEq(wiringProbe.balance, 0, "probe balance must stay zero");
    }

    function _computeCreateNonce1Address(address deployer) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x01))))));
    }
}

contract MockMineCoreSinkView {
    address public immutable claim;
    uint256 public constant emissionStartTime = 1;
    uint256 public constant GENESIS_ACCRUAL_DURATION = 604800;

    constructor(address claim_) {
        claim = claim_;
    }
}
