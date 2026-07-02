// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";
import {IFurnace} from "src/interfaces/IFurnace.sol";
import {MineCoreHelper} from "src/MineCoreHelper.sol";

import {MineCoreHarness} from "./MineCoreHarness.sol";

/// @notice Test-only MineCore harness that mirrors `_settlePrevKingClaim` and records gas snapshots.
/// @dev Keep `probeSettlePrevKingClaim` in sync with `src/MineCore.sol::_settlePrevKingClaim`.
contract MineCoreGasProbeHarness is MineCoreHarness {
    struct SettleGasProbe {
        uint256 gasEntry;
        uint256 gasBeforeEnter;
        uint256 gasRequestedForEnter;
        uint256 gasAfterEnterOrCatch;
        uint256 gasAfterSettle;
        uint8 outcome;
    }

    uint8 internal constant OUTCOME_ZERO_CLAIM = 0;
    uint8 internal constant OUTCOME_DISABLED = 1;
    uint8 internal constant OUTCOME_PRECHECK_SKIPPED = 2;
    uint8 internal constant OUTCOME_RESOLUTION_SKIPPED = 3;
    uint8 internal constant OUTCOME_FURNACE_ZERO = 4;
    uint8 internal constant OUTCOME_WIRING_FAILED = 5;
    uint8 internal constant OUTCOME_ENTER_SUCCEEDED = 6;
    uint8 internal constant OUTCOME_ENTER_CAUGHT = 7;

    constructor(address claim_, address ve_, address royalties_, address initialOwner)
        MineCoreHarness(claim_, ve_, royalties_, initialOwner)
    {}

    function settleClaimMinGasForTest() external pure returns (uint256) {
        return SETTLE_CLAIM_MIN_GAS;
    }

    function settleClaimEnterReserveGasForTest() external pure returns (uint256) {
        return SETTLE_CLAIM_ENTER_RESERVE_GAS;
    }

    function probeOutcomeEnterSucceeded() external pure returns (uint8) {
        return OUTCOME_ENTER_SUCCEEDED;
    }

    function probeOutcomeEnterCaught() external pure returns (uint8) {
        return OUTCOME_ENTER_CAUGHT;
    }

    function probeSettlePrevKingClaim(uint256 reignId, address recipient, uint256 claimAmount)
        external
        returns (SettleGasProbe memory probe)
    {
        probe.gasEntry = gasleft();

        if (claimAmount == 0) {
            probe.outcome = OUTCOME_ZERO_CLAIM;
            probe.gasAfterSettle = gasleft();
            return probe;
        }

        // Gas pre-check: credit for a later force-locked withdrawal instead of attempting the lock.
        if (gasleft() < SETTLE_CLAIM_MIN_GAS) {
            _creditPendingKingClaim(recipient, claimAmount);
            emit Events.KingAutoLockSkipped(reignId, recipient, claimAmount, 0xFF);
            probe.outcome = OUTCOME_PRECHECK_SKIPPED;
            probe.gasAfterSettle = gasleft();
            return probe;
        }

        // Mint the King-stream CLAIM to this contract (backs the lock or the pending credit).
        claim.mint(address(this), claimAmount);

        IFurnace f = furnace;
        address furnaceAddr = address(f);

        if (furnaceAddr == address(0)) {
            pendingKingClaim[recipient] += claimAmount;
            totalPendingKingClaim += claimAmount;
            emit Events.KingClaimCredited(recipient, claimAmount);
            emit Events.KingAutoLockFailed(
                reignId, recipient, claimAmount, abi.encodeWithSelector(Errors.ZeroAddress.selector)
            );
            probe.outcome = OUTCOME_FURNACE_ZERO;
            probe.gasAfterSettle = gasleft();
            return probe;
        }
        if (!_isReciprocallyWiredFurnace(furnaceAddr)) {
            pendingKingClaim[recipient] += claimAmount;
            totalPendingKingClaim += claimAmount;
            emit Events.KingClaimCredited(recipient, claimAmount);
            emit Events.KingAutoLockFailed(
                reignId, recipient, claimAmount, abi.encodeWithSelector(Errors.WiringMismatch.selector)
            );
            probe.outcome = OUTCOME_WIRING_FAILED;
            probe.gasAfterSettle = gasleft();
            return probe;
        }

        KingAutoLockConfig storage cfg = kingAutoLockConfig[recipient];

        // Destination: an explicitly selected lock first, then the pinned create-once lock.
        uint256 preResolvedTokenId = cfg.targetTokenId != 0 ? cfg.targetTokenId : cfg.pinnedTokenId;

        uint256 targetTokenId;
        uint256 durationSeconds;
        bool createAutoMax;
        if (preResolvedTokenId != 0) {
            (bool resolved, uint256 rTokenId, uint256 rDuration, bool rAutoMax,) = MineCoreHelper(_helper)
                .resolveKingAutoLockDestination(address(ve), recipient, preResolvedTokenId, 0, false);
            if (resolved) {
                targetTokenId = rTokenId;
                durationSeconds = rDuration;
                createAutoMax = rAutoMax;
            } else {
                if (cfg.targetTokenId == 0 && cfg.pinnedTokenId != 0) cfg.pinnedTokenId = 0;
                targetTokenId = 0;
                durationSeconds = Constants.MAX_LOCK_DURATION;
                createAutoMax = true;
            }
        } else {
            targetTokenId = 0;
            durationSeconds = Constants.MAX_LOCK_DURATION;
            createAutoMax = true;
        }

        uint256 minVeOut = cfg.minVeOut;
        if (minVeOut == 0) minVeOut = 1;

        _forceApprove(IERC20(address(claim)), furnaceAddr, claimAmount);

        probe.gasBeforeEnter = gasleft();
        uint256 _gasLeft = gasleft();
        uint256 gasForEnter = _gasLeft > SETTLE_CLAIM_ENTER_RESERVE_GAS ? _gasLeft - SETTLE_CLAIM_ENTER_RESERVE_GAS : 0;
        probe.gasRequestedForEnter = gasForEnter;

        try f.enterWithClaimFor{gas: gasForEnter}(
            recipient, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut
        ) returns (
            uint256 tokenIdUsed
        ) {
            probe.gasAfterEnterOrCatch = gasleft();

            _bestEffortResetApproval(IERC20(address(claim)), furnaceAddr);

            if (targetTokenId == 0 && cfg.pinnedTokenId == 0) {
                cfg.pinnedTokenId = tokenIdUsed;
            }

            emit Events.KingAutoLockExecuted(reignId, recipient, claimAmount, tokenIdUsed);
            probe.outcome = OUTCOME_ENTER_SUCCEEDED;
        } catch {
            probe.gasAfterEnterOrCatch = gasleft();

            bytes memory bounded = _boundedRevertData();

            if (targetTokenId == 0 && cfg.targetTokenId == 0) {
                cfg.pinnedTokenId = 0;
            }

            _bestEffortResetApproval(IERC20(address(claim)), furnaceAddr);

            pendingKingClaim[recipient] += claimAmount;
            totalPendingKingClaim += claimAmount;
            emit Events.KingClaimCredited(recipient, claimAmount);

            emit Events.KingAutoLockFailed(reignId, recipient, claimAmount, bounded);
            probe.outcome = OUTCOME_ENTER_CAUGHT;
        }

        probe.gasAfterSettle = gasleft();
    }
}
