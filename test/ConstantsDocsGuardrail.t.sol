// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/lib/Constants.sol";

/// @notice Guardrails against accidental drift between Solidity constants and the public constants appendix.
contract ConstantsDocsGuardrailTest is Test {
    /// @dev Curated public constants appendix for v1.0.0.
    string internal constant DOC_PATH = "docs/manuals/developer/appendix-constants-v100.md";

    modifier onlyWhenDocPresent() {
        if (!vm.isFile(DOC_PATH)) {
            return;
        }
        _;
    }

    function testEmergencyDelistMinAgeMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedDays = _parseUintAfterNeedle(md, "| EMERGENCY_DELIST_MIN_AGE |");
        assertEq(
            Constants.EMERGENCY_DELIST_MIN_AGE, expectedDays * 1 days, "Constants.EMERGENCY_DELIST_MIN_AGE != docs"
        );
    }

    function testMinLockDurationMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedDays = _parseUintAfterNeedle(md, "| MIN_LOCK_DURATION |");
        assertEq(Constants.MIN_LOCK_DURATION, expectedDays * 1 days, "Constants.MIN_LOCK_DURATION != docs");
    }

    function testMaxLockDurationMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedDays = _parseUintAfterNeedle(md, "| MAX_LOCK_DURATION |");
        assertEq(Constants.MAX_LOCK_DURATION, expectedDays * 1 days, "Constants.MAX_LOCK_DURATION != docs");
    }

    function testMaxVeNftsPerUserMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expected = _parseUintAfterNeedle(md, "| MAX_VE_NFTS_PER_USER |");
        assertEq(Constants.MAX_VE_NFTS_PER_USER, expected, "Constants.MAX_VE_NFTS_PER_USER != docs");
    }

    function testUnbondingPeriodMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedDays = _parseUintAfterNeedle(md, "| UNBONDING_PERIOD |");
        assertEq(Constants.UNBONDING_PERIOD, expectedDays * 1 days, "Constants.UNBONDING_PERIOD != docs");
    }

    function testMaxUnbondsPerUserMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expected = _parseUintAfterNeedle(md, "| MAX_UNBONDS_PER_USER |");
        assertEq(Constants.MAX_UNBONDS_PER_USER, expected, "Constants.MAX_UNBONDS_PER_USER != docs");
    }

    function testMinVeFlushMatchesDocs() public onlyWhenDocPresent {
        // Public appendix: "MIN_VE_FLUSH | 100 veCLAIM" — parse the 100 prefix, multiply by 1e18.
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedBase = _parseUintAfterNeedle(md, "| MIN_VE_FLUSH |");
        assertEq(Constants.MIN_VE_FLUSH, expectedBase * 1e18, "Constants.MIN_VE_FLUSH != docs");
    }

    // ---------------------------------------------------------------
    // Emission constants
    // ---------------------------------------------------------------

    function testEmissionDecayPeriodMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedYears = _parseUintAfterNeedle(md, "| EMISSION_DECAY_PERIOD |");
        assertEq(Constants.EMISSION_DECAY_PERIOD, expectedYears * 365 days, "Constants.EMISSION_DECAY_PERIOD != docs");
    }

    function testKingEmissionLaunchRateMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedBase = _parseUintAfterNeedle(md, "| KING_EMISSION_LAUNCH_RATE |");
        assertEq(
            Constants.KING_EMISSION_LAUNCH_RATE, expectedBase * 1e18, "Constants.KING_EMISSION_LAUNCH_RATE != docs"
        );
    }

    function testFurnaceEmissionLaunchRateMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedBase = _parseUintAfterNeedle(md, "| FURNACE_EMISSION_LAUNCH_RATE |");
        assertEq(
            Constants.FURNACE_EMISSION_LAUNCH_RATE,
            expectedBase * 1e18,
            "Constants.FURNACE_EMISSION_LAUNCH_RATE != docs"
        );
    }

    function testTakeoverDecayPeriodMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedHours = _parseUintAfterNeedle(md, "| TAKEOVER_DECAY_PERIOD |");
        assertEq(Constants.TAKEOVER_DECAY_PERIOD, expectedHours * 1 hours, "Constants.TAKEOVER_DECAY_PERIOD != docs");
    }

    // ---------------------------------------------------------------
    // BPS / spread / bonus constants
    // ---------------------------------------------------------------

    function testBpsDenomMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expected = _parseUintAfterNeedle(md, "| BPS_DENOM |");
        assertEq(Constants.BPS_DENOM, expected, "Constants.BPS_DENOM != docs");
    }

    function testMaxUserBonusBpsMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expected = _parseUintAfterNeedle(md, "| MAX_USER_BONUS_BPS |");
        assertEq(Constants.MAX_USER_BONUS_BPS, expected, "Constants.MAX_USER_BONUS_BPS != docs");
    }

    function testSellSpreadFloor7dBpsMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expected = _parseUintAfterNeedle(md, "| SELL_SPREAD_FLOOR_7D_BPS |");
        assertEq(Constants.SELL_SPREAD_FLOOR_7D_BPS, expected, "Constants.SELL_SPREAD_FLOOR_7D_BPS != docs");
    }

    function testSwapDeadlineSecondsMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expected = _parseUintAfterNeedle(md, "| SWAP_DEADLINE_SECONDS |");
        assertEq(Constants.SWAP_DEADLINE_SECONDS, expected, "Constants.SWAP_DEADLINE_SECONDS != docs");
    }

    function testMinLockAmountMatchesDocs() public onlyWhenDocPresent {
        string memory md = vm.readFile(DOC_PATH);
        uint256 expectedBase = _parseUintAfterNeedle(md, "| MIN_LOCK_AMOUNT |");
        assertEq(Constants.MIN_LOCK_AMOUNT, expectedBase * 1e18, "Constants.MIN_LOCK_AMOUNT != docs");
    }

    // ---------------------------------------------------------------
    // Pinned structural invariants
    // ---------------------------------------------------------------

    /// @dev KING_EMISSION_FLOOR = KING_EMISSION_LAUNCH_RATE / 9 (integer division).
    function testKingEmissionFloorIsLaunchRateDividedBy9() public pure {
        assertEq(
            Constants.KING_EMISSION_FLOOR,
            Constants.KING_EMISSION_LAUNCH_RATE / 9,
            "KING_EMISSION_FLOOR must equal KING_EMISSION_LAUNCH_RATE / 9"
        );
    }

    /// @dev Same structural invariant for the Furnace emission floor.
    function testFurnaceEmissionFloorIsLaunchRateDividedBy9() public pure {
        assertEq(
            Constants.FURNACE_EMISSION_FLOOR,
            Constants.FURNACE_EMISSION_LAUNCH_RATE / 9,
            "FURNACE_EMISSION_FLOOR must equal FURNACE_EMISSION_LAUNCH_RATE / 9"
        );
    }

    /// @dev TAKEOVER_PRICE_FLOOR is pinned at 0.001 ether.
    function testTakeoverPriceFloorPinned() public pure {
        assertEq(Constants.TAKEOVER_PRICE_FLOOR, 0.001 ether, "TAKEOVER_PRICE_FLOOR must be 0.001 ether");
    }

    /// @dev SETTLEMENT_KEEPER_GRACE_SECONDS is the keeper-priority window.
    function testSettlementKeeperGraceSecondsPinned() public pure {
        assertEq(
            Constants.SETTLEMENT_KEEPER_GRACE_SECONDS, 1800, "SETTLEMENT_KEEPER_GRACE_SECONDS must be 1800 (30 minutes)"
        );
    }

    /// @notice Parse a base-10 uint that appears after the first occurrence of `needle` in `text`.
    /// @dev Designed for simple markdown table rows like: `| EMERGENCY_DELIST_MIN_AGE | 7 days |`.
    function _parseUintAfterNeedle(string memory text, string memory needle) internal pure returns (uint256) {
        bytes memory t = bytes(text);
        bytes memory n = bytes(needle);

        // Find the first occurrence of the needle.
        uint256 i = _indexOf(t, n);

        // Move to the first byte after the needle.
        uint256 k = i + n.length;

        // Skip ASCII spaces.
        while (k < t.length && t[k] == 0x20) {
            k++;
        }

        // Parse digits.
        uint256 value = 0;
        bool found = false;
        while (k < t.length) {
            uint8 c = uint8(t[k]);
            if (c >= 48 && c <= 57) {
                value = value * 10 + (c - 48);
                found = true;
                k++;
            } else if (c == 0x2C || c == 0x5F) {
                // comma / underscore separators — skip
                k++;
            } else {
                break;
            }
        }

        require(found, "docs parse: expected digits");
        return value;
    }

    /// @notice Return the start index of the first occurrence of `needle` in `haystack`.
    function _indexOf(bytes memory haystack, bytes memory needle) internal pure returns (uint256) {
        require(needle.length > 0, "docs parse: empty needle");
        require(haystack.length >= needle.length, "docs parse: needle too long");

        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return i;
        }

        revert("docs parse: needle not found");
    }
}
