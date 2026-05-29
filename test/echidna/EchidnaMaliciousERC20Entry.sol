// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MaliciousFeeOnTransferERC20} from "../mocks/MaliciousFeeOnTransferERC20.sol";
import {MaliciousRebaseERC20} from "../mocks/MaliciousRebaseERC20.sol";
import {MaliciousReentrantERC20} from "../mocks/MaliciousReentrantERC20.sol";

/// @title Adversarial entry-token harness.
/// @notice Drives `Furnace.enterWithToken` and `MineCore.takeoverWithToken`
///         with three classes of misbehaving ERC20:
///         - fee-on-transfer (skims a percentage on every transfer)
///         - rebase (mutates `balanceOf` without a transfer)
///         - transfer-callback (reentrant call on every transfer)
///
///         The protocol's intended posture is to refuse all three at the
///         registry layer via `setFurnaceEntryTokenExactReceiptSafe(false)`
///         or by leaving them disabled. Properties below verify that any
///         path that DOES accept one of these tokens either reverts cleanly
///         or delivers the exact `minVeOut` / `minEthOut` the caller
///         requested. No silent shortfall is permitted.
contract EchidnaMaliciousERC20Entry is EchidnaSetup {
    MaliciousFeeOnTransferERC20 internal feeToken;
    MaliciousRebaseERC20 internal rebaseToken;
    MaliciousReentrantERC20 internal reentrantToken;

    address internal feeTokenWethPool;
    address internal rebaseTokenWethPool;
    address internal reentrantTokenWethPool;

    bool internal sawFurnaceEntrySilentShortfall;
    bool internal sawTakeoverSilentShortfall;
    bool internal sawReentrancyBypass;

    constructor() payable {
        _deployAndWire();

        feeToken = new MaliciousFeeOnTransferERC20("FeeToken", "FEE", 100, address(0xDEAD));
        rebaseToken = new MaliciousRebaseERC20("RebaseToken", "REB");
        reentrantToken = new MaliciousReentrantERC20("ReentrantToken", "REE");

        feeTokenWethPool = address(new MockERC20("FEE-WETH Pool", "FEEWETH"));
        rebaseTokenWethPool = address(new MockERC20("REB-WETH Pool", "REBWETH"));
        reentrantTokenWethPool = address(new MockERC20("REE-WETH Pool", "REEWETH"));

        dexRouter.setPoolFor(address(feeToken), address(weth), false, mockFactory, feeTokenWethPool);
        dexRouter.setPoolFor(address(rebaseToken), address(weth), false, mockFactory, rebaseTokenWethPool);
        dexRouter.setPoolFor(address(reentrantToken), address(weth), false, mockFactory, reentrantTokenWethPool);

        // Configure all three tokens as enabled for entry. The protocol must
        // either revert or deliver exactly `minVeOut` / `minEthOut`.
        furnaceRegistry.setTokenConfig(address(feeToken), true, false, false, address(0), false, feeTokenWethPool);
        furnaceRegistry.setTokenConfig(address(rebaseToken), true, false, false, address(0), false, rebaseTokenWethPool);
        furnaceRegistry.setTokenConfig(
            address(reentrantToken), true, false, false, address(0), false, reentrantTokenWethPool
        );

        // Mark fee + rebase as exact-receipt-unsafe so the Furnace gate refuses
        // them. The reentrant token is left exact-receipt-safe so we can drive
        // the reentrancy attempt against the live entry path.
        furnaceRegistry.setFurnaceEntryTokenExactReceiptSafe(address(feeToken), false);
        furnaceRegistry.setFurnaceEntryTokenExactReceiptSafe(address(rebaseToken), false);
        furnaceRegistry.setFurnaceEntryTokenExactReceiptSafe(address(reentrantToken), true);

        mineCoreRegistry.setTokenConfig(address(feeToken), true, false, false, address(0), false, feeTokenWethPool);
        mineCoreRegistry.setTokenConfig(
            address(rebaseToken), true, false, false, address(0), false, rebaseTokenWethPool
        );
        mineCoreRegistry.setTokenConfig(
            address(reentrantToken), true, false, false, address(0), false, reentrantTokenWethPool
        );
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_furnaceEntryWithFeeToken(uint256 amount, uint256 durationSeconds, uint256 minVeOut) public {
        if (amount < 1e18) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (minVeOut > type(uint128).max) minVeOut = uint256(type(uint128).max);

        feeToken.mint(address(this), amount);
        feeToken.approve(address(furnace), amount);

        uint256 veBefore = ve.veBalanceOf(address(this));
        try furnace.enterWithToken(address(feeToken), amount, 0, durationSeconds, false, minVeOut) {
            uint256 veDelta = ve.veBalanceOf(address(this)) - veBefore;
            if (veDelta < minVeOut) sawFurnaceEntrySilentShortfall = true;
        } catch {}
    }

    function action_furnaceEntryWithRebaseToken(uint256 amount, uint256 durationSeconds, uint256 minVeOut) public {
        if (amount < 1e18) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (minVeOut > type(uint128).max) minVeOut = uint256(type(uint128).max);

        rebaseToken.mint(address(this), amount);
        rebaseToken.approve(address(furnace), amount);

        uint256 veBefore = ve.veBalanceOf(address(this));
        try furnace.enterWithToken(address(rebaseToken), amount, 0, durationSeconds, false, minVeOut) {
            uint256 veDelta = ve.veBalanceOf(address(this)) - veBefore;
            if (veDelta < minVeOut) sawFurnaceEntrySilentShortfall = true;
        } catch {}
    }

    function action_rebaseShrink(uint256 factorBps) public {
        if (factorBps == 0 || factorBps > 10_000) factorBps = factorBps % 9_900 + 100;
        rebaseToken.rebase(factorBps);
    }

    function action_furnaceEntryWithReentrantToken(uint256 amount, uint256 durationSeconds, uint256 minVeOut) public {
        if (amount < 1e18) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (minVeOut > type(uint128).max) minVeOut = uint256(type(uint128).max);

        reentrantToken.mint(address(this), amount);
        reentrantToken.approve(address(furnace), amount);

        // Configure the reentrant callback to attempt a second entry on the
        // same token mid-transfer. The Furnace nonReentrant guard MUST catch
        // the reentrant call. We detect a guard bypass by counting NFT mints
        // that happen during the outer call: a successful outer entry mints
        // exactly one NFT; a successful reentrant inner entry would mint a
        // second one in the same transaction. Reentrant inner reverts (the
        // expected outcome) leave nextTokenId at +1.
        bytes memory reentrantPayload = abi.encodeWithSelector(
            furnace.enterWithToken.selector, address(reentrantToken), 1, uint256(0), durationSeconds, false, uint256(0)
        );
        reentrantToken.setReentrantCall(address(furnace), reentrantPayload);

        uint256 nextTokenIdBefore = ve.nextTokenId();
        bool outerOk;
        try furnace.enterWithToken(address(reentrantToken), amount, 0, durationSeconds, false, minVeOut) {
            outerOk = true;
        } catch {
            outerOk = false;
        }
        uint256 nextTokenIdAfter = ve.nextTokenId();
        uint256 mintCount = nextTokenIdAfter - nextTokenIdBefore;

        // Outer-success-path bypass: outer succeeded AND a second NFT was
        // minted in the same call (i.e. the inner reentrant entry also
        // succeeded). Outer-revert-path bypass: outer reverted but an NFT
        // was still minted (the reentrant inner committed despite the
        // outer's failure to settle).
        if (outerOk && mintCount > 1) sawReentrancyBypass = true;
        if (!outerOk && mintCount > 0) sawReentrancyBypass = true;

        reentrantToken.setReentrantCall(address(0), "");
    }

    function action_takeoverWithFeeToken(uint256 amount, uint256 minEthOut) public {
        if (amount < 1e18) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;

        feeToken.mint(address(this), amount);
        feeToken.approve(address(mineCore), amount);

        // Snapshot the protocol's ETH inventory: any ETH that lands in
        // mineCore + royalties as a result of this call must satisfy the
        // requested minEthOut floor. Otherwise the takeover delivered less
        // value than the caller agreed to.
        uint256 systemEthBefore = address(mineCore).balance + address(royalties).balance;
        try mineCore.takeoverWithToken(address(feeToken), amount, minEthOut, type(uint256).max) {
            uint256 systemEthAfter = address(mineCore).balance + address(royalties).balance;
            uint256 delivered = systemEthAfter > systemEthBefore ? systemEthAfter - systemEthBefore : 0;
            if (minEthOut > 0 && delivered < minEthOut) sawTakeoverSilentShortfall = true;
        } catch {}
    }

    function action_takeoverWithRebaseToken(uint256 amount, uint256 minEthOut) public {
        if (amount < 1e18) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;

        rebaseToken.mint(address(this), amount);
        rebaseToken.approve(address(mineCore), amount);

        uint256 systemEthBefore = address(mineCore).balance + address(royalties).balance;
        try mineCore.takeoverWithToken(address(rebaseToken), amount, minEthOut, type(uint256).max) {
            uint256 systemEthAfter = address(mineCore).balance + address(royalties).balance;
            uint256 delivered = systemEthAfter > systemEthBefore ? systemEthAfter - systemEthBefore : 0;
            if (minEthOut > 0 && delivered < minEthOut) sawTakeoverSilentShortfall = true;
        } catch {}
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @notice The Furnace entry path MUST NOT silently deliver less ve than
    ///         `minVeOut` for any entry token. Either revert or deliver.
    function echidna_furnace_entry_no_silent_shortfall() public view returns (bool) {
        return !sawFurnaceEntrySilentShortfall;
    }

    /// @notice The MineCore takeover path MUST NOT silently accept a token
    ///         payment that fails to deliver `minEthOut` to the protocol.
    function echidna_takeover_no_silent_shortfall() public view returns (bool) {
        return !sawTakeoverSilentShortfall;
    }

    /// @notice A reentrant token MUST NOT successfully reenter the Furnace
    ///         entry path mid-transfer. ReentrancyGuard MUST hold.
    function echidna_furnace_entry_reentrancy_guard_holds() public view returns (bool) {
        return !sawReentrancyBypass;
    }
}
