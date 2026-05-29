// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Fee-on-transfer token: skims 1% on every transfer (not mint/burn).
contract MockFoTToken is ERC20 {
    constructor() ERC20("FoT Token", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            uint256 fee = value / 100; // 1% fee
            super._update(from, to, value - fee);
            if (fee > 0) super._update(from, address(0), fee); // burn fee
        } else {
            super._update(from, to, value);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  TEST A:  Cross-registry isolation via Furnace.setEntryTokenRegistry
// ═══════════════════════════════════════════════════════════════════════

/// @notice Verifies that Furnace.setEntryTokenRegistry rejects a registry that
///         MineCore is already using, enforcing the cross-protocol split.
contract EntryTokenRegistryCrossIsolationTest is Test {
    address internal owner;

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;

    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal furnaceReg;
    EntryTokenRegistry internal mineCoreReg;

    function setUp() public {
        vm.txGasPrice(0);
        owner = makeAddr("owner");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );

        weth = new MockWETH();
        address factory = address(0xFACADE);
        vm.etch(factory, hex"01");
        router = new MockAerodromeRouter(factory, address(weth));

        furnaceReg = new EntryTokenRegistry(owner);
        mineCoreReg = new EntryTokenRegistry(owner);

        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());

        vm.startPrank(owner);

        // Wire Furnace so it considers address(this) as mineCore.
        vm.mockCall(address(this), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(address(this), abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        vm.mockCall(address(this), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        claim.setMineCore(address(this));
        vm.mockCall(address(this), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(this), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        furnace.setMineCore(address(this));

        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        ve.setMineMarket(market);
        ve.setFurnace(address(furnace));
        furnace.setMineMarket(market);
        furnace.setShareholderRoyalties(mockSR);

        vm.stopPrank();
    }

    /// @dev Furnace.setEntryTokenRegistry succeeds when MineCore uses a DIFFERENT registry.
    function testFurnaceAcceptsDifferentRegistryFromMineCore() public {
        // Mock: MineCore's entryTokenRegistry() returns mineCoreReg.
        vm.mockCall(address(this), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(address(mineCoreReg)));

        vm.prank(owner);
        furnace.setEntryTokenRegistry(address(furnaceReg));
        assertEq(furnace.entryTokenRegistry(), address(furnaceReg));
    }

    /// @dev Furnace.setEntryTokenRegistry reverts when MineCore uses the SAME registry.
    function testFurnaceRejectsSharedRegistryWithMineCore() public {
        // Mock: MineCore's entryTokenRegistry() returns furnaceReg (the same one).
        vm.mockCall(address(this), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(address(furnaceReg)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setEntryTokenRegistry(address(furnaceReg));
    }

    /// @dev Furnace.setEntryTokenRegistry succeeds when MineCore has no registry set (address(0)).
    function testFurnaceAcceptsRegistryWhenMineCoreHasNone() public {
        vm.mockCall(address(this), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(address(0)));

        vm.prank(owner);
        furnace.setEntryTokenRegistry(address(furnaceReg));
        assertEq(furnace.entryTokenRegistry(), address(furnaceReg));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  TEST B:  FoT token rejection at MineCore consumer level
// ═══════════════════════════════════════════════════════════════════════

/// @notice Verifies that MineCore.takeoverWithToken rejects fee-on-transfer tokens
///         even if the registry has allowlisted the token (the _pullTokenWithFoTCheck
///         balance-delta guard catches it).
contract EntryTokenRegistryFoTRejectionTest is Test {
    address internal owner = address(0xA11CE);
    address internal alice;

    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;
    MineCoreHarness internal mineCore;

    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;
    MockFoTToken internal fotToken;

    address internal factory = address(0xFACA);
    address internal pool = address(0xBEEF);

    function setUp() public {
        vm.txGasPrice(0);
        alice = makeAddr("alice");

        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        weth = new MockWETH();
        vm.etch(factory, hex"00");
        router = new MockAerodromeRouter(factory, address(weth));
        registry = new EntryTokenRegistry(owner);
        fotToken = new MockFoTToken();

        // Wire protocol.
        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        ve.setClaimToken(address(claim));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        vm.etch(address(0xB0B0), hex"00");
        furnace.setMineMarket(address(0xB0B0));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(0xB0B0));
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);

        // Configure EntryTokenRegistry with the FoT token.
        router.setPoolFor(address(fotToken), address(weth), false, factory, pool);
        vm.etch(pool, hex"00");
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
        registry.setTokenConfig(address(fotToken), true, false, false, address(0), false, pool);
        mineCore.setEntryTokenRegistry(address(registry));
        vm.stopPrank();

        ve.setTotalVeCached(1234);
        vm.deal(address(weth), 100 ether);
    }

    /// @dev MineCore._pullTokenWithFoTCheck rejects FoT tokens because
    ///      balAfter - balBefore < amountIn.
    function testTakeoverWithFoTTokenRevertsTransferFailed() public {
        fotToken.mint(alice, 10 ether);
        vm.prank(alice);
        fotToken.approve(address(mineCore), 10 ether);

        vm.warp(mineCore.emissionStartTime() + 1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.prank(alice);
        vm.expectRevert(Errors.TransferFailed.selector);
        mineCore.takeoverWithToken(address(fotToken), 1 ether, floor, type(uint256).max);
    }
}
