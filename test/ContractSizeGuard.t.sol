// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

/// @notice Fail-fast guard: every production-deployable contract must fit within EIP-170.
/// @dev Mirrors the DEFAULT_CONTRACTS list in scripts/check_contract_sizes.py.
///      Uses vm.getDeployedCode to read the compiled runtime bytecode without actually deploying,
///      so the test works even when Anvil's code-size-limit is disabled.
contract ContractSizeGuard is Test {
    uint256 constant EIP170_LIMIT = 24_576;
    uint256 constant EIP3860_INITCODE_LIMIT = 49_152;

    function _assertUnderLimit(string memory artifact, string memory label) internal {
        bytes memory code = vm.getDeployedCode(artifact);
        assertTrue(
            code.length <= EIP170_LIMIT,
            string.concat(
                label, ": runtime ", vm.toString(code.length), " B > EIP-170 limit ", vm.toString(EIP170_LIMIT), " B"
            )
        );
    }

    function _assertInitcodeUnderLimit(string memory artifact, string memory label) internal {
        bytes memory code = vm.getCode(artifact);
        assertTrue(
            code.length <= EIP3860_INITCODE_LIMIT,
            string.concat(
                label,
                ": initcode ",
                vm.toString(code.length),
                " B > EIP-3860 limit ",
                vm.toString(EIP3860_INITCODE_LIMIT),
                " B"
            )
        );
    }

    function test_eip170_ClaimToken() public {
        _assertUnderLimit("ClaimToken.sol:ClaimToken", "ClaimToken");
    }

    function test_eip170_VeClaimNFT() public {
        _assertUnderLimit("VeClaimNFT.sol:VeClaimNFT", "VeClaimNFT");
    }

    function test_eip170_MineCore() public {
        _assertUnderLimit("MineCore.sol:MineCore", "MineCore");
    }

    function test_eip170_MineCoreHelper() public {
        _assertUnderLimit("MineCoreHelper.sol:MineCoreHelper", "MineCoreHelper");
    }

    function test_eip170_MineCoreQuoter() public {
        _assertUnderLimit("MineCoreQuoter.sol:MineCoreQuoter", "MineCoreQuoter");
    }

    function test_eip170_ShareholderRoyalties() public {
        _assertUnderLimit("ShareholderRoyalties.sol:ShareholderRoyalties", "ShareholderRoyalties");
    }

    function test_eip170_Furnace() public {
        _assertUnderLimit("Furnace.sol:Furnace", "Furnace");
    }

    function test_eip170_FurnaceQuoter() public {
        _assertUnderLimit("FurnaceQuoter.sol:FurnaceQuoter", "FurnaceQuoter");
    }

    function test_eip170_FurnaceGuardHelper() public {
        _assertUnderLimit("FurnaceGuardHelper.sol:FurnaceGuardHelper", "FurnaceGuardHelper");
    }

    function test_eip170_MarketRouter() public {
        _assertUnderLimit("MarketRouter.sol:MarketRouter", "MarketRouter");
    }

    function test_eip170_ClaimAllHelper() public {
        _assertUnderLimit("ClaimAllHelper.sol:ClaimAllHelper", "ClaimAllHelper");
    }

    function test_eip170_EntryTokenRegistry() public {
        _assertUnderLimit("EntryTokenRegistry.sol:EntryTokenRegistry", "EntryTokenRegistry");
    }

    function test_eip170_DexAdapter() public {
        _assertUnderLimit("DexAdapter.sol:DexAdapter", "DexAdapter");
    }

    function test_eip170_MaintenanceHub() public {
        _assertUnderLimit("MaintenanceHub.sol:MaintenanceHub", "MaintenanceHub");
    }

    function test_eip170_LpStakingVault7D() public {
        _assertUnderLimit("LpStakingVault7D.sol:LpStakingVault7D", "LpStakingVault7D");
    }

    function test_eip170_LaunchController() public {
        _assertUnderLimit("LaunchController.sol:LaunchController", "LaunchController");
    }

    function test_eip170_GenesisLPVault24M() public {
        _assertUnderLimit("GenesisLPVault24M.sol:GenesisLPVault24M", "GenesisLPVault24M");
    }

    function test_eip170_DelegationHub() public {
        _assertUnderLimit("DelegationHub.sol:DelegationHub", "DelegationHub");
    }

    function test_eip170_AgentLens() public {
        _assertUnderLimit("AgentLens.sol:AgentLens", "AgentLens");
    }

    // --- EIP-3860 initcode limit tests ---

    function test_eip3860_ClaimToken() public {
        _assertInitcodeUnderLimit("ClaimToken.sol:ClaimToken", "ClaimToken");
    }

    function test_eip3860_VeClaimNFT() public {
        _assertInitcodeUnderLimit("VeClaimNFT.sol:VeClaimNFT", "VeClaimNFT");
    }

    function test_eip3860_MineCore() public {
        _assertInitcodeUnderLimit("MineCore.sol:MineCore", "MineCore");
    }

    function test_eip3860_MineCoreHelper() public {
        _assertInitcodeUnderLimit("MineCoreHelper.sol:MineCoreHelper", "MineCoreHelper");
    }

    function test_eip3860_MineCoreQuoter() public {
        _assertInitcodeUnderLimit("MineCoreQuoter.sol:MineCoreQuoter", "MineCoreQuoter");
    }

    function test_eip3860_ShareholderRoyalties() public {
        _assertInitcodeUnderLimit("ShareholderRoyalties.sol:ShareholderRoyalties", "ShareholderRoyalties");
    }

    function test_eip3860_Furnace() public {
        _assertInitcodeUnderLimit("Furnace.sol:Furnace", "Furnace");
    }

    function test_eip3860_FurnaceQuoter() public {
        _assertInitcodeUnderLimit("FurnaceQuoter.sol:FurnaceQuoter", "FurnaceQuoter");
    }

    function test_eip3860_FurnaceGuardHelper() public {
        _assertInitcodeUnderLimit("FurnaceGuardHelper.sol:FurnaceGuardHelper", "FurnaceGuardHelper");
    }

    function test_eip3860_MarketRouter() public {
        _assertInitcodeUnderLimit("MarketRouter.sol:MarketRouter", "MarketRouter");
    }

    function test_eip3860_ClaimAllHelper() public {
        _assertInitcodeUnderLimit("ClaimAllHelper.sol:ClaimAllHelper", "ClaimAllHelper");
    }

    function test_eip3860_EntryTokenRegistry() public {
        _assertInitcodeUnderLimit("EntryTokenRegistry.sol:EntryTokenRegistry", "EntryTokenRegistry");
    }

    function test_eip3860_DexAdapter() public {
        _assertInitcodeUnderLimit("DexAdapter.sol:DexAdapter", "DexAdapter");
    }

    function test_eip3860_MaintenanceHub() public {
        _assertInitcodeUnderLimit("MaintenanceHub.sol:MaintenanceHub", "MaintenanceHub");
    }

    function test_eip3860_LpStakingVault7D() public {
        _assertInitcodeUnderLimit("LpStakingVault7D.sol:LpStakingVault7D", "LpStakingVault7D");
    }

    function test_eip3860_LaunchController() public {
        _assertInitcodeUnderLimit("LaunchController.sol:LaunchController", "LaunchController");
    }

    function test_eip3860_GenesisLPVault24M() public {
        _assertInitcodeUnderLimit("GenesisLPVault24M.sol:GenesisLPVault24M", "GenesisLPVault24M");
    }

    function test_eip3860_DelegationHub() public {
        _assertInitcodeUnderLimit("DelegationHub.sol:DelegationHub", "DelegationHub");
    }

    function test_eip3860_AgentLens() public {
        _assertInitcodeUnderLimit("AgentLens.sol:AgentLens", "AgentLens");
    }
}
