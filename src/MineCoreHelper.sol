// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";

/// @notice Externalized validation and math helper for MineCore runtime bytecode reduction.
/// @dev Deployed from the MineCore constructor so deploy scripts keep the same constructor args.
contract MineCoreHelper {
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_CLAIM_TOKEN = bytes4(keccak256("claimToken()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));
    bytes4 internal constant _SEL_SHAREHOLDER_ROYALTIES = bytes4(keccak256("shareholderRoyalties()"));
    bytes4 internal constant _SEL_ENTRY_TOKEN_REGISTRY = bytes4(keccak256("entryTokenRegistry()"));

    uint8 internal constant KING_AUTOLOCK_REASON_NOT_OWNER = 1;
    uint8 internal constant KING_AUTOLOCK_REASON_LISTED = 2;
    uint8 internal constant KING_AUTOLOCK_REASON_EXPIRED = 3;
    uint8 internal constant KING_AUTOLOCK_REASON_INVALID_TOKEN_ID = 4;
    uint8 internal constant KING_AUTOLOCK_REASON_INVALID_DURATION = 5;

    /// @dev Returns true when `a` has executable contract code AND is NOT an EIP-7702
    ///      delegation designator. A delegated EOA presents `code.length == 23` whose first
    ///      three bytes are `0xEF 0x01 0x00`; such an account would otherwise pass any
    ///      `code.length != 0` check while still being controlled by the underlying EOA's
    ///      delegation tuple. Wiring/admission sites use this to keep delegated EOAs out of
    ///      every protocol-root surface (claim, ve, royalties, furnace, hub, registry, router,
    ///      factory, wrappedNative, claimToken).
    function _isRealContract(address a) internal view returns (bool real) {
        uint256 size = a.code.length;
        if (size == 0) return false;
        if (size == 23) {
            bytes32 head;
            assembly ("memory-safe") {
                extcodecopy(a, 0x0, 0, 3)
                head := mload(0x0)
            }
            if (bytes3(head) == bytes3(0xef0100)) return false;
        }
        real = true;
    }

    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)

            let success := staticcall(100000, target, ptr, 0x04, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    out := and(mload(ptr), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    /// @notice Best-effort genesis-guardian recognizer used by MineCore to grant the genesis
    ///         guardian transient permissions during the launch window.
    /// @dev Returns `false` for `address(0)`, bare EOAs, EIP-7702-delegated EOAs, or any
    ///      candidate whose `mineCore()`/`claim()` backpointers do not match the live roots.
    function isCanonicalGenesisGuardian(address mineCore_, address claim_, address candidate)
        external
        view
        returns (bool)
    {
        if (candidate == address(0) || !_isRealContract(candidate)) return false;
        if (_staticcallAddress(candidate, _SEL_MINE_CORE) != mineCore_) return false;
        if (_staticcallAddress(candidate, _SEL_CLAIM) != claim_) return false;
        return true;
    }

    /// @dev Deployment-time reciprocal root validation for MineCore immutables.
    ///      The shipped VeClaimNFT exposes `claimToken()` immutably and the shipped
    ///      ShareholderRoyalties exposes `ve()` immutably. If either live surface is
    ///      present and already disagrees with the MineCore constructor args, fail
    ///      closed before ClaimToken can ever freeze to a split-brain core. Likewise,
    ///      if ClaimToken is already wired to a different MineCore, fail before the new
    ///      MineCore can be deployed into a permanently non-minting configuration.
    ///
    ///      If a contract omits these getters or returns address(0), those roots are treated
    ///      as unknown and do not trigger a mismatch revert.
    function requireCanonicalCoreRoots(address mineCore_, address claim_, address ve_, address royalties_)
        external
        view
    {
        if (claim_ == address(0) || ve_ == address(0) || royalties_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (!_isRealContract(claim_) || !_isRealContract(ve_) || !_isRealContract(royalties_)) {
            revert Errors.NotAContract();
        }

        address claimMineCore = _staticcallAddress(claim_, _SEL_MINE_CORE);
        if (mineCore_ != address(0) && claimMineCore != address(0) && claimMineCore != mineCore_) {
            revert Errors.WiringMismatch();
        }

        address veClaim = _staticcallAddress(ve_, _SEL_CLAIM_TOKEN);
        if (veClaim != address(0) && veClaim != claim_) revert Errors.WiringMismatch();

        address royaltiesVe = _staticcallAddress(royalties_, _SEL_VE);
        if (royaltiesVe != address(0) && royaltiesVe != ve_) revert Errors.WiringMismatch();
    }

    /// @dev Returns `false` unless the live Furnace still belongs to the same MineCore / Ve /
    ///      ShareholderRoyalties bundle. MineCore should treat a `false` result as a hard wiring
    ///      failure (revert).
    function isReciprocallyWiredFurnace(
        address mineCore_,
        address claim_,
        address ve_,
        address royalties_,
        address furnace_
    ) public view returns (bool) {
        if (furnace_ == address(0) || ve_ == address(0) || royalties_ == address(0)) return false;
        if (!_isRealContract(furnace_) || !_isRealContract(ve_) || !_isRealContract(royalties_)) return false;

        if (_staticcallAddress(furnace_, _SEL_MINE_CORE) != mineCore_) return false;
        if (_staticcallAddress(furnace_, _SEL_CLAIM) != claim_) return false;
        if (_staticcallAddress(furnace_, _SEL_VE) != ve_) return false;
        if (_staticcallAddress(furnace_, _SEL_SHAREHOLDER_ROYALTIES) != royalties_) return false;

        if (_staticcallAddress(ve_, _SEL_FURNACE) != furnace_) return false;
        if (_staticcallAddress(ve_, _SEL_CLAIM_TOKEN) != claim_) return false;

        if (_staticcallAddress(royalties_, _SEL_VE) != ve_) return false;
        if (_staticcallAddress(royalties_, _SEL_FURNACE) != furnace_) return false;
        if (_staticcallAddress(royalties_, _SEL_MINE_CORE) != mineCore_) return false;
        return true;
    }

    /// @notice Return true when `furnace_` uses the same EntryTokenRegistry as `mineCoreRegistry_`.
    /// Production wiring must keep these registries separate so that onboarding tokens configured
    /// for Furnace cannot be silently reused for MineCore takeover.
    function sharesEntryTokenRegistry(address furnace_, address mineCoreRegistry_) public view returns (bool) {
        if (furnace_ == address(0) || mineCoreRegistry_ == address(0)) return false;
        if (!_isRealContract(furnace_)) return false;
        address furnaceRegistry = _staticcallAddress(furnace_, _SEL_ENTRY_TOKEN_REGISTRY);
        return furnaceRegistry != address(0) && furnaceRegistry == mineCoreRegistry_;
    }

    function requireCanonicalDelegationHub(
        address mineCore_,
        address claim_,
        address ve_,
        address royalties_,
        address furnace_,
        address hub
    ) external view {
        if (hub == address(0)) revert Errors.ZeroAddress();
        if (!_isRealContract(hub)) revert Errors.NotAContract();
        if (!isReciprocallyWiredFurnace(mineCore_, claim_, ve_, royalties_, furnace_)) {
            revert Errors.WiringMismatch();
        }
        if (_staticcallAddress(furnace_, _SEL_DELEGATION_HUB) != hub) revert Errors.WiringMismatch();
    }

    /// @notice Validates and returns the router/factory/wrappedNative tuple from the
    ///         caller-supplied EntryTokenRegistry, asserting the registry's claim token
    ///         matches the canonical `claim_`.
    /// @dev `getRouterConfig()` is wrapped in a `try/catch` so a hostile registry cannot
    ///      DoS callers by reverting with arbitrarily large revert data; any revert is
    ///      collapsed to `RouterConfigNotSet`. Each returned root is also checked against
    ///      `_isRealContract` to keep EIP-7702-delegated EOAs out of the router surface.
    function getValidatedRouterConfig(address regAddr, address claim_)
        external
        view
        returns (address router, address factory, address wrappedNative)
    {
        if (regAddr == address(0) || !_isRealContract(regAddr)) revert Errors.RouterConfigNotSet();

        address claimToken = address(0);
        try IEntryTokenRegistry(regAddr).getRouterConfig() returns (address r, address f, address wn, address ct) {
            (router, factory, wrappedNative, claimToken) = (r, f, wn, ct);
        } catch {
            revert Errors.RouterConfigNotSet();
        }
        if (router == address(0) || factory == address(0) || wrappedNative == address(0) || claimToken == address(0)) {
            revert Errors.RouterConfigNotSet();
        }

        if (
            !_isRealContract(router) || !_isRealContract(factory) || !_isRealContract(wrappedNative)
                || !_isRealContract(claimToken)
        ) {
            revert Errors.NotAContract();
        }

        if (claimToken != claim_) revert Errors.InvalidToken();
    }

    /// @notice Reverting variant of the king auto-lock existing-target validator.
    /// @dev Both `ownerOf` and `getLockInfo` are wrapped in `try/catch`. Any failure on the
    ///      lock-info read maps to `InvalidToken`, mirroring the symmetric ownership-check
    ///      semantics. This keeps a hostile or asymmetric `ve_` from propagating raw revert
    ///      data through MineCore's caller frame.
    function validateKingAutoLockExistingTarget(
        address ve_,
        address user,
        uint256 targetTokenId,
        uint32 durationSeconds
    ) external view {
        address tokenOwner = address(0);
        try IVeClaimNFT(ve_).ownerOf(targetTokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (tokenOwner != user) revert Errors.NotAuthorized();

        uint256 lockEnd = 0;
        bool autoMaxExisting = false;
        bool listed = false;
        try IVeClaimNFT(ve_).getLockInfo(targetTokenId) returns (uint256, uint256 le, bool am, bool l) {
            lockEnd = le;
            autoMaxExisting = am;
            listed = l;
        } catch {
            revert Errors.InvalidToken();
        }
        if (listed) revert Errors.LockListedOrFrozen();
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();
        if (autoMaxExisting && durationSeconds != 0 && durationSeconds != Constants.MAX_LOCK_DURATION) {
            revert Errors.InvalidDuration();
        }
    }

    /// @notice Best-effort ("reason-code") variant of the king auto-lock destination resolver.
    /// @dev MUST NOT revert in the canonical paths. Returns `(false, ..., reasonCode)` for
    ///      every recognized failure so MineCore's `_settlePrevKingClaim` can fall back to
    ///      paying the prior king's CLAIM share in liquid form. Reason codes:
    ///      1=NotOwner, 2=Listed, 3=Expired, 4=InvalidTokenId, 5=InvalidDuration.
    function resolveKingAutoLockDestination(
        address ve_,
        address king,
        uint256 tokenId,
        uint32 durationSeconds,
        bool createAutoMax
    )
        external
        view
        returns (
            bool ok,
            uint256 resolvedTokenId,
            uint256 resolvedDuration,
            bool resolvedCreateAutoMax,
            uint8 reasonCode
        )
    {
        if (tokenId != 0) {
            return _resolveExistingToken(ve_, king, tokenId, durationSeconds);
        }
        if (durationSeconds != 0) {
            if (durationSeconds < Constants.MIN_LOCK_DURATION || durationSeconds > Constants.MAX_LOCK_DURATION) {
                return (false, 0, 0, false, KING_AUTOLOCK_REASON_INVALID_DURATION);
            }
        }
        return (true, 0, uint256(durationSeconds), createAutoMax, 0);
    }

    function _resolveExistingToken(address ve_, address king, uint256 tokenId, uint32 durationSeconds)
        internal
        view
        returns (bool, uint256, uint256, bool, uint8)
    {
        address tokenOwner = address(0);
        try IVeClaimNFT(ve_).ownerOf(tokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            return (false, 0, 0, false, KING_AUTOLOCK_REASON_INVALID_TOKEN_ID);
        }
        if (tokenOwner != king) return (false, 0, 0, false, KING_AUTOLOCK_REASON_NOT_OWNER);

        uint256 lockEnd = 0;
        bool autoMaxExisting = false;
        bool listed = false;
        try IVeClaimNFT(ve_).getLockInfo(tokenId) returns (uint256, uint256 le, bool am, bool l) {
            lockEnd = le;
            autoMaxExisting = am;
            listed = l;
        } catch {
            return (false, 0, 0, false, KING_AUTOLOCK_REASON_INVALID_TOKEN_ID);
        }
        if (listed) return (false, 0, 0, false, KING_AUTOLOCK_REASON_LISTED);
        if (lockEnd <= block.timestamp) return (false, 0, 0, false, KING_AUTOLOCK_REASON_EXPIRED);

        if (autoMaxExisting) {
            return (true, tokenId, Constants.MAX_LOCK_DURATION, false, 0);
        }

        uint256 remaining = lockEnd - block.timestamp;
        // The King force-lock slice must land in a lock that retains the anti-recycling horizon the
        // 50% liquid clamp assumes. A non-AutoMax lock is only eligible when its remaining duration
        // is at least KING_FORCE_LOCK_MIN_DURATION; otherwise the caller falls back to the default
        // create-once AutoMax lock. This prevents a King from collapsing the force-locked remainder
        // to a self-created short lock and unlocking ~100% of the mined CLAIM within days.
        if (remaining < Constants.KING_FORCE_LOCK_MIN_DURATION) {
            return (false, 0, 0, false, KING_AUTOLOCK_REASON_INVALID_DURATION);
        }

        uint256 desired = durationSeconds == 0 ? remaining : uint256(durationSeconds);
        if (desired < remaining) desired = remaining;
        return (true, tokenId, desired, false, 0);
    }

    /// @notice Linear-decay takeover price from `referencePrice` down to `Constants.TAKEOVER_PRICE_FLOOR`
    ///         over `Constants.TAKEOVER_DECAY_PERIOD`, clamped at the floor.
    /// @dev Pure. Monotonically non-increasing in `timestamp` for fixed (currentKing,
    ///      currentReignStartTime, referencePrice). Returns `floor` when `currentKing == 0`
    ///      (bootstrap) and when `timestamp <= currentReignStartTime`. The decayed term is
    ///      computed via `mulDiv` (floor-rounded), so the returned price is at most 1 wei
    ///      above the real-valued curve (vault-favorable).
    function takeoverPrice(
        address currentKing,
        uint256 currentReignStartTime,
        uint256 referencePrice,
        uint256 timestamp
    ) external pure returns (uint256 price) {
        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        if (currentKing == address(0)) return floor;

        uint256 start = currentReignStartTime;
        uint256 t = timestamp <= start ? 0 : (timestamp - start);

        uint256 decayPeriod = Constants.TAKEOVER_DECAY_PERIOD;
        if (t >= decayPeriod) return floor;

        uint256 ref = referencePrice;
        if (ref <= floor) return floor;

        uint256 decayed = Math.mulDiv(ref, t, decayPeriod);
        price = ref - decayed;
        if (price < floor) price = floor;
    }

    /// @notice Resolve the minimal set of delegation permission bits used when a delegate
    ///         changes the reign's ETH and/or CLAIM recipient on behalf of `king`.
    /// @dev Pure. Reverts `NotAuthorized` if the delegate lacks any of the four split
    ///      permission bits, or if a per-leg "to-self/to-king" constraint is violated.
    ///      The function returns the OR of the consumed permission bits so MineCore can
    ///      account for delegation usage exactly.
    function resolveDelegatedReignRecipientPerms(
        uint256 perms,
        address sender,
        address king,
        address ethRecipient,
        address currentEth,
        address claimRecipient,
        address currentClaim
    ) external pure returns (uint256 delegatedPermsUsed) {
        bool ethChanged = ethRecipient != currentEth;
        bool claimChanged = claimRecipient != currentClaim;

        uint256 splitBits = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT
            | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT
            | DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY
            | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;
        if ((perms & splitBits) == 0) revert Errors.NotAuthorized();

        if (ethChanged) {
            if ((perms & DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT) != 0) {
                delegatedPermsUsed |= DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT;
            } else if ((perms & DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY) != 0) {
                if (ethRecipient != sender) revert Errors.NotAuthorized();
                delegatedPermsUsed |= DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY;
            } else {
                revert Errors.NotAuthorized();
            }
        }

        if (claimChanged) {
            if ((perms & DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT) != 0) {
                delegatedPermsUsed |= DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT;
            } else if ((perms & DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY) != 0) {
                if (claimRecipient != king) revert Errors.NotAuthorized();
                delegatedPermsUsed |= DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;
            } else {
                revert Errors.NotAuthorized();
            }
        }
    }

    /// @notice Furnace emission rate (per second) at `timestamp` under the piecewise-linear
    ///         decay schedule from `FURNACE_EMISSION_LAUNCH_RATE` down to
    ///         `FURNACE_EMISSION_FLOOR` over `EMISSION_DECAY_PERIOD`.
    /// @dev Pure. Monotonically non-increasing in `timestamp`. Returns the launch rate at
    ///      and before `emissionStartTime`, and the floor rate at or after the floor crossover.
    function getFurnaceEmissionRateAt(uint256 emissionStartTime, uint256 timestamp) external pure returns (uint256) {
        if (timestamp <= emissionStartTime) return Constants.FURNACE_EMISSION_LAUNCH_RATE;
        return _rateAt(
            timestamp - emissionStartTime, Constants.FURNACE_EMISSION_LAUNCH_RATE, Constants.FURNACE_EMISSION_FLOOR
        );
    }

    /// @notice Total KING emissions accrued in [`ts0`, `ts1`] under the king emission
    ///         schedule. Trapezoidal exact for the real-valued piecewise-linear rate;
    ///         the integer implementation may differ from a real-valued split by at
    ///         most ~1 wei per `mulDiv` floor-round (split-additivity holds within that
    ///         bound, see `testFuzz_kingEmittedSplitAdditivity`).
    function kingEmitted(uint256 emissionStartTime, uint256 ts0, uint256 ts1) external pure returns (uint256) {
        return _emitted(emissionStartTime, ts0, ts1, Constants.KING_EMISSION_LAUNCH_RATE, Constants.KING_EMISSION_FLOOR);
    }

    /// @notice Total Furnace emissions accrued in [`ts0`, `ts1`] under the furnace emission
    ///         schedule. See `kingEmitted` for trapezoidal-exactness and rounding notes.
    function furnaceEmitted(uint256 emissionStartTime, uint256 ts0, uint256 ts1) external pure returns (uint256) {
        return
            _emitted(
                emissionStartTime, ts0, ts1, Constants.FURNACE_EMISSION_LAUNCH_RATE, Constants.FURNACE_EMISSION_FLOOR
            );
    }

    function _rateAt(uint256 elapsed, uint256 launchRate, uint256 floorRate) internal pure returns (uint256 rate) {
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        if (launchRate <= floorRate) return floorRate;
        if (elapsed >= D) return floorRate;

        uint256 diff = launchRate - floorRate;
        uint256 dec = Math.mulDiv(diff, elapsed, D);
        rate = launchRate - dec;
        if (rate < floorRate) rate = floorRate;
    }

    /// @dev Compute total emissions between two timestamps using the trapezoidal rule
    ///      over a piecewise-linear rate schedule (linear decay from launchRate to floorRate
    ///      over EMISSION_DECAY_PERIOD, then constant at floorRate).
    ///      Because the rate function is piecewise-linear, the trapezoidal formula
    ///      `(r(t0) + r(t1)) / 2 * (t1 - t0)` yields the EXACT integral over the reals.
    ///      The Solidity implementation floor-rounds each `mulDiv`, so split-additivity holds
    ///      only within a tolerance of ~1 wei per floor-rounded multiplication. Tests assert
    ///      this with `assertApproxEqAbs(..., 2)`; downstream consumers must treat sub-wei
    ///      drift as a normal rounding artifact and never assume strict additive equality.
    function _emitted(uint256 emissionStartTime, uint256 ts0, uint256 ts1, uint256 launchRate, uint256 floorRate)
        internal
        pure
        returns (uint256 emitted)
    {
        if (ts1 <= ts0) return 0;
        if (ts1 <= emissionStartTime) return 0;
        if (ts0 < emissionStartTime) ts0 = emissionStartTime;

        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 floorTs = emissionStartTime + D;

        if (ts0 >= floorTs) {
            return floorRate * (ts1 - ts0);
        }

        if (ts1 <= floorTs) {
            uint256 t0 = ts0 - emissionStartTime;
            uint256 t1 = ts1 - emissionStartTime;
            uint256 r0 = _rateAt(t0, launchRate, floorRate);
            uint256 r1 = _rateAt(t1, launchRate, floorRate);
            return Math.mulDiv(r0 + r1, ts1 - ts0, 2);
        }

        uint256 t0b = ts0 - emissionStartTime;
        uint256 r0b = _rateAt(t0b, launchRate, floorRate);
        uint256 decayPart = Math.mulDiv(r0b + floorRate, floorTs - ts0, 2);
        uint256 floorPart = floorRate * (ts1 - floorTs);
        emitted = decayPart + floorPart;
    }
}
