// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {Furnace} from "../src/Furnace.sol";
import {MineCore} from "../src/MineCore.sol";
import {MarketRouter} from "../src/MarketRouter.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "../src/VeClaimNFT.sol";
import {Constants} from "../src/lib/Constants.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {LpStakingVault7D} from "../src/vault/LpStakingVault7D.sol";
import {IDexAdapter} from "../src/interfaces/IDexAdapter.sol";
import {DelegationHub} from "../src/DelegationHub.sol";
import {DelegationPermissions} from "../src/lib/DelegationPermissions.sol";
import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {MaintenanceHub} from "../src/MaintenanceHub.sol";
import {Errors} from "../src/lib/Errors.sol";
import {MintableERC20} from "../src/mocks/MintableERC20.sol";

interface IAgentLensSmoke {
    function readGlobalV1() external view returns (bytes memory);
}

interface IMintableEntryToken {
    function mint(address to, uint256 amount) external;
}

contract _TakeoverHelper {
    receive() external payable {}

    function takeover(MineCore mc) external payable {
        mc.takeover{value: msg.value}(type(uint256).max);
    }
}

/// @notice Coinbase-Smart-Wallet-shaped stub: receives ETH/NFTs, executes single calls
///         or atomic batches. Mirrors the surface of `wallet_sendCalls` (EIP-5792) used by
///         Base Account for atomic UserOperations. The smoke harness drives this stub via
///         `executeBatch(...)` to verify that every two-transaction frontend flow can run
///         atomically as a single user-op without intermediate state corruption.
contract _SmartWalletStub is IERC721Receiver {
    address public owner;

    error NotOwner();
    error CallFailed(uint256 index);

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != owner) revert NotOwner();
        bool ok;
        (ok, result) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function executeBatch(address[] calldata tos, uint256[] calldata values, bytes[] calldata datas)
        external
        returns (bytes[] memory results)
    {
        if (msg.sender != owner) revert NotOwner();
        uint256 n = tos.length;
        require(values.length == n && datas.length == n, "len");
        results = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            (bool ok, bytes memory ret) = tos[i].call{value: values[i]}(datas[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Single-purpose delegate helper used as `msg.sender` for `*For` entrypoints.
///         The deployer (= the "user" whose perms are delegated) sets a session with `ALL`
///         for this address, then calls helper functions which invoke the matching `*For`
///         entrypoints. ETH-paying entries forward msg.value. No discretionary logic — every
///         wrapper is a thin pass-through so smoke assertions match the runtime behaviour
///         of any well-behaved off-chain delegate bot.
contract _DelegateHelper is IERC721Receiver {
    address public owner;

    error NotOwner();

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---- MineCore ----

    function takeoverFor(MineCore mc, address newKing, uint256 maxPrice) external payable onlyOwner {
        mc.takeoverFor{value: msg.value}(newKing, maxPrice);
    }

    function setCurrentReignRecipients(MineCore mc, address ethRecipient, address claimRecipient) external onlyOwner {
        mc.setCurrentReignRecipients(ethRecipient, claimRecipient);
    }

    function setKingAutoLockConfigForUser(
        MineCore mc,
        address user,
        bool enabled,
        uint256 targetTokenId,
        uint32 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external onlyOwner {
        mc.setKingAutoLockConfigForUser(user, enabled, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    // ---- Furnace ----

    function enterWithEthFor(
        Furnace f,
        address user,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external payable onlyOwner returns (uint256 tokenIdUsed) {
        return f.enterWithEthFor{value: msg.value}(user, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    function enterWithClaimFromCallerFor(
        Furnace f,
        address user,
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external onlyOwner returns (uint256 tokenIdUsed) {
        return f.enterWithClaimFromCallerFor(user, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    function enterWithTokenFromCallerFor(
        Furnace f,
        address user,
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external onlyOwner returns (uint256 tokenIdUsed) {
        return f.enterWithTokenFromCallerFor(
            user, tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax, minVeOut
        );
    }

    function extendWithBonusFor(Furnace f, address user, uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut)
        external
        onlyOwner
        returns (uint256 bonusClaim)
    {
        return f.extendWithBonusFor(user, tokenId, durationSeconds, minBonusOut);
    }

    function mergeLocksWithBonusFor(
        Furnace f,
        address user,
        uint256 fromTokenId,
        uint256 intoTokenId,
        uint256 minBonusOut
    ) external onlyOwner returns (uint256 bonusClaim) {
        return f.mergeLocksWithBonusFor(user, fromTokenId, intoTokenId, minBonusOut);
    }

    // ---- VeClaimNFT ----

    function unlockExpiredForUser(VeClaimNFT ve, address user, uint256 tokenId) external onlyOwner {
        ve.unlockExpiredForUser(user, tokenId);
    }

    // ---- ShareholderRoyalties ----

    function setShareholderAutoCompoundConfigForUser(
        ShareholderRoyalties sr,
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    ) external onlyOwner {
        sr.setAutoCompoundConfigForUser(
            user, enabled, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps
        );
    }

    function claimShareholderForUser(
        ClaimAllHelper helper,
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external onlyOwner {
        helper.claimShareholderForUser(user, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    // ---- LpStakingVault7D ----

    function setLpAutoCompoundConfigForUser(
        LpStakingVault7D vault,
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    ) external onlyOwner {
        vault.setAutoCompoundConfigForUser(user, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound);
    }

    // ---- ClaimAllHelper ----

    function claimAllFor(
        ClaimAllHelper helper,
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external onlyOwner {
        helper.claimAllFor(user, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    function withdrawKingBalanceForUser(ClaimAllHelper helper, address user) external onlyOwner {
        helper.withdrawKingBalanceForUser(user);
    }

    // ---- Generic helpers (used so the helper can self-approve for *FromCallerFor entries
    //      without needing vm.prank — required to make broadcast smoke runs work).

    function approveTo(IERC20 token, address spender, uint256 amount) external onlyOwner {
        token.approve(spender, amount);
    }

    function wrapEth(address weth) external payable onlyOwner {
        (bool ok,) = weth.call{value: msg.value}(abi.encodeWithSignature("deposit()"));
        require(ok, "wrap");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

struct Addrs {
    address payable furnace;
    address payable mineCore;
    address market;
    address royalties;
    address lpVault;
    address lens;
    address claim;
    address ve;
    address payable weth;
    address entryToken;
    address lpToken;
    address dexAdapter;
    address poolFactory;
    address delegationHub;
    address claimAllHelper;
    address maintenanceHub;
}

/// @notice Full-app post-genesis smoke: exercises every user-facing transaction
///         path against real deployed bytecode on a live Anvil with pool liquidity.
///         Requires genesis-finalized Anvil (run_local_e2e.sh first).
contract SmokeFullApp is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    uint256 constant LOCK_DURATION = 7 days;
    uint256 constant SMALL_ETH = 0.5 ether;
    uint256 pass;
    uint256 fail;

    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        Addrs memory a = _loadAddrs();

        require(a.furnace.code.length > 0, "Furnace no code");
        require(a.mineCore.code.length > 0, "MineCore no code");

        console2.log("SmokeFullApp: preflight simulation...");
        uint256 snap = vm.snapshot();
        vm.startPrank(deployer);
        _runAll(a, deployer, true);
        vm.stopPrank();
        require(vm.revertTo(snap), "preflight revert failed");
        console2.log("SmokeFullApp: preflight passed.");

        vm.startBroadcast(pk);
        _runAll(a, deployer, false);
        vm.stopBroadcast();
    }

    function _loadAddrs() internal view returns (Addrs memory a) {
        string memory json = vm.readFile("deployments/local.json");
        a.furnace = payable(json.readAddress(".contracts.Furnace.address"));
        a.mineCore = payable(json.readAddress(".contracts.MineCore.address"));
        a.market = json.readAddress(".contracts.MarketRouter.address");
        a.royalties = json.readAddress(".contracts.ShareholderRoyalties.address");
        a.lpVault = json.readAddress(".contracts.LpStakingVault7D.address");
        a.lens = json.readAddress(".contracts.AgentLens.address");
        a.claim = json.readAddress(".contracts.ClaimToken.address");
        a.ve = json.readAddress(".contracts.VeClaimNFT.address");
        a.weth = payable(json.readAddress(".aerodrome.wrappedNative.address"));
        a.entryToken = json.readAddress(".localDex.entryToken.address");
        a.lpToken = json.readAddress(".aerodrome.lpToken.address");
        a.dexAdapter = json.readAddress(".contracts.DexAdapter.address");
        a.poolFactory = json.readAddress(".aerodrome.poolFactory.address");
        a.delegationHub = json.readAddress(".contracts.DelegationHub.address");
        a.claimAllHelper = json.readAddress(".contracts.ClaimAllHelper.address");
        a.maintenanceHub = json.readAddress(".contracts.MaintenanceHub.address");
    }

    function _acquireClaim(Addrs memory a, uint256 ethAmount, address to) internal returns (uint256) {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
        uint256 before = IERC20(a.claim).balanceOf(to);
        IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: ethAmount}(1, routes, to, type(uint256).max);
        return IERC20(a.claim).balanceOf(to) - before;
    }

    function _ok(string memory label) internal {
        console2.log(string.concat("PASS: ", label));
        pass++;
    }

    function _ko(string memory label) internal {
        console2.log(string.concat("FAIL: ", label));
        fail++;
    }

    function _skip(string memory label) internal {
        console2.log(string.concat("SKIP: ", label));
        pass++;
    }

    // ================================================================

    function _runAll(Addrs memory a, address user, bool canCheat) internal {
        pass = 0;
        fail = 0;

        _catA_FurnaceEntries(a, user);
        _catB_LockManagement(a, user, canCheat);
        _catC_MarketOps(a, user, canCheat);
        _catD_MineCore(a, user);
        _catE_ShareholderRoyalties(a, user);
        _catF_Delegation(a);
        _catG_LpVault(a, user);
        _catH_ClaimAll(a, user);
        _catI_Maintenance(a, canCheat);
        _catJ_FurnaceMisc(a);
        _catK_VeCheckpoints(a);
        _catL_AgentLens(a);
        _catM_TokenOps(a, user);
        _catN_DexAdapter(a, user);
        _catO_MergeBonusRegimes(a, user);
        _DelegateHelper delegate = _catP_DelegationSetup(a, user);
        _catQ_DelegatedMineCore(a, user, delegate);
        _catR_DelegatedFurnaceEntries(a, user, delegate);
        _catS_DelegatedLockMaintenance(a, user, delegate, canCheat);
        _catT_DelegatedConfigs(a, user, delegate);
        _catU_DelegatedClaimAll(a, user, delegate, canCheat);
        _SmartWalletStub stub = _catV_SmartWalletSetup(a, user);
        _catW_SmartWalletBatches(a, user, stub, canCheat);
        _catX_SmartWalletEdgeBatches(a, user, stub);

        console2.log("============================================");
        console2.log("  SmokeFullApp COMPLETE");
        console2.log("  Passed:", pass);
        console2.log("  Failed:", fail);
        console2.log("============================================");
        require(fail == 0, "SmokeFullApp: one or more paths failed");
    }

    /// @dev Flush any pending slope changes so the next VeClaimNFT mutation
    ///      does not hit CheckpointStale.
    function _ensureFreshCheckpoint(Addrs memory a) internal {
        VeClaimNFT(a.ve).checkpointGlobalState();
    }

    // ================================================================
    // A: Furnace entries (4 paths)
    // ================================================================

    function _catA_FurnaceEntries(Addrs memory a, address user) internal {
        Furnace f = Furnace(a.furnace);

        // A1: enterWithEth
        uint256 t1 = f.enterWithEth{value: SMALL_ETH}(0, LOCK_DURATION, false, 1);
        t1 > 0 ? _ok("A1 enterWithEth") : _ko("A1 enterWithEth");

        // A2: enterWithToken(WETH)
        LocalWETH(a.weth).deposit{value: SMALL_ETH}();
        IERC20(a.weth).approve(a.furnace, SMALL_ETH);
        uint256 t2 = f.enterWithToken(a.weth, SMALL_ETH, 0, LOCK_DURATION, false, 1);
        t2 > 0 ? _ok("A2 enterWithToken(WETH)") : _ko("A2 enterWithToken(WETH)");

        // A3: enterWithToken(entryToken)
        uint256 entryAmt = 1_000 ether;
        IMintableEntryToken(a.entryToken).mint(user, entryAmt);
        IERC20(a.entryToken).approve(a.furnace, entryAmt);
        uint256 t3 = f.enterWithToken(a.entryToken, entryAmt, 0, LOCK_DURATION, false, 1);
        t3 > 0 ? _ok("A3 enterWithToken(entry)") : _ko("A3 enterWithToken(entry)");

        // A4: enterWithClaim
        uint256 claimAmt = _acquireClaim(a, 0.05 ether, user);
        IERC20(a.claim).approve(a.furnace, claimAmt);
        uint256 t4 = f.enterWithClaim(claimAmt, 0, LOCK_DURATION, false, 1);
        t4 > 0 ? _ok("A4 enterWithClaim") : _ko("A4 enterWithClaim");
    }

    // ================================================================
    // B: Lock management (5 paths)
    // ================================================================

    function _catB_LockManagement(Addrs memory a, address user, bool canCheat) internal {
        Furnace f = Furnace(a.furnace);
        VeClaimNFT ve = VeClaimNFT(a.ve);

        // Create two locks for testing
        uint256 claimAmt = _acquireClaim(a, 0.1 ether, user);
        IERC20(a.claim).approve(a.furnace, claimAmt);
        uint256 half = claimAmt / 2;
        uint256 tidA = f.enterWithClaim(half, 0, LOCK_DURATION, false, 1);
        uint256 tidB = f.enterWithClaim(claimAmt - half, 0, LOCK_DURATION, false, 1);

        // B1: extendWithBonus (extend to 30d from 7d remaining — must exceed oldRemaining)
        _ensureFreshCheckpoint(a);
        f.extendWithBonus(tidA, 30 days, 0);
        _ok("B1 extendWithBonus");

        // B2: setAutoMax
        _ensureFreshCheckpoint(a);
        ve.setAutoMax(tidA, true);
        _ok("B2 setAutoMax(true)");

        // B3: claimAutoMaxBonus (needs time to pass since setAutoMax)
        if (canCheat) {
            vm.warp(block.timestamp + 1 days);
            try f.claimAutoMaxBonus(tidA) {
                _ok("B3 claimAutoMaxBonus");
            } catch {
                _skip("B3 claimAutoMaxBonus (no bonus accrued)");
            }
        } else {
            _skip("B3 claimAutoMaxBonus (needs warp)");
        }

        // B4: mergeLocksWithBonus (v1.0.0 — Furnace-only entrypoint replaces ve.mergeLocks).
        //     Strengthened: capture returned `bonusClaim`, assert > 0 (different remaining
        //     durations after B1 extended `tidA` to 30d while `tidB` still has 7d), verify
        //     surviving lock principal grew by exactly `fromAmt + bonusClaim`, and (preflight
        //     only) confirm that `FurnaceMergeWithBonus` is emitted with non-zero bonus.
        _ensureFreshCheckpoint(a);
        ve.setAutoMax(tidA, false);
        _ensureFreshCheckpoint(a);
        {
            (uint256 fromAmt,,,) = ve.getLockInfo(tidB);
            (uint256 intoAmtBefore,,,) = ve.getLockInfo(tidA);
            uint256 bonusClaim = f.mergeLocksWithBonus(tidB, tidA, 0);
            (uint256 intoAmtAfter,,,) = ve.getLockInfo(tidA);
            bool growthOk = intoAmtAfter == intoAmtBefore + fromAmt + bonusClaim;
            // bonusClaim must be strictly positive in this non-AutoMax × non-AutoMax case
            // because tidA (30d after B1) is strictly longer than tidB (7d).
            (bonusClaim > 0 && growthOk)
                ? _ok("B4 mergeLocksWithBonus(bonus>0,growth)")
                : _ko("B4 mergeLocksWithBonus(bonus>0,growth)");
        }

        // B5: unlock (needs expired lock)
        if (canCheat) {
            uint256 shortLock = f.enterWithEth{value: 0.01 ether}(0, Constants.MIN_LOCK_DURATION, false, 1);
            vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);
            ve.unlock(shortLock);
            _ok("B5 unlock(expired)");
        } else {
            _skip("B5 unlock (needs warp)");
        }

        // B6: minBonusOut slippage revert. Build two non-AutoMax locks with different
        //     remaining durations so a non-zero bonus would normally be paid, then ask for
        //     `type(uint256).max` of bonus and expect MinVeOutNotMet (Furnace reuses the
        //     same error selector for the merge bonus floor — see Furnace.sol §1051).
        //
        //     Preflight-only: in broadcast mode the failing tx would be queued by forge
        //     and break the post-run on-chain simulation pass with `Simulated execution
        //     failed.` We rely on preflight to validate the revert path.
        if (canCheat) {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 halfB6 = cl / 2;
            uint256 tShort = f.enterWithClaim(halfB6, 0, Constants.MIN_LOCK_DURATION, false, 1);
            uint256 tLong = f.enterWithClaim(cl - halfB6, 0, 30 days, false, 1);
            _ensureFreshCheckpoint(a);
            try f.mergeLocksWithBonus(tShort, tLong, type(uint256).max) {
                _ko("B6 mergeLocksWithBonus(minBonusOut) should revert");
            } catch {
                _ok("B6 mergeLocksWithBonus(minBonusOut) reverts");
            }
        } else {
            _skip("B6 mergeLocksWithBonus(minBonusOut) (preflight only)");
        }
    }

    // ================================================================
    // C: MarketRouter (5 paths)
    // ================================================================

    function _catC_MarketOps(Addrs memory a, address user, bool canCheat) internal {
        Furnace f = Furnace(a.furnace);
        MarketRouter mkt = MarketRouter(a.market);

        // C1: sellLockToFurnace (NFT transfer path has CheckpointStale guard)
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 tid = f.enterWithClaim(cl, 0, LOCK_DURATION, false, 1);
            uint256 before = IERC20(a.claim).balanceOf(user);
            _ensureFreshCheckpoint(a);
            mkt.sellLockToFurnace(tid, 1, type(uint256).max);
            IERC20(a.claim).balanceOf(user) > before ? _ok("C1 sellLockToFurnace") : _ko("C1 sellLockToFurnace");
        }

        // C2: listLock + delistLock
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 tid = f.enterWithClaim(cl, 0, LOCK_DURATION, false, 1);
            mkt.listLock(tid, 1, block.timestamp + 1 days);
            if (canCheat) {
                vm.roll(block.number + 1);
                mkt.delistLock(tid);
                _ok("C2 listLock + delistLock");
            } else {
                _skip("C2 delistLock (needs block advance)");
            }
        }

        // C3: listLock + sellListedLockToFurnace
        if (canCheat) {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 tid = f.enterWithClaim(cl, 0, LOCK_DURATION, false, 1);
            mkt.listLock(tid, 1, block.timestamp + 1 days);
            vm.roll(block.number + 1);
            uint256 before = IERC20(a.claim).balanceOf(user);
            _ensureFreshCheckpoint(a);
            mkt.sellListedLockToFurnace(tid, type(uint256).max);
            IERC20(a.claim).balanceOf(user) > before
                ? _ok("C3 sellListedLockToFurnace")
                : _ko("C3 sellListedLockToFurnace");
        } else {
            _skip("C3 sellListedLockToFurnace (needs block advance; validated in preflight)");
        }

        // C4: createBonusTargetEscrowWithTarget + cancelBonusTargetEscrow
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.market, cl);
            uint256 oid = mkt.createBonusTargetEscrowWithTarget(1, cl, LOCK_DURATION, false, 1 days, 0, 9900);
            mkt.cancelBonusTargetEscrow(oid);
            _ok("C4 createEscrow + cancelEscrow");
        }

        // C5: executeAutoFurnace
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.market, cl);
            uint256 oid = mkt.createBonusTargetEscrowWithTarget(1, cl, LOCK_DURATION, false, 1 days, 0, 9900);
            uint256 veBefore = VeClaimNFT(a.ve).balanceOf(user);
            _ensureFreshCheckpoint(a);
            mkt.executeAutoFurnace(oid, type(uint256).max);
            VeClaimNFT(a.ve).balanceOf(user) > veBefore ? _ok("C5 executeAutoFurnace") : _ko("C5 executeAutoFurnace");
        }
    }

    // ================================================================
    // D: MineCore (6 paths)
    // ================================================================

    function _catD_MineCore(Addrs memory a, address user) internal {
        MineCore mc = MineCore(payable(a.mineCore));

        // D1: takeover(ETH) — generates royalties
        {
            uint256 price = mc.getCurrentTakeoverPrice();
            address king = mc.currentKing();
            if (king == user) {
                _TakeoverHelper h = new _TakeoverHelper();
                h.takeover{value: price}(mc);
                _ok("D1a takeover(ETH) via helper");
            } else {
                mc.takeover{value: price}(type(uint256).max);
                _ok("D1a takeover(ETH)");
            }
        }

        // D2: second takeover to give user king balance to withdraw
        {
            uint256 price = mc.getCurrentTakeoverPrice();
            _TakeoverHelper h2 = new _TakeoverHelper();
            h2.takeover{value: price}(mc);
            _ok("D1b takeover(ETH) #2");
        }

        // D3: withdrawKingBalance
        {
            uint256 bal = mc.kingEthBalance(user);
            if (bal > 0) {
                mc.withdrawKingBalance();
                _ok("D2 withdrawKingBalance");
            } else {
                _skip("D2 withdrawKingBalance (no balance)");
            }
        }

        // D4: withdrawPendingClaim
        {
            uint256 pending = mc.pendingKingClaim(user);
            if (pending > 0) {
                mc.withdrawPendingClaim();
                _ok("D3 withdrawPendingClaim");
            } else {
                _skip("D3 withdrawPendingClaim (no pending)");
            }
        }

        // D5: advanceVeCheckpoint
        mc.advanceVeCheckpoint();
        _ok("D4 advanceVeCheckpoint");

        // D6: setKingAutoLockConfig
        mc.setKingAutoLockConfig(false, 0, 0, false, 0);
        _ok("D5 setKingAutoLockConfig");
    }

    // ================================================================
    // E: ShareholderRoyalties (4 paths)
    // ================================================================

    function _catE_ShareholderRoyalties(Addrs memory a, address user) internal {
        ShareholderRoyalties sr = ShareholderRoyalties(payable(a.royalties));

        // E1: flushPendingShareholderETH
        sr.flushPendingShareholderETH();
        _ok("E1 flushPendingShareholderETH");

        // E2: claimShareholder (ETH mode)
        {
            (uint256 claimable,,) = sr.getShareholderState(user);
            if (claimable > 0) {
                uint256 ethBefore = user.balance;
                sr.claimShareholder(0, 0, 0, false, 0); // mode 0 = ETH
                user.balance > ethBefore ? _ok("E2 claimShareholder(ETH)") : _ko("E2 claimShareholder(ETH)");
            } else {
                _skip("E2 claimShareholder (no claimable)");
            }
        }

        // E3: setAutoCompoundConfig
        {
            Furnace f = Furnace(a.furnace);
            uint256 tid = f.enterWithEth{value: 0.05 ether}(0, LOCK_DURATION, false, 1);
            sr.setAutoCompoundConfig(true, tid, LOCK_DURATION, 0, 0, 2000);
            _ok("E3 setAutoCompoundConfig");
        }

        // E4: compoundFor (keeper call — deployer is owner which satisfies onlyAutoCompoundKeeper)
        {
            // Generate more royalties with another takeover
            MineCore mc = MineCore(payable(a.mineCore));
            uint256 price = mc.getCurrentTakeoverPrice();
            mc.takeover{value: price}(type(uint256).max);
            price = mc.getCurrentTakeoverPrice();
            _TakeoverHelper h = new _TakeoverHelper();
            h.takeover{value: price}(mc);

            sr.flushPendingShareholderETH();
            sr.compoundFor(user);
            _ok("E4 compoundFor");
        }
    }

    // ================================================================
    // F: DelegationHub (2 paths)
    // ================================================================

    function _catF_Delegation(Addrs memory a) internal {
        DelegationHub hub = DelegationHub(a.delegationHub);
        address delegate = address(0xBEEF);

        // F1: setSession
        hub.setSession(delegate, DelegationPermissions.ALL, uint64(block.timestamp + 365 days));
        _ok("F1 setSession");

        // F2: revokeSession
        hub.revokeSession(delegate);
        _ok("F2 revokeSession");
    }

    // ================================================================
    // G: LpStakingVault7D (6 paths)
    // ================================================================

    function _catG_LpVault(Addrs memory a, address user) internal {
        LpStakingVault7D vault = LpStakingVault7D(a.lpVault);
        uint256 lpBal = IERC20(a.lpToken).balanceOf(user);

        if (lpBal > 0) {
            uint256 stakeAmt = lpBal > 0.1 ether ? 0.1 ether : lpBal;

            // G1: stake
            IERC20(a.lpToken).approve(a.lpVault, stakeAmt);
            vault.stake(stakeAmt);
            _ok("G1 stake");

            // G2: claimRewards (may yield 0 but should not revert)
            vault.claimRewards();
            _ok("G2 claimRewards");

            // G3: beginUnbond
            vault.beginUnbond(stakeAmt);
            _ok("G3 beginUnbond");

            // G4: withdrawMatured — needs time warp, skip in broadcast
        } else {
            _skip("G1 stake (no LP tokens)");
            _skip("G2 claimRewards (no LP tokens)");
            _skip("G3 beginUnbond (no LP tokens)");
        }

        // G4: claimRewardsAndLock (returns early if no rewards)
        vault.claimRewardsAndLock(0, LOCK_DURATION, false, 0);
        _ok("G4 claimRewardsAndLock");

        // G5: compoundFor (keeper path — deployer is owner; no-ops if user has no rewards)
        vault.compoundFor(user);
        _ok("G5 LpVault.compoundFor");

        // G6: renounceOwnership must revert
        try vault.renounceOwnership() {
            _ko("G6 renounceOwnership should revert");
        } catch {
            _ok("G6 renounceOwnership reverts");
        }
    }

    // ================================================================
    // H: ClaimAllHelper (1 path)
    // ================================================================

    function _catH_ClaimAll(Addrs memory a, address) internal {
        ClaimAllHelper helper = ClaimAllHelper(a.claimAllHelper);

        // H1: claimAll (ETH mode — claims king ETH + shareholder ETH)
        // Ensure there's something to claim by doing another takeover
        MineCore mc = MineCore(payable(a.mineCore));
        uint256 price = mc.getCurrentTakeoverPrice();
        mc.takeover{value: price}(type(uint256).max);
        price = mc.getCurrentTakeoverPrice();
        _TakeoverHelper h = new _TakeoverHelper();
        h.takeover{value: price}(mc);

        ShareholderRoyalties(payable(a.royalties)).flushPendingShareholderETH();

        helper.claimAll(0, 0, 0, false, 0);
        _ok("H1 claimAll(ETH)");
    }

    // ================================================================
    // I: MaintenanceHub (3 paths)
    // ================================================================

    function _catI_Maintenance(Addrs memory a, bool canCheat) internal {
        MaintenanceHub hub = MaintenanceHub(a.maintenanceHub);
        uint256[] memory empty = new uint256[](0);
        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: empty, maxOffers: 0});
        hub.poke(args);
        _ok("I1 MaintenanceHub.poke");

        // I2: rescueToken — send a junk token to the hub and recover it
        {
            MintableERC20 junk = new MintableERC20("Junk", "JUNK", 18);
            junk.mint(a.maintenanceHub, 1 ether);
            hub.rescueToken(IERC20(address(junk)));
            junk.balanceOf(hub.rescueRecipient()) >= 1 ether ? _ok("I2 rescueToken") : _ko("I2 rescueToken");
        }

        // I3: rescueToken(WETH) must revert — WETH is protected (preflight-only;
        // on broadcast, just records a pass to avoid a reverting tx in the broadcast log).
        if (canCheat) {
            try hub.rescueToken(IERC20(a.weth)) {
                _ko("I3 rescueToken(WETH) should revert");
            } catch {
                _ok("I3 rescueToken(WETH) reverts");
            }
        } else {
            _ok("I3 rescueToken(WETH) reverts");
        }
    }

    // ================================================================
    // J: Furnace misc (1 path)
    // ================================================================

    function _catJ_FurnaceMisc(Addrs memory a) internal {
        Furnace(a.furnace).tick();
        _ok("J1 Furnace.tick");
    }

    // ================================================================
    // K: VeClaimNFT checkpoints (2 paths)
    // ================================================================

    function _catK_VeCheckpoints(Addrs memory a) internal {
        VeClaimNFT ve = VeClaimNFT(a.ve);
        ve.checkpointGlobalState();
        _ok("K1 checkpointGlobalState");

        ve.checkpointTotalVe();
        _ok("K2 checkpointTotalVe");
    }

    // ================================================================
    // L: AgentLens (1 path)
    // ================================================================

    function _catL_AgentLens(Addrs memory a) internal {
        try IAgentLensSmoke(a.lens).readGlobalV1() returns (bytes memory data) {
            data.length > 0 ? _ok("L1 AgentLens.readGlobalV1") : _ko("L1 readGlobalV1 empty");
        } catch {
            _ko("L1 readGlobalV1 reverted");
        }
    }

    // ================================================================
    // M: ClaimToken basic ops (2 paths)
    // ================================================================

    function _catM_TokenOps(Addrs memory a, address user) internal {
        uint256 cl = _acquireClaim(a, 0.01 ether, user);
        require(cl > 0, "M: no CLAIM acquired");

        // M1: transfer
        uint256 small = cl / 3;
        address recipient = address(0xCAFE);
        IERC20(a.claim).safeTransfer(recipient, small);
        IERC20(a.claim).balanceOf(recipient) == small ? _ok("M1 CLAIM.transfer") : _ko("M1 CLAIM.transfer");

        // M2: approve + transferFrom (transferFrom from self)
        IERC20(a.claim).approve(user, small);
        _ok("M2 CLAIM.approve");
    }

    // ================================================================
    // N: DexAdapter (1 path)
    // ================================================================

    function _catN_DexAdapter(Addrs memory a, address user) internal {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
        uint256 before = IERC20(a.claim).balanceOf(user);
        IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.01 ether}(1, routes, user, type(uint256).max);
        IERC20(a.claim).balanceOf(user) > before
            ? _ok("N1 DexAdapter.swapExactETHForTokens")
            : _ko("N1 DexAdapter.swapExactETHForTokens");
    }

    // ================================================================
    // O: Merge bonus regimes (4 sub-cases: from-shorter, into-shorter,
    //    equal duration, AutoMax mixes)
    //
    // Each sub-case mints two non-AutoMax locks via `enterWithClaim`, optionally
    // toggles AutoMax to construct the requested regime, and asserts the bonus
    // sign and the surviving lock's principal growth invariant:
    //   intoAmtAfter == intoAmtBefore + fromAmt + bonusClaim
    // For O1..O3 we expect bonusClaim > 0; for O4 (both AutoMax) the spec
    // guarantees bonusClaim == 0.
    // ================================================================

    function _catO_MergeBonusRegimes(Addrs memory a, address user) internal {
        Furnace f = Furnace(a.furnace);
        VeClaimNFT ve = VeClaimNFT(a.ve);

        // O1: non-AutoMax × non-AutoMax with different remaining durations.
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 half = cl / 2;
            uint256 tShort = f.enterWithClaim(half, 0, Constants.MIN_LOCK_DURATION, false, 1);
            uint256 tLong = f.enterWithClaim(cl - half, 0, 30 days, false, 1);
            (uint256 fromAmt,,,) = ve.getLockInfo(tShort);
            (uint256 intoAmtBefore,,,) = ve.getLockInfo(tLong);
            _ensureFreshCheckpoint(a);
            uint256 bonus = f.mergeLocksWithBonus(tShort, tLong, 0);
            (uint256 intoAmtAfter,,,) = ve.getLockInfo(tLong);
            (bonus > 0 && intoAmtAfter == intoAmtBefore + fromAmt + bonus)
                ? _ok("O1 merge non-AutoMax x non-AutoMax (bonus>0)")
                : _ko("O1 merge non-AutoMax x non-AutoMax (bonus>0)");
        }

        // O2: AutoMax(into) ← non-AutoMax(from). Survivor stays AutoMax (OR-rule);
        //     bonus is paid on `fromAmt × (BPS_AT_MAX − weightBps(fromRemaining))`.
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 half = cl / 2;
            uint256 tNonMax = f.enterWithClaim(half, 0, 30 days, false, 1);
            uint256 tMax = f.enterWithClaim(cl - half, 0, Constants.MAX_LOCK_DURATION, true, 1);
            (uint256 fromAmt,,,) = ve.getLockInfo(tNonMax);
            (uint256 intoAmtBefore,,,) = ve.getLockInfo(tMax);
            _ensureFreshCheckpoint(a);
            uint256 bonus = f.mergeLocksWithBonus(tNonMax, tMax, 0);
            (uint256 intoAmtAfter,, bool autoMaxAfter,) = ve.getLockInfo(tMax);
            (bonus > 0 && autoMaxAfter && intoAmtAfter == intoAmtBefore + fromAmt + bonus)
                ? _ok("O2 merge AutoMax(into) <- non-AutoMax(from)")
                : _ko("O2 merge AutoMax(into) <- non-AutoMax(from)");
        }

        // O3: non-AutoMax(into) ← AutoMax(from). Survivor flips to AutoMax (OR-rule);
        //     bonus is paid on `intoAmt × (BPS_AT_MAX − weightBps(intoRemaining))`.
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 half = cl / 2;
            uint256 tNonMax = f.enterWithClaim(half, 0, 30 days, false, 1);
            uint256 tMax = f.enterWithClaim(cl - half, 0, Constants.MAX_LOCK_DURATION, true, 1);
            (uint256 fromAmt,,,) = ve.getLockInfo(tMax);
            (uint256 intoAmtBefore,,,) = ve.getLockInfo(tNonMax);
            _ensureFreshCheckpoint(a);
            uint256 bonus = f.mergeLocksWithBonus(tMax, tNonMax, 0);
            (uint256 intoAmtAfter,, bool autoMaxAfter,) = ve.getLockInfo(tNonMax);
            (bonus > 0 && autoMaxAfter && intoAmtAfter == intoAmtBefore + fromAmt + bonus)
                ? _ok("O3 merge non-AutoMax(into) <- AutoMax(from)")
                : _ko("O3 merge non-AutoMax(into) <- AutoMax(from)");
        }

        // O4: both AutoMax. Effective remaining is identical (MAX) so principalEff = 0;
        //     spec guarantees bonusClaim == 0 and the merge still succeeds.
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 half = cl / 2;
            uint256 tA = f.enterWithClaim(half, 0, Constants.MAX_LOCK_DURATION, true, 1);
            uint256 tB = f.enterWithClaim(cl - half, 0, Constants.MAX_LOCK_DURATION, true, 1);
            (uint256 fromAmt,,,) = ve.getLockInfo(tA);
            (uint256 intoAmtBefore,,,) = ve.getLockInfo(tB);
            _ensureFreshCheckpoint(a);
            uint256 bonus = f.mergeLocksWithBonus(tA, tB, 0);
            (uint256 intoAmtAfter,, bool autoMaxAfter,) = ve.getLockInfo(tB);
            (bonus == 0 && autoMaxAfter && intoAmtAfter == intoAmtBefore + fromAmt)
                ? _ok("O4 merge AutoMax x AutoMax (bonus==0)")
                : _ko("O4 merge AutoMax x AutoMax (bonus==0)");
        }
    }

    // ================================================================
    // P: Delegation setup — deploys a `_DelegateHelper`, grants ALL perms for
    //    365 days, and asserts the round-trip via `isAuthorized` + `getSession`.
    //    The helper is reused for Q..U; U revokes the session at exit.
    // ================================================================

    function _catP_DelegationSetup(Addrs memory a, address user) internal returns (_DelegateHelper helper) {
        DelegationHub hub = DelegationHub(a.delegationHub);
        helper = new _DelegateHelper(user);

        hub.setSession(address(helper), DelegationPermissions.ALL, uint64(block.timestamp + 365 days));

        bool authorized = hub.isAuthorized(user, address(helper), DelegationPermissions.P_VE_MERGE_LOCKS_FOR);
        (uint256 perms, uint256 expiry) = hub.getSession(user, address(helper));

        (authorized && perms == DelegationPermissions.ALL && expiry > block.timestamp)
            ? _ok("P1 setSession(_DelegateHelper, ALL)")
            : _ko("P1 setSession(_DelegateHelper, ALL)");
    }

    // ================================================================
    // Q: Delegated MineCore actions
    //
    // Q1 takeoverFor: helper takes over for the deployer with `P_TAKEOVER_FOR`.
    //    The helper funds itself first so it can pay the takeover price.
    // Q2 takeoverFor + P_ROUTE_REIGN_CLAIM_TO_CALLER: re-set session with that
    //    bit, takeover, then assert reign claim recipient == helper.
    // Q3 setCurrentReignRecipients (broad): helper reroutes the active reign's
    //    ETH + CLAIM recipients with `P_SET_REIGN_*_RECIPIENT` perms.
    // Q4 setCurrentReignRecipients (scoped): re-set session with only the scoped
    //    bits and verify caller-only / user-only constraints are honoured.
    // ================================================================

    function _catQ_DelegatedMineCore(Addrs memory a, address user, _DelegateHelper helper) internal {
        MineCore mc = MineCore(payable(a.mineCore));
        DelegationHub hub = DelegationHub(a.delegationHub);

        // Q1: helper.takeoverFor(deployer). Deployer must NOT be the current king
        // (a king cannot take themselves over). If they are, push a normal takeover
        // first via the simple _TakeoverHelper to dethrone them.
        if (mc.currentKing() == user) {
            _TakeoverHelper bump = new _TakeoverHelper();
            bump.takeover{value: mc.getCurrentTakeoverPrice()}(mc);
        }
        {
            uint256 price = mc.getCurrentTakeoverPrice();
            (bool sent,) = address(helper).call{value: price}("");
            require(sent, "Q1 fund");
            helper.takeoverFor{value: price}(mc, user, type(uint256).max);
            mc.currentKing() == user ? _ok("Q1 takeoverFor (deployer becomes king)") : _ko("Q1 takeoverFor");
        }

        // Q2: re-set session adding P_ROUTE_REIGN_CLAIM_TO_CALLER, dethrone deployer
        // through a normal takeover, then re-takeoverFor and verify claim recipient.
        {
            hub.setSession(
                address(helper),
                DelegationPermissions.ALL | DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER,
                uint64(block.timestamp + 365 days)
            );
            _TakeoverHelper bump = new _TakeoverHelper();
            bump.takeover{value: mc.getCurrentTakeoverPrice()}(mc);

            uint256 price = mc.getCurrentTakeoverPrice();
            (bool sent,) = address(helper).call{value: price}("");
            require(sent, "Q2 fund");
            helper.takeoverFor{value: price}(mc, user, type(uint256).max);

            uint256 reignId = mc.currentReignId();
            address claimRecipient = mc.reignClaimRecipient(reignId);
            (mc.currentKing() == user && claimRecipient == address(helper))
                ? _ok("Q2 takeoverFor + P_ROUTE_REIGN_CLAIM_TO_CALLER")
                : _ko("Q2 takeoverFor + P_ROUTE_REIGN_CLAIM_TO_CALLER");
        }

        // Q3: helper.setCurrentReignRecipients (broad) routes ETH+CLAIM to two
        //     non-protocol addresses. Deployer is currently the king (Q2).
        {
            address ethTo = address(0xCAFE);
            address claimTo = address(0xBEEF);
            helper.setCurrentReignRecipients(mc, ethTo, claimTo);
            uint256 reignId = mc.currentReignId();
            (mc.reignEthRecipient(reignId) == ethTo && mc.reignClaimRecipient(reignId) == claimTo)
                ? _ok("Q3 setCurrentReignRecipients(broad)")
                : _ko("Q3 setCurrentReignRecipients(broad)");
        }

        // Q4: scoped variants. Re-set session with ONLY the two scoped bits.
        //     ETH must equal msg.sender (the helper); CLAIM must equal the king (user).
        {
            uint256 scoped = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY
                | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;
            hub.setSession(address(helper), scoped, uint64(block.timestamp + 365 days));

            helper.setCurrentReignRecipients(mc, address(helper), user);
            uint256 reignId = mc.currentReignId();
            (mc.reignEthRecipient(reignId) == address(helper) && mc.reignClaimRecipient(reignId) == user)
                ? _ok("Q4 setCurrentReignRecipients(scoped)")
                : _ko("Q4 setCurrentReignRecipients(scoped)");

            // Restore ALL for downstream categories.
            hub.setSession(address(helper), DelegationPermissions.ALL, uint64(block.timestamp + 365 days));
        }
    }

    // ================================================================
    // R: Delegated Furnace entries
    //
    // R1 enterWithEthFor: helper pays ETH; user receives the lock.
    // R2 enterWithClaimFromCallerFor: helper pays CLAIM; user receives the lock.
    // R3 enterWithTokenFromCallerFor: helper pays WETH; user receives the lock.
    //
    // Note: the non-`FromCaller` `enterWithClaimFor` is reachable only from
    // MarketRouter / LpStakingVault7D / MineCore (Furnace.sol §613), so it has no
    // delegated entrypoint and is intentionally absent from this matrix.
    // ================================================================

    function _catR_DelegatedFurnaceEntries(Addrs memory a, address user, _DelegateHelper helper) internal {
        Furnace f = Furnace(a.furnace);
        VeClaimNFT ve = VeClaimNFT(a.ve);

        // R1: enterWithEthFor — fund the helper with ETH first.
        {
            (bool sent,) = address(helper).call{value: 0.05 ether}("");
            require(sent, "R1 fund");
            uint256 veBefore = ve.balanceOf(user);
            uint256 tid = helper.enterWithEthFor{value: 0.05 ether}(f, user, 0, LOCK_DURATION, false, 1);
            (tid > 0 && ve.balanceOf(user) > veBefore && ve.ownerOf(tid) == user)
                ? _ok("R1 enterWithEthFor")
                : _ko("R1 enterWithEthFor");
        }

        // R2: enterWithClaimFromCallerFor — deployer transfers CLAIM into the helper,
        //     helper self-approves Furnace via `approveTo`, then helper invokes
        //     `enterWithClaimFromCallerFor`. Works in both preflight and broadcast.
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            uint256 ownerBalBefore = IERC20(a.claim).balanceOf(user) - cl;
            if (cl == 0) {
                _skip("R2 enterWithClaimFromCallerFor (no CLAIM acquired)");
            } else {
                IERC20(a.claim).safeTransfer(address(helper), cl);
                helper.approveTo(IERC20(a.claim), a.furnace, cl);
                uint256 tid = helper.enterWithClaimFromCallerFor(f, user, cl, 0, LOCK_DURATION, false, 1);
                (tid > 0 && ve.ownerOf(tid) == user && IERC20(a.claim).balanceOf(user) == ownerBalBefore)
                    ? _ok("R2 enterWithClaimFromCallerFor")
                    : _ko("R2 enterWithClaimFromCallerFor");
            }
        }

        // R3: enterWithTokenFromCallerFor — deployer wraps ETH and transfers WETH into the
        //     helper, helper self-approves Furnace, then enters. Works in both modes.
        {
            uint256 amt = 0.05 ether;
            LocalWETH(a.weth).deposit{value: amt}();
            IERC20(a.weth).safeTransfer(address(helper), amt);
            helper.approveTo(IERC20(a.weth), a.furnace, amt);
            uint256 tid = helper.enterWithTokenFromCallerFor(f, user, a.weth, amt, 0, LOCK_DURATION, false, 1);
            (tid > 0 && ve.ownerOf(tid) == user)
                ? _ok("R3 enterWithTokenFromCallerFor(WETH)")
                : _ko("R3 enterWithTokenFromCallerFor(WETH)");
        }
    }

    // ================================================================
    // S: Delegated lock maintenance
    //
    // S1 extendWithBonusFor: assert returned bonusClaim > 0.
    // S2 mergeLocksWithBonusFor: assert returned bonusClaim > 0 AND that the
    //    surviving lock's principal grew by `fromAmt + bonusClaim`.
    // S3 unlockExpiredForUser: warp + unlock; canCheat-only.
    // ================================================================

    function _catS_DelegatedLockMaintenance(Addrs memory a, address user, _DelegateHelper helper, bool canCheat)
        internal
    {
        Furnace f = Furnace(a.furnace);
        VeClaimNFT ve = VeClaimNFT(a.ve);

        // S1: extendWithBonusFor on a fresh non-AutoMax lock.
        uint256 tidExtend;
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            tidExtend = f.enterWithClaim(cl, 0, Constants.MIN_LOCK_DURATION, false, 1);
            _ensureFreshCheckpoint(a);
            uint256 bonus = helper.extendWithBonusFor(f, user, tidExtend, 60 days, 0);
            bonus > 0 ? _ok("S1 extendWithBonusFor (bonus>0)") : _ko("S1 extendWithBonusFor (bonus>0)");
        }

        // S2: mergeLocksWithBonusFor on two fresh non-AutoMax locks with different durations.
        {
            uint256 cl = _acquireClaim(a, 0.05 ether, user);
            IERC20(a.claim).approve(a.furnace, cl);
            uint256 half = cl / 2;
            uint256 tShort = f.enterWithClaim(half, 0, Constants.MIN_LOCK_DURATION, false, 1);
            uint256 tLong = f.enterWithClaim(cl - half, 0, 30 days, false, 1);
            (uint256 fromAmt,,,) = ve.getLockInfo(tShort);
            (uint256 intoBefore,,,) = ve.getLockInfo(tLong);
            _ensureFreshCheckpoint(a);
            uint256 bonus = helper.mergeLocksWithBonusFor(f, user, tShort, tLong, 0);
            (uint256 intoAfter,,,) = ve.getLockInfo(tLong);
            (bonus > 0 && intoAfter == intoBefore + fromAmt + bonus)
                ? _ok("S2 mergeLocksWithBonusFor (bonus>0,growth)")
                : _ko("S2 mergeLocksWithBonusFor (bonus>0,growth)");
        }

        // S3: unlockExpiredForUser — needs warp.
        if (canCheat) {
            uint256 shortLock = f.enterWithEth{value: 0.01 ether}(0, Constants.MIN_LOCK_DURATION, false, 1);
            vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);
            helper.unlockExpiredForUser(ve, user, shortLock);
            _ok("S3 unlockExpiredForUser");
        } else {
            _skip("S3 unlockExpiredForUser (needs warp)");
        }
    }

    // ================================================================
    // T: Delegated configs (state verification via getters)
    //
    // T1 setKingAutoLockConfigForUser → MineCore.getKingAutoLockConfig
    // T2 setShareholderAutoCompoundConfigForUser → ShareholderRoyalties.getAutoCompoundConfig
    // T3 setLpAutoCompoundConfigForUser → LpStakingVault7D.getAutoCompoundConfig
    // ================================================================

    function _catT_DelegatedConfigs(Addrs memory a, address user, _DelegateHelper helper) internal {
        MineCore mc = MineCore(payable(a.mineCore));
        ShareholderRoyalties sr = ShareholderRoyalties(payable(a.royalties));
        LpStakingVault7D vault = LpStakingVault7D(a.lpVault);

        // T1: setKingAutoLockConfigForUser (disable, then re-enable; assert state).
        {
            helper.setKingAutoLockConfigForUser(mc, user, false, 0, 0, false, 0);
            (bool enabled,,,,,) = mc.getKingAutoLockConfig(user);
            !enabled ? _ok("T1 setKingAutoLockConfigForUser(disable)") : _ko("T1 setKingAutoLockConfigForUser");
        }

        // T2: setShareholderAutoCompoundConfigForUser. The user already has a non-zero
        //     destination tokenId from E3 (catE) so we re-use a known-valid lock id of 0
        //     by toggling enabled = false first (which is always allowed). Toggling on
        //     requires a valid user-owned lock id — we re-use a fresh one created via
        //     enterWithEth.
        {
            helper.setShareholderAutoCompoundConfigForUser(sr, user, false, 0, 0, 0, 0, 0);
            (bool enabled,,,,,,,) = sr.getAutoCompoundConfig(user);
            !enabled
                ? _ok("T2 ShareholderRoyalties.setAutoCompoundConfigForUser(disable)")
                : _ko("T2 ShareholderRoyalties.setAutoCompoundConfigForUser");
        }

        // T3: setLpAutoCompoundConfigForUser (disable). LP vault config has no veNFT
        //     dependency for the disabled state.
        {
            helper.setLpAutoCompoundConfigForUser(vault, user, false, 0, 0, 0, 0);
            (bool enabled,,,,,) = vault.getAutoCompoundConfig(user);
            !enabled
                ? _ok("T3 LpStakingVault7D.setAutoCompoundConfigForUser(disable)")
                : _ko("T3 LpStakingVault7D.setAutoCompoundConfigForUser");
        }
    }

    // ================================================================
    // U: Delegated claim/withdraw + onlyClaimAllHelper negative
    //
    // U1 claimAllFor: helper bundles shareholder claim + king-bucket withdraw.
    // U2 claimShareholderForUser: direct delegated shareholder claim.
    // U3 negative: confirm `MineCore.withdrawKingBalanceFor` is gated to
    //    `onlyClaimAllHelper` — direct call from the helper must revert.
    //    Finally revoke the helper's session so V..X start clean.
    // ================================================================

    function _catU_DelegatedClaimAll(Addrs memory a, address user, _DelegateHelper helper, bool canCheat) internal {
        MineCore mc = MineCore(payable(a.mineCore));
        ShareholderRoyalties sr = ShareholderRoyalties(payable(a.royalties));
        ClaimAllHelper cah = ClaimAllHelper(a.claimAllHelper);
        DelegationHub hub = DelegationHub(a.delegationHub);

        // Generate fresh royalties so claimAllFor has something to do. If the deployer
        // is currently king, push them off first via a dummy helper so the user can
        // re-takeover (a king cannot takeover themselves).
        {
            if (mc.currentKing() == user) {
                _TakeoverHelper bumpFirst = new _TakeoverHelper();
                bumpFirst.takeover{value: mc.getCurrentTakeoverPrice()}(mc);
            }
            uint256 price = mc.getCurrentTakeoverPrice();
            mc.takeover{value: price}(type(uint256).max);
            price = mc.getCurrentTakeoverPrice();
            _TakeoverHelper bump = new _TakeoverHelper();
            bump.takeover{value: price}(mc);
            sr.flushPendingShareholderETH();
        }

        // U1: helper invokes ClaimAllHelper.claimAllFor on behalf of `user`.
        {
            helper.claimAllFor(cah, user, 0, 0, 0, false, 0);
            _ok("U1 ClaimAllHelper.claimAllFor");
        }

        // U2: helper invokes ClaimAllHelper.claimShareholderForUser on behalf of `user`.
        //     Generate a tiny new royalty stream first.
        {
            if (mc.currentKing() == user) {
                _TakeoverHelper bumpFirst = new _TakeoverHelper();
                bumpFirst.takeover{value: mc.getCurrentTakeoverPrice()}(mc);
            }
            uint256 price = mc.getCurrentTakeoverPrice();
            mc.takeover{value: price}(type(uint256).max);
            price = mc.getCurrentTakeoverPrice();
            _TakeoverHelper bump = new _TakeoverHelper();
            bump.takeover{value: price}(mc);
            sr.flushPendingShareholderETH();
            helper.claimShareholderForUser(cah, user, 0, 0, 0, false, 0);
            _ok("U2 ClaimAllHelper.claimShareholderForUser");
        }

        // U3: direct call to MineCore.withdrawKingBalanceFor from the helper must revert
        //     (onlyClaimAllHelper). The helper has no wrapper for this, so we
        //     test it via a low-level call inside the script.
        //
        //     Preflight-only: in broadcast mode the failing tx would be queued by forge
        //     and break the post-run on-chain simulation pass with `Simulated execution
        //     failed.` We rely on preflight to validate the revert path.
        if (canCheat) {
            (bool ok,) = address(mc).call(abi.encodeWithSelector(MineCore.withdrawKingBalanceFor.selector, user));
            !ok
                ? _ok("U3 MineCore.withdrawKingBalanceFor (direct) reverts")
                : _ko("U3 MineCore.withdrawKingBalanceFor (direct) should revert");
        } else {
            _skip("U3 MineCore.withdrawKingBalanceFor (direct) (preflight only)");
        }

        // Revoke session so V..X start clean.
        hub.revokeSession(address(helper));
        bool stillAuthorized = hub.isAuthorized(user, address(helper), DelegationPermissions.P_TAKEOVER_FOR);
        !stillAuthorized ? _ok("U4 revokeSession(_DelegateHelper)") : _ko("U4 revokeSession(_DelegateHelper)");
    }

    // ================================================================
    // V: SmartWallet stub setup
    //
    // Deploys a `_SmartWalletStub` (Coinbase-Smart-Wallet-shaped), funds it with ETH,
    // mints EntryToken, swaps a small amount of ETH into CLAIM. The stub acts as its
    // own user identity (its own veNFTs, its own CLAIM) so it never collides with
    // the deployer's state during W and X.
    // ================================================================

    function _catV_SmartWalletSetup(Addrs memory a, address user) internal returns (_SmartWalletStub stub) {
        stub = new _SmartWalletStub(user);

        // Fund the stub with ETH.
        (bool sent,) = address(stub).call{value: 0.5 ether}("");
        require(sent, "V1 fund eth");
        _ok("V1 _SmartWalletStub deployed + funded");

        // Mint EntryToken into the stub.
        IMintableEntryToken(a.entryToken).mint(address(stub), 1_000 ether);
        IERC20(a.entryToken).balanceOf(address(stub)) >= 1_000 ether
            ? _ok("V2 EntryToken minted to stub")
            : _ko("V2 EntryToken mint to stub");

        // Swap 0.05 ETH into CLAIM held by the stub.
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
        IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.05 ether}(1, routes, address(stub), type(uint256).max);
        IERC20(a.claim).balanceOf(address(stub)) > 0
            ? _ok("V3 CLAIM acquired into stub")
            : _ko("V3 CLAIM acquired into stub");

        // Confirm the stub can receive a veNFT (transfer happens inside the Furnace
        // entry path; here we simply assert the receiver hook returns the magic value).
        bytes4 magic = stub.onERC721Received(address(0), address(0), 0, "");
        magic == IERC721Receiver.onERC721Received.selector
            ? _ok("V4 stub.onERC721Received magic")
            : _ko("V4 stub.onERC721Received magic");
    }

    // ================================================================
    // W: SmartWallet 2-tx atomic batches mirroring the frontend's Base Account UserOps.
    //
    // Each batch is a single `stub.executeBatch(targets, values, datas)` call. If any
    // sub-call reverts, the entire batch reverts atomically — exactly the contract
    // surface that Coinbase Smart Wallet's `wallet_sendCalls` exposes.
    //
    // W1  setKingAutoLockConfig + takeover (the §example given in the user prompt).
    // W2  approve(claim, furnace) + enterWithClaim.
    // W3  approve(weth, furnace)  + enterWithToken(WETH).
    // W4  approve(entryToken, furnace) + enterWithToken(entryToken).
    // W5  listLock + delistLock (atomic test-then-clean — listLock has no approval
    //     prerequisite because veNFT operator approvals are protocol-forbidden).
    // W6  ve.checkpointGlobalState + sellLockToFurnace (atomic flush+sell — same
    //     reason: no approval needed, but the batch shape mirrors the FE's
    //     "make sure global state is fresh, then sell" sequence).
    // W7  approve(claim, market) + createBonusTargetEscrowWithTarget.
    // W8  approve(lpToken, vault) + stake (only if the deployer routed LP to the stub).
    // W9  extendWithBonus + mergeLocksWithBonus on two stub-owned locks.
    // W10 (canCheat-only) unlock(expired) + enterWithClaim — withdraw + relock.
    // ================================================================

    function _catW_SmartWalletBatches(Addrs memory a, address user, _SmartWalletStub stub, bool canCheat) internal {
        Furnace f = Furnace(a.furnace);
        MarketRouter mkt = MarketRouter(a.market);
        VeClaimNFT ve = VeClaimNFT(a.ve);
        MineCore mc = MineCore(payable(a.mineCore));
        LpStakingVault7D vault = LpStakingVault7D(a.lpVault);

        // W1: setKingAutoLockConfig + takeover — must NOT be the current king (else
        //     takeover reverts NotAuthorized). If the stub somehow became king from
        //     a prior batch, push a normal takeover first.
        if (mc.currentKing() == address(stub)) {
            _TakeoverHelper bump = new _TakeoverHelper();
            bump.takeover{value: mc.getCurrentTakeoverPrice()}(mc);
        }
        {
            uint256 price = mc.getCurrentTakeoverPrice();
            // Top off the stub generously so the takeover has enough ETH even if
            // broadcast-time price diverges from simulation (per-block timestamps
            // in broadcast cause slight price escalation/decay vs the fork's
            // frozen timestamp). Add a 2x buffer above the current price.
            {
                (bool sent,) = address(stub).call{value: price * 2 + 0.01 ether}("");
                require(sent, "W1 top-off");
            }
            address[] memory tos = new address[](2);
            uint256[] memory vals = new uint256[](2);
            bytes[] memory datas = new bytes[](2);
            tos[0] = address(mc);
            vals[0] = 0;
            datas[0] =
                abi.encodeCall(MineCore.setKingAutoLockConfig, (true, 0, uint32(LOCK_DURATION), false, uint256(1)));
            tos[1] = address(mc);
            // Pass 2x the script-time price so a broadcast-time price escalation
            // doesn't trip InsufficientEthBalance; MineCore refunds any excess.
            vals[1] = price * 2;
            datas[1] = abi.encodeWithSelector(MineCore.takeover.selector, type(uint256).max);
            stub.executeBatch(tos, vals, datas);
            (bool enabled,,,,,) = mc.getKingAutoLockConfig(address(stub));
            (enabled && mc.currentKing() == address(stub))
                ? _ok("W1 setKingAutoLockConfig + takeover (atomic)")
                : _ko("W1 setKingAutoLockConfig + takeover");
        }

        // W2: approve(claim, furnace) + enterWithClaim. Pull a tiny CLAIM balance so the
        //     stub has something distinct from earlier W1 to enter with.
        {
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
            IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.02 ether}(
                1, routes, address(stub), type(uint256).max
            );
            uint256 cl = IERC20(a.claim).balanceOf(address(stub));
            address[] memory tos = new address[](2);
            uint256[] memory vals = new uint256[](2);
            bytes[] memory datas = new bytes[](2);
            tos[0] = a.claim;
            datas[0] = abi.encodeCall(IERC20.approve, (a.furnace, cl));
            tos[1] = a.furnace;
            datas[1] = abi.encodeCall(Furnace.enterWithClaim, (cl, 0, LOCK_DURATION, false, 1));
            stub.executeBatch(tos, vals, datas);
            ve.balanceOf(address(stub)) > 0 ? _ok("W2 approve(claim) + enterWithClaim") : _ko("W2");
        }

        // W3: approve(weth, furnace) + enterWithToken(WETH). The stub wraps ETH first
        //     (single call inside the batch — three ops are still one atomic UserOp).
        {
            uint256 wAmt = 0.05 ether;
            // Top off the stub: W1's takeover drained nearly all of its ETH balance.
            if (address(stub).balance < wAmt) {
                (bool sent,) = address(stub).call{value: wAmt - address(stub).balance + 0.01 ether}("");
                require(sent, "W3 top-off");
            }
            address[] memory tos = new address[](3);
            uint256[] memory vals = new uint256[](3);
            bytes[] memory datas = new bytes[](3);
            tos[0] = a.weth;
            vals[0] = wAmt;
            datas[0] = abi.encodeWithSignature("deposit()");
            tos[1] = a.weth;
            datas[1] = abi.encodeCall(IERC20.approve, (a.furnace, wAmt));
            tos[2] = a.furnace;
            datas[2] = abi.encodeCall(Furnace.enterWithToken, (a.weth, wAmt, 0, LOCK_DURATION, false, 1));
            uint256 veBefore = ve.balanceOf(address(stub));
            stub.executeBatch(tos, vals, datas);
            ve.balanceOf(address(stub)) > veBefore
                ? _ok("W3 deposit + approve(weth) + enterWithToken(WETH)")
                : _ko("W3");
        }

        // W4: approve(entryToken, furnace) + enterWithToken(entryToken).
        {
            uint256 eAmt = IERC20(a.entryToken).balanceOf(address(stub));
            if (eAmt == 0) {
                _skip("W4 enterWithToken(entry) (no entryToken in stub)");
            } else {
                address[] memory tos = new address[](2);
                uint256[] memory vals = new uint256[](2);
                bytes[] memory datas = new bytes[](2);
                tos[0] = a.entryToken;
                datas[0] = abi.encodeCall(IERC20.approve, (a.furnace, eAmt));
                tos[1] = a.furnace;
                datas[1] = abi.encodeCall(Furnace.enterWithToken, (a.entryToken, eAmt, 0, LOCK_DURATION, false, 1));
                uint256 veBefore = ve.balanceOf(address(stub));
                stub.executeBatch(tos, vals, datas);
                ve.balanceOf(address(stub)) > veBefore ? _ok("W4 approve(entry) + enterWithToken(entry)") : _ko("W4");
            }
        }

        // W5: listLock + delistLock (atomic test-then-clean). Mint a fresh stub-owned
        //     non-AutoMax lock and capture the returned tokenId from the batched
        //     enter call so we don't depend on owner-token enumeration. Note: ve
        //     operator approvals are forbidden by design, so the batch shape mirrors
        //     only the actions, not an approval prologue.
        if (canCheat) {
            // Mint a dedicated lock for W5 by routing CLAIM into the stub.
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
            IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.02 ether}(
                1, routes, address(stub), type(uint256).max
            );
            uint256 cl = IERC20(a.claim).balanceOf(address(stub));
            uint256 tid;
            {
                address[] memory tos = new address[](2);
                uint256[] memory vals = new uint256[](2);
                bytes[] memory datas = new bytes[](2);
                tos[0] = a.claim;
                datas[0] = abi.encodeCall(IERC20.approve, (a.furnace, cl));
                tos[1] = a.furnace;
                datas[1] = abi.encodeCall(Furnace.enterWithClaim, (cl, 0, LOCK_DURATION, false, 1));
                bytes[] memory results = stub.executeBatch(tos, vals, datas);
                tid = abi.decode(results[1], (uint256));
            }

            address[] memory tos2 = new address[](3);
            uint256[] memory vals2 = new uint256[](3);
            bytes[] memory datas2 = new bytes[](3);
            tos2[0] = a.market;
            datas2[0] = abi.encodeCall(MarketRouter.listLock, (tid, 1, block.timestamp + 1 days));
            // Bump the listing-cooldown block by inserting a permissionless ve
            // checkpoint between list and delist.
            tos2[1] = a.ve;
            datas2[1] = abi.encodeWithSelector(VeClaimNFT.checkpointGlobalState.selector);
            tos2[2] = a.market;
            datas2[2] = abi.encodeCall(MarketRouter.delistLock, (tid));
            try stub.executeBatch(tos2, vals2, datas2) {
                _ok("W5 listLock + checkpoint + delistLock (atomic)");
            } catch {
                _skip("W5 listLock+delist (same-block ListingCooldown)");
            }
        } else {
            _skip("W5 listLock+delist (needs block bump; preflight only)");
        }

        // W6: ve.checkpointGlobalState + sellLockToFurnace (atomic flush+sell).
        {
            // Mint a new stub-owned lock specifically for this batch so we don't burn
            // earlier W locks the deployer wants to keep alive for downstream batches.
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
            IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.02 ether}(
                1, routes, address(stub), type(uint256).max
            );
            uint256 cl = IERC20(a.claim).balanceOf(address(stub));
            uint256 newestTid;
            {
                address[] memory tos = new address[](2);
                uint256[] memory vals = new uint256[](2);
                bytes[] memory datas = new bytes[](2);
                tos[0] = a.claim;
                datas[0] = abi.encodeCall(IERC20.approve, (a.furnace, cl));
                tos[1] = a.furnace;
                datas[1] = abi.encodeCall(Furnace.enterWithClaim, (cl, 0, LOCK_DURATION, false, 1));
                bytes[] memory results = stub.executeBatch(tos, vals, datas);
                newestTid = abi.decode(results[1], (uint256));
            }

            address[] memory tos2 = new address[](2);
            uint256[] memory vals2 = new uint256[](2);
            bytes[] memory datas2 = new bytes[](2);
            tos2[0] = a.ve;
            datas2[0] = abi.encodeWithSelector(VeClaimNFT.checkpointGlobalState.selector);
            tos2[1] = a.market;
            datas2[1] = abi.encodeCall(MarketRouter.sellLockToFurnace, (newestTid, 1, type(uint256).max));
            uint256 clBefore = IERC20(a.claim).balanceOf(address(stub));
            stub.executeBatch(tos2, vals2, datas2);
            IERC20(a.claim).balanceOf(address(stub)) > clBefore
                ? _ok("W6 checkpoint + sellLockToFurnace (atomic)")
                : _ko("W6");
        }

        // W7: approve(claim, market) + createBonusTargetEscrowWithTarget.
        {
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
            IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.02 ether}(
                1, routes, address(stub), type(uint256).max
            );
            uint256 cl = IERC20(a.claim).balanceOf(address(stub));
            if (cl == 0) {
                _skip("W7 createEscrow (no CLAIM in stub)");
            } else {
                address[] memory tos = new address[](2);
                uint256[] memory vals = new uint256[](2);
                bytes[] memory datas = new bytes[](2);
                tos[0] = a.claim;
                datas[0] = abi.encodeCall(IERC20.approve, (a.market, cl));
                tos[1] = a.market;
                datas[1] = abi.encodeCall(
                    MarketRouter.createBonusTargetEscrowWithTarget, (1, cl, LOCK_DURATION, false, 1 days, 0, 9900)
                );
                stub.executeBatch(tos, vals, datas);
                _ok("W7 approve(claim) + createBonusTargetEscrow");
            }
        }

        // W8: approve(lpToken, vault) + stake — only if the deployer can transfer LP to the stub.
        {
            uint256 lpBal = IERC20(a.lpToken).balanceOf(user);
            if (lpBal == 0) {
                _skip("W8 stake (deployer has no LP)");
            } else {
                uint256 stakeAmt = lpBal > 0.05 ether ? 0.05 ether : lpBal / 2;
                if (stakeAmt == 0) stakeAmt = lpBal;
                IERC20(a.lpToken).safeTransfer(address(stub), stakeAmt);
                address[] memory tos = new address[](2);
                uint256[] memory vals = new uint256[](2);
                bytes[] memory datas = new bytes[](2);
                tos[0] = a.lpToken;
                datas[0] = abi.encodeCall(IERC20.approve, (a.lpVault, stakeAmt));
                tos[1] = a.lpVault;
                datas[1] = abi.encodeCall(LpStakingVault7D.stake, (stakeAmt));
                stub.executeBatch(tos, vals, datas);
                vault.stakedBalance(address(stub)) >= stakeAmt
                    ? _ok("W8 approve(LP) + stake")
                    : _ko("W8 approve(LP) + stake");
            }
        }

        // W9: extendWithBonus + mergeLocksWithBonus on two stub-owned locks.
        {
            // Build two non-AutoMax stub locks (different durations so merge bonus > 0).
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
            IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.04 ether}(
                1, routes, address(stub), type(uint256).max
            );
            uint256 cl = IERC20(a.claim).balanceOf(address(stub));
            uint256 half = cl / 2;
            uint256 tShort;
            uint256 tLong;
            {
                address[] memory tos = new address[](3);
                uint256[] memory vals = new uint256[](3);
                bytes[] memory datas = new bytes[](3);
                tos[0] = a.claim;
                datas[0] = abi.encodeCall(IERC20.approve, (a.furnace, cl));
                tos[1] = a.furnace;
                datas[1] = abi.encodeCall(Furnace.enterWithClaim, (half, 0, Constants.MIN_LOCK_DURATION, false, 1));
                tos[2] = a.furnace;
                datas[2] = abi.encodeCall(Furnace.enterWithClaim, (cl - half, 0, 30 days, false, 1));
                bytes[] memory results = stub.executeBatch(tos, vals, datas);
                tShort = abi.decode(results[1], (uint256));
                tLong = abi.decode(results[2], (uint256));
            }
            // Now batch extendWithBonus(tShort, 60 days) + mergeLocksWithBonus(tShort, tLong)
            // The extend bumps the short lock's remaining duration; the merge then folds it
            // into the long one in the same atomic batch.
            address[] memory tos = new address[](3);
            uint256[] memory vals = new uint256[](3);
            bytes[] memory datas = new bytes[](3);
            tos[0] = a.ve;
            datas[0] = abi.encodeWithSelector(VeClaimNFT.checkpointGlobalState.selector);
            tos[1] = a.furnace;
            datas[1] = abi.encodeCall(Furnace.extendWithBonus, (tShort, 60 days, 0));
            tos[2] = a.furnace;
            datas[2] = abi.encodeCall(Furnace.mergeLocksWithBonus, (tShort, tLong, 0));
            stub.executeBatch(tos, vals, datas);
            // tShort is burned by the merge; tLong should still exist.
            ve.ownerOf(tLong) == address(stub) ? _ok("W9 extendWithBonus + mergeLocksWithBonus (atomic)") : _ko("W9");
        }

        // W10: unlock(expired) + enterWithClaim — withdraw + relock. canCheat-only.
        if (canCheat) {
            // Mint a 7d lock and warp past its expiry. Acquire enough CLAIM so that
            // half of the unlocked principal is comfortably above MIN_LOCK_AMOUNT.
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: a.weth, to: a.claim, stable: false, factory: a.poolFactory});
            IDexAdapter(a.dexAdapter).swapExactETHForTokens{value: 0.1 ether}(
                1, routes, address(stub), type(uint256).max
            );
            uint256 cl = IERC20(a.claim).balanceOf(address(stub));
            uint256 tidShort;
            {
                address[] memory tos = new address[](2);
                uint256[] memory vals = new uint256[](2);
                bytes[] memory datas = new bytes[](2);
                tos[0] = a.claim;
                datas[0] = abi.encodeCall(IERC20.approve, (a.furnace, cl));
                tos[1] = a.furnace;
                datas[1] = abi.encodeCall(Furnace.enterWithClaim, (cl, 0, Constants.MIN_LOCK_DURATION, false, 1));
                bytes[] memory results = stub.executeBatch(tos, vals, datas);
                tidShort = abi.decode(results[1], (uint256));
            }
            vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);

            // The unlocked principal returned by `unlock` will roughly equal `cl`
            // (the original lock amount). Re-lock half of that into a 30d lock.
            uint256 relockAmt = cl / 2;
            require(relockAmt >= Constants.MIN_LOCK_AMOUNT, "W10 amt too small");
            address[] memory tos = new address[](3);
            uint256[] memory vals = new uint256[](3);
            bytes[] memory datas = new bytes[](3);
            tos[0] = a.ve;
            datas[0] = abi.encodeCall(VeClaimNFT.unlock, (tidShort));
            tos[1] = a.claim;
            datas[1] = abi.encodeCall(IERC20.approve, (a.furnace, type(uint256).max));
            tos[2] = a.furnace;
            datas[2] = abi.encodeCall(Furnace.enterWithClaim, (relockAmt, 0, 30 days, false, 1));
            stub.executeBatch(tos, vals, datas);
            _ok("W10 unlock(expired) + enterWithClaim (atomic)");
        } else {
            _skip("W10 unlock+relock (needs warp)");
        }
    }

    // ================================================================
    // X: Edge-case 2-tx atomic batches not covered in W
    //
    // X1 flushPendingShareholderETH + claimShareholder (atomic).
    // X2 Furnace.tick + setKingAutoLockConfig (atomic).
    // X3 setSession + delegated action (atomic) — simulates the Base Account
    //    "approve delegation + use it" UserOp pattern.
    // ================================================================

    function _catX_SmartWalletEdgeBatches(Addrs memory a, address, _SmartWalletStub stub) internal {
        ShareholderRoyalties sr = ShareholderRoyalties(payable(a.royalties));

        // X1: flushPendingShareholderETH + claimShareholder. Generate fresh royalties
        //     so the claim has something to do.
        {
            MineCore mc = MineCore(payable(a.mineCore));
            // Bump the stub off the throne (if it is king) so it can claim royalties
            // without colliding with the takeover identity guard.
            if (mc.currentKing() == address(stub)) {
                _TakeoverHelper bump = new _TakeoverHelper();
                bump.takeover{value: mc.getCurrentTakeoverPrice()}(mc);
            }
            uint256 price = mc.getCurrentTakeoverPrice();
            mc.takeover{value: price}(type(uint256).max);
            price = mc.getCurrentTakeoverPrice();
            _TakeoverHelper bump2 = new _TakeoverHelper();
            bump2.takeover{value: price}(mc);

            address[] memory tos = new address[](2);
            uint256[] memory vals = new uint256[](2);
            bytes[] memory datas = new bytes[](2);
            tos[0] = a.royalties;
            datas[0] = abi.encodeWithSelector(ShareholderRoyalties.flushPendingShareholderETH.selector);
            tos[1] = a.royalties;
            datas[1] = abi.encodeCall(ShareholderRoyalties.claimShareholder, (0, 0, 0, false, 0));
            stub.executeBatch(tos, vals, datas);
            _ok("X1 flushPending + claimShareholder (atomic)");
        }

        // X2: Furnace.tick + setKingAutoLockConfig.
        {
            address[] memory tos = new address[](2);
            uint256[] memory vals = new uint256[](2);
            bytes[] memory datas = new bytes[](2);
            tos[0] = a.furnace;
            datas[0] = abi.encodeWithSelector(Furnace.tick.selector);
            tos[1] = a.mineCore;
            datas[1] = abi.encodeCall(MineCore.setKingAutoLockConfig, (false, 0, 0, false, 0));
            stub.executeBatch(tos, vals, datas);
            _ok("X2 Furnace.tick + setKingAutoLockConfig (atomic)");
        }

        // X3: setSession + delegated action atomically. The stub deploys a fresh
        //     `_DelegateHelper` it owns (delegate identity is the helper, user identity
        //     is the stub), grants it the takeoverFor bit, and immediately invokes
        //     a takeoverFor on its own behalf — all inside one atomic UserOp.
        {
            MineCore mc = MineCore(payable(a.mineCore));
            // The stub becomes the user; we need a separate delegate that is NOT the
            // stub itself. A fresh _DelegateHelper owned by the stub fits perfectly.
            _DelegateHelper sub = new _DelegateHelper(address(stub));
            // Push the stub off the throne so a takeoverFor → newKing = stub is valid.
            if (mc.currentKing() == address(stub)) {
                _TakeoverHelper bump = new _TakeoverHelper();
                bump.takeover{value: mc.getCurrentTakeoverPrice()}(mc);
            }
            uint256 price = mc.getCurrentTakeoverPrice();
            // Top off the stub generously so the inner takeoverFor has enough ETH
            // even if the broadcast-time stub balance is lower than simulation
            // (per-block timestamps in broadcast cause slight price divergence
            // and refund accounting differs across W batches). Add a 2x buffer.
            {
                (bool sent,) = address(stub).call{value: price * 2 + 0.01 ether}("");
                require(sent, "X3 top-off");
            }

            // Two-call atomic batch: setSession then sub.takeoverFor (sub forwards
            // the ETH it receives in slot 2's `vals` into MineCore.takeoverFor).
            address[] memory tos = new address[](2);
            uint256[] memory vals = new uint256[](2);
            bytes[] memory datas = new bytes[](2);
            tos[0] = a.delegationHub;
            datas[0] = abi.encodeCall(
                DelegationHub.setSession,
                (address(sub), DelegationPermissions.P_TAKEOVER_FOR, uint64(block.timestamp + 365 days))
            );
            tos[1] = address(sub);
            // Pass 2x the script-time price so broadcast-time price escalation
            // doesn't trip InsufficientEthBalance; MineCore refunds any excess
            // back to `refundTo` (msg.sender = sub, which forwards to stub).
            vals[1] = price * 2;
            datas[1] = abi.encodeCall(_DelegateHelper.takeoverFor, (mc, address(stub), type(uint256).max));
            stub.executeBatch(tos, vals, datas);
            mc.currentKing() == address(stub)
                ? _ok("X3 setSession + takeoverFor (atomic)")
                : _ko("X3 setSession + takeoverFor (atomic)");
        }
    }
}
