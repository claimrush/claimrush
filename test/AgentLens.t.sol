// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AgentLens} from "../src/lens/AgentLens.sol";
import {Errors} from "../src/lib/Errors.sol";

/// @notice Minimal deployment test for AgentLens (view-only lens contract).
contract AgentLensTest is Test {
    function _defaultParams(address dummy) internal pure returns (AgentLens.ConstructorParams memory) {
        return AgentLens.ConstructorParams({
            claimToken: dummy,
            veClaimNFT: dummy,
            mineCore: dummy,
            shareholderRoyalties: dummy,
            furnace: dummy,
            marketRouter: dummy,
            lpStakingVault7D: dummy,
            dexAdapter: dummy,
            furnaceEntryTokenRegistry: dummy,
            mineCoreEntryTokenRegistry: dummy,
            delegationHub: dummy,
            claimAllHelper: dummy,
            maintenanceHub: dummy,
            launchController: dummy,
            genesisLPVault24M: dummy
        });
    }

    function test_deploy_withValidParams() public {
        address dummy = address(new DummyContract());
        AgentLens lens = new AgentLens(_defaultParams(dummy));

        assertEq(lens.claimToken(), dummy);
        assertEq(lens.furnace(), dummy);
        assertEq(lens.SNAPSHOT_VERSION(), 1);
    }

    function test_deploy_revertsOnZeroAddress() public {
        address dummy = address(new DummyContract());
        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.claimToken = address(0);

        vm.expectRevert();
        new AgentLens(p);
    }

    // ----------------------------------------------------------------
    // EIP-7702 rejection on every immutable address slot
    //
    // AgentLens is view-only and used by agents/deployment checks as a
    // snapshot oracle. If the constructor accepted a 7702-delegated EOA, an
    // attacker could pass `code.length != 0` at deploy time and later mutate
    // the delegation target while the lens stays pinned to the address — a
    // permanent, silent oracle compromise. These tests pin the rejection on
    // every required AND every optional address slot.
    // ----------------------------------------------------------------

    function _etch7702(address target) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", address(this)));
        assertEq(target.code.length, 23, "designator length");
    }

    function _expectRequiredFieldRejectsDelegation(string memory label) internal {
        address dummy = address(new DummyContract());
        address delegated = makeAddr(label);
        _etch7702(delegated);

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        if (keccak256(bytes(label)) == keccak256("delegatedClaimToken")) {
            p.claimToken = delegated;
        } else if (keccak256(bytes(label)) == keccak256("delegatedVeClaimNFT")) {
            p.veClaimNFT = delegated;
        } else if (keccak256(bytes(label)) == keccak256("delegatedMineCore")) {
            p.mineCore = delegated;
        } else if (keccak256(bytes(label)) == keccak256("delegatedShareholderRoyalties")) {
            p.shareholderRoyalties = delegated;
        } else if (keccak256(bytes(label)) == keccak256("delegatedFurnace")) {
            p.furnace = delegated;
        } else {
            revert("unknown required field");
        }

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new AgentLens(p);
    }

    function test_deploy_rejectsDelegatedClaimToken() public {
        _expectRequiredFieldRejectsDelegation("delegatedClaimToken");
    }

    function test_deploy_rejectsDelegatedVeClaimNFT() public {
        _expectRequiredFieldRejectsDelegation("delegatedVeClaimNFT");
    }

    function test_deploy_rejectsDelegatedMineCore() public {
        _expectRequiredFieldRejectsDelegation("delegatedMineCore");
    }

    function test_deploy_rejectsDelegatedShareholderRoyalties() public {
        _expectRequiredFieldRejectsDelegation("delegatedShareholderRoyalties");
    }

    function test_deploy_rejectsDelegatedFurnace() public {
        _expectRequiredFieldRejectsDelegation("delegatedFurnace");
    }

    function test_deploy_rejectsDelegatedOptionalMarketRouter() public {
        // Optional fields are also baked into immutable storage, so the same
        // threat applies. Verify with one representative optional slot to
        // exercise the optional-field codepath; the helper reuses the same
        // `_rejectDelegatedEOA` so all optional slots share the property.
        address dummy = address(new DummyContract());
        address delegated = makeAddr("delegatedOptionalMarketRouter");
        _etch7702(delegated);

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.marketRouter = delegated;

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new AgentLens(p);
    }

    function test_deploy_rejectsDelegatedOptionalLaunchController() public {
        address dummy = address(new DummyContract());
        address delegated = makeAddr("delegatedOptionalLaunchController");
        _etch7702(delegated);

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.launchController = delegated;

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new AgentLens(p);
    }

    function test_deploy_acceptsZeroOptionalSlots() public {
        // Sanity: the optional-slot rejection is a no-op for `address(0)`,
        // so omitting an optional periphery still deploys cleanly.
        address dummy = address(new DummyContract());
        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.marketRouter = address(0);
        p.launchController = address(0);
        p.maintenanceHub = address(0);

        AgentLens lens = new AgentLens(p);
        assertEq(lens.marketRouter(), address(0));
        assertEq(lens.launchController(), address(0));
        assertEq(lens.maintenanceHub(), address(0));
    }

    // ----------------------------------------------------------------
    // Integration: readGlobalV1 graceful degradation
    // ----------------------------------------------------------------

    /// @notice readGlobalV1 must never revert, even when all modules fail.
    function test_readGlobalV1_neverReverts_allModulesFail() public {
        address dummy = address(new DummyContract());
        AgentLens lens = new AgentLens(_defaultParams(dummy));

        AgentLens.GlobalV1 memory s = lens.readGlobalV1();

        // Block metadata always populated
        assertEq(s.blockNumber, block.number);
        assertEq(s.blockTimestamp, block.timestamp);
        assertEq(s.snapshotVersion, 1);

        // All module flags must be false (DummyContract doesn't implement any interface)
        assertFalse(s.status.claimOk, "claim should fail");
        assertFalse(s.status.mineCoreOk, "mineCore should fail");
        assertFalse(s.status.furnaceOk, "furnace should fail");
        assertFalse(s.status.royaltiesOk, "royalties should fail");
        assertFalse(s.status.veOk, "ve should fail");
        assertFalse(s.status.marketOk, "market should fail");
        assertFalse(s.status.lpVaultOk, "lpVault should fail");
        assertFalse(s.status.dexOk, "dex should fail");
    }

    /// @notice readUserV1 must never revert, even when all modules fail.
    function test_readUserV1_neverReverts_allModulesFail() public {
        address dummy = address(new DummyContract());
        AgentLens lens = new AgentLens(_defaultParams(dummy));

        address user = address(0xBEEF);
        AgentLens.UserV1 memory s = lens.readUserV1(user);

        assertEq(s.blockNumber, block.number);
        assertEq(s.blockTimestamp, block.timestamp);
        assertEq(s.user, user);
        assertEq(s.snapshotVersion, 1);

        assertFalse(s.status.claimBalanceOk, "claimBalance should fail");
        assertFalse(s.status.mineCoreOk, "mineCore should fail");
        assertFalse(s.status.royaltiesOk, "royalties should fail");
        assertFalse(s.status.veOk, "ve should fail");
        assertFalse(s.status.marketOk, "market should fail");
        assertFalse(s.status.lpVaultOk, "lpVault should fail");
    }

    /// @notice readUserV1 must revert for address(0).
    function test_readUserV1_revertsOnZeroUser() public {
        address dummy = address(new DummyContract());
        AgentLens lens = new AgentLens(_defaultParams(dummy));

        vm.expectRevert();
        lens.readUserV1(address(0));
    }

    // ----------------------------------------------------------------
    // Integration: partial module success
    // ----------------------------------------------------------------

    /// @notice When claimToken is a valid ERC20 but other modules fail,
    ///         only claimOk / claimBalanceOk should be true.
    function test_readGlobalV1_partialSuccess_onlyClaimOk() public {
        MockERC20 token = new MockERC20();
        address dummy = address(new DummyContract());

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.claimToken = address(token);
        AgentLens lens = new AgentLens(p);

        AgentLens.GlobalV1 memory s = lens.readGlobalV1();

        assertTrue(s.status.claimOk, "claim should succeed");
        assertEq(s.claim.name, "MockClaim");
        assertEq(s.claim.symbol, "MCK");
        assertEq(s.claim.decimals, 18);
        assertEq(s.claim.totalSupply, 1_000_000e18);

        // Other modules still fail
        assertFalse(s.status.mineCoreOk);
        assertFalse(s.status.furnaceOk);
        assertFalse(s.status.royaltiesOk);
        assertFalse(s.status.veOk);
    }

    function test_readGlobalV1_furnaceStatusFalseWhenQuoterFails_butKeepsDirectFields() public {
        address dummy = address(new DummyContract());
        MockFurnaceQuoter quoter = new MockFurnaceQuoter(true);
        MockFurnace furnace = new MockFurnace(address(quoter));

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.furnace = address(furnace);
        AgentLens lens = new AgentLens(p);

        AgentLens.GlobalV1 memory s = lens.readGlobalV1();

        assertFalse(s.status.furnaceOk, "furnace should report incomplete");
        assertTrue(s.furnace.lockingPaused, "direct furnace reads should still populate");
        assertEq(s.furnace.sellImpactVolume, 77);
        assertEq(s.furnace.lastSellImpactUpdate, 88);
        assertEq(s.furnace.lpStreamRatePerSec, 9);
        assertEq(s.furnace.lpStreamPeriodFinish, 10);
        assertEq(s.furnace.lpStreamLastUpdate, 11);
        assertEq(s.furnace.lpStreamRemaining, 12);
        assertEq(s.furnace.reserve, 0, "quoter-backed fields should remain unset on failure");
    }

    function test_readGlobalV1_furnaceStatusTrueWhenAllSubreadsSucceed() public {
        address dummy = address(new DummyContract());
        MockFurnaceQuoter quoter = new MockFurnaceQuoter(false);
        MockFurnace furnace = new MockFurnace(address(quoter));

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.furnace = address(furnace);
        AgentLens lens = new AgentLens(p);

        AgentLens.GlobalV1 memory s = lens.readGlobalV1();

        assertTrue(s.status.furnaceOk, "furnace should report complete");
        assertEq(s.furnace.reserve, 101);
        assertEq(s.furnace.lockedSupply, 202);
        assertEq(s.furnace.userSpotBonusBps, 303);
        assertEq(s.furnace.lpTopupRateBps, 404);
        assertEq(s.furnace.quoteUserBonusBps, 505);
        assertEq(s.furnace.quoteLpTopupBps, 606);
        assertEq(s.furnace.virtualDepth, 707);
        assertEq(s.furnace.lastUpdate, 808);
    }

    function test_readUserV1_partialSuccess_onlyClaimBalanceOk() public {
        MockERC20 token = new MockERC20();
        address dummy = address(new DummyContract());

        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.claimToken = address(token);
        AgentLens lens = new AgentLens(p);

        address user = address(0xBEEF);
        AgentLens.UserV1 memory s = lens.readUserV1(user);

        assertTrue(s.status.claimBalanceOk, "claimBalance should succeed");
        assertEq(s.claimBalance, 0);

        assertFalse(s.status.mineCoreOk);
        assertFalse(s.status.royaltiesOk);
        assertFalse(s.status.veOk);
    }

    // ----------------------------------------------------------------
    // Integration: optional modules with zero address
    // ----------------------------------------------------------------

    /// @notice When optional modules are address(0), their status stays false
    ///         and no call is attempted (gas savings).
    function test_readGlobalV1_optionalModulesZero_skipped() public {
        address dummy = address(new DummyContract());
        AgentLens.ConstructorParams memory p = _defaultParams(dummy);
        p.marketRouter = address(0);
        p.lpStakingVault7D = address(0);
        p.dexAdapter = address(0);

        AgentLens lens = new AgentLens(p);
        AgentLens.GlobalV1 memory s = lens.readGlobalV1();

        // Optional modules skipped — status stays default false
        assertFalse(s.status.marketOk);
        assertFalse(s.status.lpVaultOk);
        assertFalse(s.status.dexOk);
    }

    // ----------------------------------------------------------------
    // SelfCallOnly access control
    // ----------------------------------------------------------------

    /// @notice External callers must not be able to call _readXxxExt directly.
    function test_selfCallOnly_revertsExternalCaller() public {
        address dummy = address(new DummyContract());
        AgentLens lens = new AgentLens(_defaultParams(dummy));

        vm.expectRevert(AgentLens.SelfCallOnly.selector);
        lens._readClaimMetaExt();

        vm.expectRevert(AgentLens.SelfCallOnly.selector);
        lens._readMineCoreGlobalExt();

        vm.expectRevert(AgentLens.SelfCallOnly.selector);
        lens._readFurnaceGlobalExt();

        vm.expectRevert(AgentLens.SelfCallOnly.selector);
        lens._readMineCoreUserExt(address(0xBEEF));

        vm.expectRevert(AgentLens.SelfCallOnly.selector);
        lens._readVeUserExt(address(0xBEEF));
    }
}

