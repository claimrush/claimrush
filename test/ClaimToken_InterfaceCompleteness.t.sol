// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {IClaimToken} from "src/interfaces/IClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";

contract ClaimTokenInterfaceCompletenessTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant NEXT_OWNER = address(0xBEEF);

    ClaimToken internal token;
    IClaimToken internal claim;

    function setUp() public {
        token = new ClaimToken(OWNER);
        claim = IClaimToken(address(token));
    }

    function testIClaimTokenExposesMetadataAndOwnable2StepSurface() public {
        assertEq(claim.name(), "ClaimRush");
        assertEq(claim.symbol(), "CLAIM");
        assertEq(claim.decimals(), 18);

        assertEq(claim.owner(), OWNER);
        assertEq(claim.pendingOwner(), address(0));

        vm.prank(OWNER);
        claim.transferOwnership(NEXT_OWNER);
        assertEq(claim.pendingOwner(), NEXT_OWNER);
        assertEq(claim.owner(), OWNER);

        vm.prank(NEXT_OWNER);
        claim.acceptOwnership();
        assertEq(claim.owner(), NEXT_OWNER);
        assertEq(claim.pendingOwner(), address(0));
    }

    function testIClaimTokenExposesRenounceOwnershipGuard() public {
        address mineCore = address(new MockMineCoreInterfaceView(address(token)));

        vm.startPrank(OWNER);
        claim.setMineCore(mineCore);

        vm.expectRevert(Errors.NotAuthorized.selector);
        claim.renounceOwnership();

        claim.freezeConfig();
        claim.renounceOwnership();
        vm.stopPrank();

        assertEq(claim.owner(), address(0));
        assertEq(claim.pendingOwner(), address(0));
    }
}

contract MockMineCoreInterfaceView {
    address public claim;

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
