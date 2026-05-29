// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IClaimToken} from "src/interfaces/IClaimToken.sol";
import {IVeClaimNFT} from "src/interfaces/IVeClaimNFT.sol";
import {IFurnace} from "src/interfaces/IFurnace.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title Furnace `extendWithBonus` floor-drift probe (Sepolia fork dry run)
/// @notice Property: cycling N small extensions over a window pays no more bonus than
///         a single extension covering the same window. Mirrors the M4 path-independence
///         property test, but exercises the deployed Sepolia bytecode instead of a
///         freshly-deployed local stack. The probe is a dry run — `vm.createSelectFork`
///         loads Sepolia state into a local EVM, and all `extendWithBonus` calls
///         execute against the fork without ever broadcasting a transaction.
///
/// @dev Skipped automatically when `BASE_SEPOLIA_RPC_URL` is unset, so the probe
///      never breaks normal CI. Run with:
///        BASE_SEPOLIA_RPC_URL=<url> forge test --match-path \
///          test/Furnace_ExtendWithBonusFloorDriftProbe.fork.t.sol -vv
contract FurnaceExtendWithBonusFloorDriftProbeForkTest is Test {
    // Canonical addresses from `deployments/base_sepolia.json` (recorded 2026-04-28T14:07:14Z).
    address internal constant CLAIM = 0x5Caf80d77D6D9Bd7870B2e3Cb227eb49f6695d1F;
    address internal constant VE_CLAIM = 0xdB0B201C42a08510BecEa0EA68030A69af0a4A1c;
    address internal constant FURNACE = 0x15617293eaEcefbf2ffa8Dd8aA9D2c49a39A3d7E;
    address internal constant MINE_CORE = 0xD0f9e2E2269E9801a2765d52Bd8077A34eF71c41;

    address internal user = address(0xB1B1);

    IClaimToken internal claim;
    IVeClaimNFT internal ve;
    IFurnace internal furnace;

    function setUp() public {
        string memory rpc;
        try vm.envString("BASE_SEPOLIA_RPC_URL") returns (string memory v) {
            rpc = v;
        } catch {
            rpc = "";
        }
        if (bytes(rpc).length == 0) {
            // No fork URL: nothing to probe. setUp returns; every test guards on
            // `_forkActive()` and skips when the fork was not initialized.
            return;
        }

        vm.createSelectFork(rpc);
        claim = IClaimToken(CLAIM);
        ve = IVeClaimNFT(VE_CLAIM);
        furnace = IFurnace(FURNACE);
    }

    function _forkActive() internal view returns (bool) {
        return address(furnace) != address(0);
    }

    function _mintClaim(address to, uint256 amount) internal {
        // ClaimToken.mint is gated on `onlyMineCore`. Impersonate MineCore on the
        // fork to seed a synthetic lock for the probe.
        vm.prank(MINE_CORE);
        claim.mint(to, amount);
    }

    function _createLock(uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        // The user-facing lock-creation path is `Furnace.enter*`, which routes through
        // an entry-token swap. For the probe we sidestep the swap by minting CLAIM
        // directly to Furnace (impersonating MineCore) and impersonating Furnace to
        // call `VeClaimNFT.createLockFor` — the same Furnace-only path the live
        // contract uses internally to mint a lock for the user.
        _mintClaim(address(furnace), amount);
        vm.startPrank(address(furnace));
        claim.approve(address(ve), type(uint256).max);
        tokenId = ve.createLockFor(user, amount, duration, false);
        vm.stopPrank();
    }

    /// @notice Baseline single-shot extension covering N×step seconds pays at least as
    ///         much bonus as N separate step-sized extensions covering the same window.
    ///         The cycled total stays inside a 1 CLAIM (1e18 wei) ceiling above the
    ///         baseline — that ceiling catches a degenerate bps-floor surcharge of
    ///         roughly 0.05 CLAIM per cycle on a 5M CLAIM lock without false-positiving
    ///         on legitimate AMM curvature drift.
    function test_FloorDriftProbe_CyclingDoesNotInflateBaseline() public {
        if (!_forkActive()) {
            emit log("BASE_SEPOLIA_RPC_URL unset; floor-drift probe skipped (dry-run only).");
            return;
        }

        uint256 lockAmt = 5_000_000e18;
        uint256 cycles = 11;
        uint256 step = 30;
        uint256 totalDelta = cycles * step;

        // Drop block.timestamp warps onto the live fork's clock; the on-chain lock
        // book starts from `block.timestamp` at fork-load time.
        vm.warp(block.timestamp + 1);
        uint256 lockId = _createLock(lockAmt, Constants.MAX_LOCK_DURATION - totalDelta);
        vm.warp(block.timestamp + 1);

        uint256 snapId = vm.snapshot();

        uint256 endT = block.timestamp + cycles * step;
        vm.warp(endT);
        vm.prank(user);
        uint256 baselineBonus = furnace.extendWithBonus(lockId, Constants.MAX_LOCK_DURATION, 0);
        assertGt(baselineBonus, 0, "baseline single-shot extension should pay non-zero bonus");

        require(vm.revertTo(snapId), "snapshot revert failed");

        uint256 cycledTotal = 0;
        uint256 t = block.timestamp;
        for (uint256 i = 1; i <= cycles; i++) {
            t += step;
            vm.warp(t);
            uint256 target = Constants.MAX_LOCK_DURATION - totalDelta + (i * step);
            vm.prank(user);
            uint256 paid = furnace.extendWithBonus(lockId, target, 0);
            cycledTotal += paid;
        }

        emit log_named_uint("baseline bonus (claim wei)", baselineBonus);
        emit log_named_uint("cycled total (claim wei) ", cycledTotal);

        assertLt(cycledTotal, 2 * baselineBonus, "cycled extension cumulative bonus exceeds 2x single-shot baseline");
        assertLt(
            cycledTotal,
            baselineBonus + 1e18,
            "cycled extension surcharge above baseline indicates duration weight floor drift"
        );
    }
}
