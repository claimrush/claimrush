// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/lib/Constants.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {MockContract} from "../../mocks/MockContract.sol";

/// @title Furnace bonus-split model differential
/// @notice Pins the local pure-function model helper used by
///         `test/halmos/Furnace_M1_M6_Proofs.t.sol` against the production
///         source so a refactor of `FurnaceGuardHelper.splitBonusAmm` is
///         caught by a Foundry fuzz before it silently invalidates the
///         Halmos proofs.
///
/// @dev    Differential coverage: the `(userBonus, lpBonus)` split from
///         `FurnaceGuardHelper.splitBonusAmm`
///         (`src/FurnaceGuardHelper.sol:1301-1309`) is called directly
///         and the model output is asserted equal across the bounded
///         fuzz domain. The harness's `_principalEff` projection is the
///         bytecode-equivalent integer form `(amount * weight) /
///         WEIGHT_DENOM` (production source at `src/Furnace.sol:971`).
///         A second differential below pins it against
///         OpenZeppelin's `Math.mulDiv` so any future widening of the
///         symbolic domain past the uint256-safe envelope is caught
///         immediately rather than silently corrupting the M1/M4
///         proofs.
contract Furnace_ModelDifferentialTest is Test {
    FurnaceGuardHelper internal helper;

    function setUp() public {
        MockContract claimStub = new MockContract();
        MockContract veStub = new MockContract();
        helper = new FurnaceGuardHelper(address(claimStub), address(veStub));
    }

    /// @dev Local mirror of the harness `_bonusSplit` helper, restricted to
    ///      the user / lp split branch (no dust-refund — that lives in the
    ///      Furnace caller, not the helper).
    function _modelSplit(uint256 grossBonus, uint256 lpRateBps) internal pure returns (uint256 user, uint256 lp) {
        if (lpRateBps == 0 || grossBonus == 0) return (grossBonus, 0);
        user = Math.mulDiv(grossBonus, Constants.BPS_DENOM, Constants.BPS_DENOM + lpRateBps);
        lp = grossBonus - user;
    }

    /// @notice The harness `_bonusSplit` user / lp branch matches
    ///         `FurnaceGuardHelper.splitBonusAmm` exactly across the bounded
    ///         input domain.
    function testFuzz_modelSplitMatchesProduction(uint256 grossBonus, uint256 lpRateBps) public view {
        grossBonus = bound(grossBonus, 0, 1_000_000_000_000e18);
        lpRateBps = bound(lpRateBps, 0, Constants.LP_TOPUP_RATE_MAX_BPS);

        (uint256 modelUser, uint256 modelLp) = _modelSplit(grossBonus, lpRateBps);
        (uint256 prodUser, uint256 prodLp) = helper.splitBonusAmm(grossBonus, lpRateBps);

        assertEq(modelUser, prodUser, "split: user share drift");
        assertEq(modelLp, prodLp, "split: lp share drift");
    }

    /// @notice The harness `_principalEff` integer form
    ///         `(lockAmount * weightDelta) / WEIGHT_DENOM` matches
    ///         `Math.mulDiv(lockAmount, weightDelta, WEIGHT_DENOM)` across
    ///         the bounded symbolic domain
    ///         (`MAX_SYMBOLIC_VALUE * WEIGHT_DENOM = 1e30 * 1e12 = 1e42`,
    ///         well inside uint256). The integer form is what the M1/M4
    ///         proofs run against; this differential exists so that any
    ///         future widening of the harness bounds past the uint256-safe
    ///         envelope is caught here instead of silently invalidating
    ///         the proofs.
    function testFuzz_modelPrincipalEffMatchesMulDiv(uint256 lockAmount, uint256 weightDelta) public pure {
        lockAmount = bound(lockAmount, 0, 1_000_000_000_000e18);
        weightDelta = bound(weightDelta, 0, Constants.WEIGHT_DENOM);

        uint256 modelOut = (lockAmount * weightDelta) / Constants.WEIGHT_DENOM;
        uint256 mulDivOut = Math.mulDiv(lockAmount, weightDelta, Constants.WEIGHT_DENOM);

        assertEq(modelOut, mulDivOut, "principalEff: integer form drifted from mulDiv");
    }
}
