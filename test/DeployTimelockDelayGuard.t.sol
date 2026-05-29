// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "script/Deploy.s.sol";

contract _DeployDelayHarness is Deploy {
    /// @dev Thin view-adapter so the test can invoke the internal guard directly.
    function requireValidMainnetTimelockDelay(uint256 delay, bool allowUnsafe) external view {
        _requireValidMainnetTimelockDelay(delay, allowUnsafe);
    }
}

contract DeployTimelockDelayGuardTest is Test {
    /// @dev Historical note: this test used to drive `_loadConfig()` end-to-end via
    ///      `vm.setEnv`, then assert on the expected revert string. Foundry runs test
    ///      contracts in parallel threads sharing a single OS process env, so concurrent
    ///      `vm.setEnv` writes from peer test contracts (e.g. `ScriptSafety.t.sol`
    ///      setting `LP_WITHDRAW_RECIPIENT=""`) could clobber this test's setUp between
    ///      the test-function entry and `_loadConfig` reading the variable. That made
    ///      the suite non-deterministically fail on an earlier `_loadConfig` check.
    ///      The guard under test here is a pure function of its two arguments, so we
    ///      now drive it directly via a harness and sidestep the env-var race entirely.
    function testTimelockDelayOverrideGuard() public {
        vm.chainId(8453);

        _DeployDelayHarness script = new _DeployDelayHarness();

        uint256 shortDelay = 3600;

        // --- reject: short delay without explicit ack must revert --------------
        vm.expectRevert(
            "Deploy: TIMELOCK_DELAY_SECONDS below 48 hours on mainnet; set ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY=true to override"
        );
        script.requireValidMainnetTimelockDelay(shortDelay, false);

        // --- allow: explicit ack permits short delay ----------------------------
        script.requireValidMainnetTimelockDelay(shortDelay, true);

        // --- safe delay is always accepted, ack or no ack -----------------------
        script.requireValidMainnetTimelockDelay(48 hours, false);
        script.requireValidMainnetTimelockDelay(48 hours, true);
    }

    /// @dev On non-mainnet chains the guard is a no-op regardless of the ack flag.
    function testTimelockDelayOverrideGuardNoopOffMainnet() public {
        vm.chainId(31337);

        _DeployDelayHarness script = new _DeployDelayHarness();

        script.requireValidMainnetTimelockDelay(1 seconds, false);
        script.requireValidMainnetTimelockDelay(1 seconds, true);
    }
}
