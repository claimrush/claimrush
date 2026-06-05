// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";

/// @notice Pin delegation permission bit positions against accidental drift.
/// @dev Bit positions are ABI/stability sensitive once deployed.
///      Shifting a bit changes the meaning of existing on-chain sessions,
///      granting unintended permissions or revoking expected ones.
contract DelegationPermissionsGuardrailTest is Test {
    // MineCore
    function testPTakeoverFor() public {
        assertEq(DelegationPermissions.P_TAKEOVER_FOR, 1 << 0);
    }

    function testPRouteReignClaimToCaller() public {
        assertEq(DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER, 1 << 1);
    }

    function testPSetReignEthRecipient() public {
        assertEq(DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT, 1 << 2);
    }

    function testPSetReignEthRecipientToCallerOnly() public {
        assertEq(DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY, 1 << 3);
    }

    function testPSetReignClaimRecipient() public {
        assertEq(DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT, 1 << 4);
    }

    function testPSetReignClaimRecipientToUserOnly() public {
        assertEq(DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY, 1 << 5);
    }

    // ClaimAllHelper
    function testPWithdrawKingBucketFor() public {
        assertEq(DelegationPermissions.P_WITHDRAW_KING_BUCKET_FOR, 1 << 6);
    }

    function testPClaimShareholderFor() public {
        assertEq(DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR, 1 << 7);
    }

    function testPClaimAllFor() public {
        assertEq(DelegationPermissions.P_CLAIM_ALL_FOR, 1 << 8);
    }

    // Furnace
    function testPFurnaceEnterEthFor() public {
        assertEq(DelegationPermissions.P_FURNACE_ENTER_ETH_FOR, 1 << 9);
    }

    function testPFurnaceEnterClaimFor() public {
        assertEq(DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR, 1 << 10);
    }

    function testPFurnaceEnterTokenFor() public {
        assertEq(DelegationPermissions.P_FURNACE_ENTER_TOKEN_FOR, 1 << 11);
    }

    // VeClaimNFT
    function testPVeExtendLockFor() public {
        assertEq(DelegationPermissions.P_VE_EXTEND_LOCK_FOR, 1 << 12);
    }

    function testPVeMergeLocksFor() public {
        assertEq(DelegationPermissions.P_VE_MERGE_LOCKS_FOR, 1 << 13);
    }

    function testPVeUnlockExpiredFor() public {
        assertEq(DelegationPermissions.P_VE_UNLOCK_EXPIRED_FOR, 1 << 14);
    }

    // Settings / config
    function testPSetKingAutoLockConfigFor() public {
        assertEq(DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR, 1 << 15);
    }

    function testPSetShareholderAutoCompoundConfigFor() public {
        assertEq(DelegationPermissions.P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR, 1 << 16);
    }

    function testPSetLpAutoCompoundConfigFor() public {
        assertEq(DelegationPermissions.P_SET_LP_AUTOCOMPOUND_CONFIG_FOR, 1 << 17);
    }

    // ClaimAllHelper (value routing)
    function testPRouteShareholderEthToCaller() public {
        assertEq(DelegationPermissions.P_ROUTE_SHAREHOLDER_ETH_TO_CALLER, 1 << 18);
    }

    // ALL convenience mask
    function testAllMaskCoversExactlyBits0Through18() public {
        uint256 expected = 0;
        for (uint256 i = 0; i < 19; i++) {
            expected |= (1 << i);
        }
        assertEq(DelegationPermissions.ALL, expected, "ALL mask must be bits 0..18");
    }

    function testPermissionBitsArePairwiseUnique() public {
        uint256[19] memory bits = [
            DelegationPermissions.P_TAKEOVER_FOR,
            DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER,
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT,
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
            DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT,
            DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
            DelegationPermissions.P_WITHDRAW_KING_BUCKET_FOR,
            DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR,
            DelegationPermissions.P_CLAIM_ALL_FOR,
            DelegationPermissions.P_FURNACE_ENTER_ETH_FOR,
            DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR,
            DelegationPermissions.P_FURNACE_ENTER_TOKEN_FOR,
            DelegationPermissions.P_VE_EXTEND_LOCK_FOR,
            DelegationPermissions.P_VE_MERGE_LOCKS_FOR,
            DelegationPermissions.P_VE_UNLOCK_EXPIRED_FOR,
            DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR,
            DelegationPermissions.P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
            DelegationPermissions.P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
            DelegationPermissions.P_ROUTE_SHAREHOLDER_ETH_TO_CALLER
        ];

        for (uint256 i = 0; i < bits.length; i++) {
            assertTrue(bits[i] != 0, "permission bit must be non-zero");
            for (uint256 j = i + 1; j < bits.length; j++) {
                assertEq(bits[i] & bits[j], 0, "permission bits must not overlap");
            }
        }
    }
}
