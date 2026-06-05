// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IMineCore} from "../src/interfaces/IMineCore.sol";
import {IFurnace} from "../src/interfaces/IFurnace.sol";
import {IVeClaimNFT} from "../src/interfaces/IVeClaimNFT.sol";
import {IVeClaimNFTLockStartView} from "../src/interfaces/IVeClaimNFTLockStartView.sol";
import {IClaimToken} from "../src/interfaces/IClaimToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDelegationHub} from "../src/interfaces/IDelegationHub.sol";
import {IShareholderRoyalties} from "../src/interfaces/IShareholderRoyalties.sol";
import {IMarketRouter} from "../src/interfaces/IMarketRouter.sol";
import {ILpStakingVault7D} from "../src/interfaces/ILpStakingVault7D.sol";
import {IEntryTokenRegistry} from "../src/interfaces/IEntryTokenRegistry.sol";
import {IGenesisLPVault24M} from "../src/interfaces/IGenesisLPVault24M.sol";
import {IMineCoreQuoter} from "../src/interfaces/IMineCoreQuoter.sol";
import {IFurnaceQuoter} from "../src/interfaces/IFurnaceQuoter.sol";

/// @title Interface selector pin invariants
/// @notice Pins 4-byte selectors for hot-path interface functions. A
///         selector pin does NOT prevent intentional ABI changes; it forces
///         the change to also update this test, surfacing the drift in code
///         review and protecting against silent rename / type-change /
///         hoist-to-external regressions.
/// @dev Coverage: takeover-flow, Furnace-entry-flow, lock lifecycle,
///      ClaimToken emission, delegation session, shareholder, marketplace,
///      LP staking, entry registry, genesis vault, and quoter hot paths.
contract InterfaceSelectorPin is Test {
    function test_iMineCore_selectors_pinned() public pure {
        assertEq(IMineCore.takeover.selector, bytes4(0x1b870fc5));
        assertEq(IMineCore.takeoverFor.selector, bytes4(0x22e1c200));
        assertEq(IMineCore.takeoverWithToken.selector, bytes4(0x8081bbd5));
        assertEq(IMineCore.getReignInfo.selector, bytes4(0x567fe498));
        assertEq(IMineCore.collectGenesisKingClaim.selector, bytes4(0xb01c8959));
    }

    function test_iFurnace_selectors_pinned() public pure {
        assertEq(IFurnace.enterWithEth.selector, bytes4(0x509933c5));
        assertEq(IFurnace.enterWithClaim.selector, bytes4(0x72786ee3));
        assertEq(IFurnace.enterWithToken.selector, bytes4(0xbcbbebe1));
        assertEq(IFurnace.sellLockToFurnaceFromMarket.selector, bytes4(0x36cf559d));
        assertEq(IFurnace.tick.selector, bytes4(0x3eaf5d9f));
        // Merge-with-bonus is the user-facing merge path: all merges flow through
        // Furnace so the bonus engine and slippage floor are reused.
        assertEq(IFurnace.mergeLocksWithBonus.selector, bytes4(0x3eda102c));
        assertEq(IFurnace.mergeLocksWithBonusFor.selector, bytes4(0xe6ebcb7b));
    }

    /// @notice Pin the auth-gated `__bonusAmmFromHelper(address,uint256,uint256,uint256)`
    ///         callback selector. Furnace's merge body is offloaded into FurnaceGuardHelper via
    ///         delegatecall (EIP-170 budget); the helper, running in Furnace's storage context,
    ///         calls back into Furnace with this selector to invoke `_applyBonusAmm`. Drift here
    ///         would either break the merge bonus path entirely (helper hits a missing selector)
    ///         or — if the selector were redirected to a different function — silently route
    ///         bonus-AMM math through the wrong logic. The function is intentionally NOT on
    ///         IFurnace (internal callback), so we pin via keccak256 of its raw signature.
    function test_furnace_bonusAmmFromHelper_selector_pinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("__bonusAmmFromHelper(address,uint256,uint256,uint256)"))),
            uint32(0x66735232),
            "Furnace.__bonusAmmFromHelper(address,uint256,uint256,uint256) selector pinned at 0x66735232"
        );
    }

    function test_iVeClaimNFT_selectors_pinned() public pure {
        assertEq(IVeClaimNFT.createLockFor.selector, bytes4(0xff59ebd1));
        // v1.0.0: Furnace-only merge sibling of extendLockToFor / addToLockFor.
        // The user-facing merge entrypoint is IFurnace.mergeLocksWithBonus.
        assertEq(IVeClaimNFT.mergeLocksFor.selector, bytes4(0x34b4429b));
        assertEq(IVeClaimNFT.unlock.selector, bytes4(0x6198e339));
        // `lockStartOf` is declared on the slim parent interface and inherited
        // by IVeClaimNFT. Solidity's `T.fn.selector` member access
        // resolves only against directly-declared members, so we pin the
        // selector through the parent. The compiled IVeClaimNFT ABI exposes
        // the same selector via inheritance.
        assertEq(IVeClaimNFTLockStartView.lockStartOf.selector, bytes4(0x580ddf60));
    }

    function test_iClaimToken_selectors_pinned() public pure {
        assertEq(IClaimToken.mint.selector, bytes4(0x40c10f19));
        assertEq(IClaimToken.burn.selector, bytes4(0x42966c68));
        // `transfer` is inherited from IERC20Metadata -> IERC20; see the
        // VeClaimNFT slim-slice note for why selectors of inherited members
        // must be pinned through the parent declaration.
        assertEq(IERC20.transfer.selector, bytes4(0xa9059cbb));
    }

    function test_iDelegationHub_selectors_pinned() public pure {
        assertEq(IDelegationHub.setSession.selector, bytes4(0xb8feaf83));
        assertEq(IDelegationHub.isAuthorized.selector, bytes4(0xaf0c98e6));
    }

    function test_iShareholderRoyalties_selectors_pinned() public pure {
        assertEq(IShareholderRoyalties.onTakeover.selector, bytes4(0xf1a66c6d));
        assertEq(IShareholderRoyalties.claimShareholder.selector, bytes4(0xab7aaaf5));
        assertEq(IShareholderRoyalties.claimShareholderForTo.selector, bytes4(0x8f83ebd8));
    }

    function test_iMarketRouter_selectors_pinned() public pure {
        assertEq(IMarketRouter.listLock.selector, bytes4(0xb1d09efe));
        assertEq(IMarketRouter.sellLockToFurnace.selector, bytes4(0x4942b9f1));
        assertEq(IMarketRouter.executeAutoFurnace.selector, bytes4(0xce065652));
    }

    function test_iLpStakingVault7D_selectors_pinned() public pure {
        assertEq(ILpStakingVault7D.stake.selector, bytes4(0xa694fc3a));
        assertEq(ILpStakingVault7D.harvestFeesToRewards.selector, bytes4(0x64d3f7e4));
    }

    function test_iEntryTokenRegistry_selectors_pinned() public pure {
        assertEq(IEntryTokenRegistry.setTokenConfig.selector, bytes4(0x93212ef5));
        assertEq(IEntryTokenRegistry.resolveFurnaceRoute.selector, bytes4(0x1fe07db2));
    }

    function test_iGenesisLPVault24M_selectors_pinned() public pure {
        assertEq(IGenesisLPVault24M.startLock.selector, bytes4(0x7fc54976));
        assertEq(IGenesisLPVault24M.extendLock.selector, bytes4(0x44ee3a1c));
    }

    function test_iQuoter_selectors_pinned() public pure {
        assertEq(IMineCoreQuoter.quoteTakeoverWithToken.selector, bytes4(0x1517b024));
        assertEq(IFurnaceQuoter.quoteEnterWithEth.selector, bytes4(0x7ccd86a9));
        assertEq(IFurnaceQuoter.quoteSellLockToFurnaceBreakdown.selector, bytes4(0xe3f06695));
    }
}