/// @dev Minimal contract so address.code.length > 0 for constructor checks.
contract DummyContract {
    fallback() external payable {}
}

/// @dev Minimal ERC20 that responds to name/symbol/decimals/totalSupply/balanceOf.
contract MockERC20 {
    function name() external pure returns (string memory) {
        return "MockClaim";
    }

    function symbol() external pure returns (string memory) {
        return "MCK";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 1_000_000e18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
    fallback() external payable {}
}

contract MockFurnace {
    address internal immutable quoter;

    constructor(address _quoter) {
        quoter = _quoter;
    }

    function lockingPaused() external pure returns (bool) {
        return true;
    }

    function furnaceQuoter() external view returns (address) {
        return quoter;
    }

    function sellImpactVolume() external pure returns (uint256) {
        return 77;
    }

    function lastSellImpactUpdate() external pure returns (uint256) {
        return 88;
    }

    function getLpStreamState() external pure returns (uint256, uint256, uint256, uint256) {
        return (9, 10, 11, 12);
    }
}

contract MockFurnaceQuoter {
    bool internal immutable shouldRevert;

    constructor(bool _shouldRevert) {
        shouldRevert = _shouldRevert;
    }

    function getFurnaceState()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        if (shouldRevert) revert("quoter failed");
        return (101, 202, 303, 404, 505, 606, 707, 808);
    }
}
