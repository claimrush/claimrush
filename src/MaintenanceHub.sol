// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Errors} from "./lib/Errors.sol";
import {Constants} from "./lib/Constants.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IShareholderRoyalties} from "./interfaces/IShareholderRoyalties.sol";
import {IMarketRouter} from "./interfaces/IMarketRouter.sol";
import {IFurnace} from "./interfaces/IFurnace.sol";

/// @notice Permissionless maintenance entrypoint (v1.0.0).
/// @dev Spec: docs/spec/maintenance-hub-spec-v1.0.0.md
contract MaintenanceHub is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_ROYALTIES = bytes4(keccak256("royalties()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_MINE_MARKET = bytes4(keccak256("mineMarket()"));
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_CLAIM_TOKEN = bytes4(keccak256("claimToken()"));
    bytes4 internal constant _SEL_SHAREHOLDER_ROYALTIES = bytes4(keccak256("shareholderRoyalties()"));
    bytes4 internal constant _SEL_EXECUTE_AUTO_FURNACE = bytes4(keccak256("executeAutoFurnace(uint256,uint256)"));
    uint256 internal constant _OFFER_EXEC_GAS_CAP = 1_500_000;
    uint256 internal constant _OFFER_DEADLINE_GRACE = 300;

    /// @dev Sentinel address that receives stuck tokens via `rescueToken`.
    ///      Set once at deploy time; cannot be changed.
    address public immutable rescueRecipient;

    // ------------------------------------------------------------
    // External ABI types
    // ------------------------------------------------------------

    /// @notice Poke configuration.
    /// @dev Field order is ABI-bound per spec.
    struct PokeArgs {
        uint256[] offerIds;
        uint256 maxOffers;
    }

    // ------------------------------------------------------------
    // Events (MUST)
    // ------------------------------------------------------------

    event Poked(
        address caller,
        bool checkpointOk,
        bool flushOk,
        uint256 offersAttempted,
        uint256 offersSucceeded,
        bool furnaceTickSucceeded,
        uint256 bountyWethForwarded
    );

    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------
    // Wiring (no public getters; ABI is intentionally narrow)
    // ------------------------------------------------------------

    address private immutable marketRouter;
    address private immutable furnace;
    address private immutable ve;
    address private immutable royalties;
    IERC20 private immutable weth;

    /// @dev Reject EIP-7702 delegated EOAs masquerading as real contracts. A 7702 designator
    ///      is exactly the 23-byte sequence `0xEF 0x01 0x00 || delegate`, which would
    ///      otherwise satisfy `code.length != 0` and pass naive contract-check gates while
    ///      still being controlled by the underlying EOA's revocable delegation tuple.
    ///      Mirrors the peer pattern used in `DexAdapter._rejectDelegatedEOA` for behavior parity.
    function _rejectDelegatedEOA(address a) internal view {
        uint256 size = a.code.length;
        if (size == 0) revert Errors.NotAContract();
        if (size != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(a, ptr, 0, 3)
            prefix := mload(ptr)
        }
        if (prefix == 0xEF0100) revert Errors.NotAContract();
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory (prevents return-data bomb griefing).
    ///      Gas-bounded: forwards at most 100 000 gas to prevent untrusted callees from consuming
    ///      the caller's entire gas budget during wiring checks.
    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            mstore(0x00, sel)

            let success := staticcall(100000, target, 0x00, 0x04, 0x00, 0x20)
            if success {
                if iszero(lt(returndatasize(), 0x20)) {
                    out := and(mload(0x00), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    /// @dev Fail closed unless the immutable upkeep bundle still resolves to one canonical
    ///      MarketRouter / Furnace / VeClaimNFT / ShareholderRoyalties / MineCore / CLAIM tree.
    ///      `poke()` is intentionally best-effort, so a stale or split-brain hub must revert
    ///      before any sub-actions can partially operate on mixed deployments.
    function _requireCanonicalBundle() internal view {
        address claim = _staticcallAddress(ve, _SEL_CLAIM_TOKEN);
        address core = _staticcallAddress(royalties, _SEL_MINE_CORE);

        if (claim == address(0) || core == address(0)) revert Errors.WiringMismatch();
        if (claim.code.length == 0 || core.code.length == 0) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(marketRouter, _SEL_VE) != ve
                || _staticcallAddress(marketRouter, _SEL_ROYALTIES) != royalties
                || _staticcallAddress(marketRouter, _SEL_CLAIM) != claim || _staticcallAddress(furnace, _SEL_VE) != ve
                || _staticcallAddress(furnace, _SEL_CLAIM) != claim
                || _staticcallAddress(furnace, _SEL_SHAREHOLDER_ROYALTIES) != royalties
                || _staticcallAddress(furnace, _SEL_MINE_MARKET) != marketRouter
                || _staticcallAddress(furnace, _SEL_MINE_CORE) != core
                || _staticcallAddress(ve, _SEL_MINE_MARKET) != marketRouter
                || _staticcallAddress(ve, _SEL_FURNACE) != furnace
                || _staticcallAddress(royalties, _SEL_MINE_MARKET) != marketRouter
                || _staticcallAddress(royalties, _SEL_FURNACE) != furnace
                || _staticcallAddress(royalties, _SEL_VE) != ve || _staticcallAddress(core, _SEL_FURNACE) != furnace
                || _staticcallAddress(core, _SEL_ROYALTIES) != royalties || _staticcallAddress(core, _SEL_VE) != ve
                || _staticcallAddress(core, _SEL_CLAIM) != claim || _staticcallAddress(claim, _SEL_MINE_CORE) != core
        ) revert Errors.WiringMismatch();
    }

    constructor(
        address _marketRouter,
        address _furnace,
        address _ve,
        address _royalties,
        address _weth,
        address _rescueRecipient
    ) {
        if (
            _marketRouter == address(0) || _furnace == address(0) || _ve == address(0) || _royalties == address(0)
                || _weth == address(0) || _rescueRecipient == address(0)
        ) revert Errors.ZeroAddress();
        // Reject bare EOAs AND EIP-7702 delegated EOAs on every immutable contract root.
        // `rescueRecipient` is intentionally NOT subjected to this check because the spec
        // permits an EOA destination for stuck-token recovery. The five canonical roots,
        // by contrast, MUST be real contracts (or be permanently bricked at first poke if
        // a 7702 delegator later revokes its designation).
        _rejectDelegatedEOA(_marketRouter);
        _rejectDelegatedEOA(_furnace);
        _rejectDelegatedEOA(_ve);
        _rejectDelegatedEOA(_royalties);
        _rejectDelegatedEOA(_weth);

        marketRouter = _marketRouter;
        furnace = _furnace;
        ve = _ve;
        royalties = _royalties;
        weth = IERC20(_weth);
        rescueRecipient = _rescueRecipient;

        _requireCanonicalBundle();
    }

    // ------------------------------------------------------------
    // Rescue (stuck-token recovery)
    // ------------------------------------------------------------

    /// @notice Recover ERC-20 tokens accidentally sent to the hub.
    /// @dev    Permissionless call; tokens are always sent to the immutable `rescueRecipient`.
    ///         Cannot rescue WETH to prevent draining in-flight bounty deltas.
    function rescueToken(IERC20 token) external nonReentrant {
        if (address(token) == address(weth)) revert Errors.NotAuthorized();
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert Errors.AmountZero();
        token.safeTransfer(rescueRecipient, bal);
        emit TokenRescued(address(token), rescueRecipient, bal);
    }

    // ------------------------------------------------------------
    // Maintenance entrypoint
    // ------------------------------------------------------------

    /// @notice Execute best-effort upkeep.
    /// @dev This call is nonpayable; WETH bounties are forwarded to the caller.
    function poke(PokeArgs calldata args) external nonReentrant {
        _requireCanonicalBundle();

        uint256 wethBefore = weth.balanceOf(address(this));
        bool checkpointOk = false;
        bool flushOk = false;

        // 1) ve checkpoint (best-effort, explicitly gas-capped)
        // NOTE: checkpointGlobalState() and checkpointTotalVe() share the same
        // internal implementation (_checkpointGlobalStateInternal), so a single
        // checkpointGlobalState() call is sufficient to refresh global checkpoint state.
        // Cap at 1_000_000 gas: the global checkpoint is bounded by MAX_SLOPE_CHANGES_PER_CALL
        // and typical execution is well under 300k. The cap prevents a regressed canonical
        // VeClaimNFT upgrade from forwarding 63/64ths of remaining gas and starving the
        // market sweep / Furnace tick that follow in the same poke.
        try IVeClaimNFT(ve).checkpointGlobalState{gas: 1_000_000}() {
            checkpointOk = true;
        } catch {}

        // 2) Shareholder flush (best-effort, explicitly gas-capped)
        // Cap at 500_000 gas: matches Furnace.tick's outer cap and is the right order of
        // magnitude for a bounded ETH flush + index update. Same starvation-defense rationale
        // as the checkpoint cap above.
        try IShareholderRoyalties(royalties).flushPendingShareholderETH{gas: 500_000}() {
            flushOk = true;
        } catch {}

        // 3) Market sweep (bounded)
        uint256 maxOffersClamped = args.maxOffers;
        uint256 cap = Constants.MAX_MAINTENANCE_OFFERS_PER_CALL;
        if (maxOffersClamped > cap) maxOffersClamped = cap;

        uint256 offersAttempted = 0;
        uint256 offersSucceeded = 0;

        uint256 n = args.offerIds.length;
        if (n > maxOffersClamped) n = maxOffersClamped;

        address mr = marketRouter;
        bytes4 sel = _SEL_EXECUTE_AUTO_FURNACE;
        uint256 gasCap = _OFFER_EXEC_GAS_CAP;
        uint256 dl = block.timestamp + _OFFER_DEADLINE_GRACE;

        for (uint256 i = 0; i < n; ++i) {
            if (gasleft() < gasCap + 600_000) break;

            uint256 offerId = args.offerIds[i];
            if (offerId == 0) continue;
            offersAttempted += 1;

            bool ok;
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, sel)
                mstore(add(ptr, 0x04), offerId)
                mstore(add(ptr, 0x24), dl)
                ok := call(gasCap, mr, 0, ptr, 0x44, 0, 0)
                mstore(0x40, add(ptr, 0x60))
            }
            if (ok) offersSucceeded += 1;
        }

        // 4) Furnace tick - accrues LP rewards stream and overflow drip (best-effort)
        // Gas budget must cover: nonReentrant (~5k), _accrueLpStream with safeTransfer (~35k),
        // notifyRewards{gas:200k} on LpStakingVault7D, overflow drip math + FurnaceGuardHelper
        // external calls (~30k), _syncFurnaceReserve (~15k).  Total worst-case ~350-400k.
        bool furnaceTickSucceeded = false;
        try IFurnace(furnace).tick{gas: 500_000}() {
            furnaceTickSucceeded = true;
        } catch {
            // best-effort
        }

        // Bounty forwarding (WETH only)
        // Forward only the WETH delta realized during this poke so pre-existing hub balances
        // cannot be drained by the next arbitrary caller.
        // Use raw transfer inside try/catch so a WETH transfer failure does NOT roll back
        // all the best-effort maintenance work completed above.
        uint256 wethAfter = weth.balanceOf(address(this));
        uint256 wethBounty = wethAfter > wethBefore ? wethAfter - wethBefore : 0;
        if (wethBounty > 0) {
            try IERC20(address(weth)).transfer(msg.sender, wethBounty) returns (bool success) {
                if (!success) wethBounty = 0;
            } catch {
                wethBounty = 0;
            }
        }

        emit Poked(
            msg.sender, checkpointOk, flushOk, offersAttempted, offersSucceeded, furnaceTickSucceeded, wethBounty
        );
    }
}
