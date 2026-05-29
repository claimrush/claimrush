// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockShareholderRoyaltiesCheckpointSpy} from "./mocks/MockShareholderRoyaltiesCheckpointSpy.sol";

import {
    ReturnBombShareholderRoyalties,
    RevertBombShareholderRoyalties,
    MockMarketRouterRoyalties
} from "./mocks/ReturnBombWiring.sol";

contract VeClaimNFTTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal charlie = address(0xC);
    address internal dave = address(0xD);
    address internal delegate = address(0xD1E6);

    DelegationHub internal canonicalHub;
    DelegationHub internal evilHub;

    function setUp() public {
        // Mock addresses must look like contracts for NotAContract guards.
        // mineCore (0xC0DE) is the canonical minter set in setUp via claim.setMineCore(mineCore).
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        canonicalHub = new DelegationHub();
        evilHub = new DelegationHub();

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));

        // Resolve the same royalties address from both live wiring surfaces by default.
        // Single-surface drift is tested explicitly below.
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));

        // Default reciprocal wiring mocks so furnace, market, mineCore, and royalties agree with VeClaimNFT.
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();
    }

    function _mockDriftedMineMarket(address badMarket, address royaltiesAddr) internal {
        vm.etch(badMarket, hex"00");
        vm.mockCall(badMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badMarket, abi.encodeWithSignature("royalties()"), abi.encode(royaltiesAddr));
    }

    function _forceSetFurnace(address newFurnace) internal {
        vm.store(address(ve), bytes32(uint256(10)), bytes32(uint256(uint160(newFurnace))));
    }

    function _forceSetMineMarket(address newMarket) internal {
        vm.store(address(ve), bytes32(uint256(9)), bytes32(uint256(uint160(newMarket))));
    }

    function testConstructorRevertsWhenClaimTokenIsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new VeClaimNFTHarness(address(0xBEEF), owner);
    }

    function testFuzz_constructorRevertsWhenClaimTokenIsEoa(address badClaim) public {
        vm.assume(badClaim != address(0));
        vm.assume(badClaim.code.length == 0);

        vm.expectRevert(Errors.NotAContract.selector);
        new VeClaimNFTHarness(badClaim, owner);
    }

    function testWiringOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ve.setMineMarket(address(0x1234));
    }

    function testResolveShareholderRoyalties_ReturnDataBombDoesNotOOG() public {
        // Return a very large buffer from furnace.shareholderRoyalties(), but with a valid address in the first word.
        ReturnBombShareholderRoyalties bomb = new ReturnBombShareholderRoyalties(address(srMock), 524_288);

        _forceSetFurnace(address(bomb));

        // Call with a bounded gas limit: should succeed if VeClaimNFT does not copy full returndata into memory.
        (bool ok, bytes memory ret) = address(ve).call{gas: 1_000_000}(
            abi.encodeWithSelector(VeClaimNFTHarness.resolveShareholderRoyaltiesForTest.selector)
        );
        assertTrue(ok, "resolve should not OOG");
        address sr = abi.decode(ret, (address));
        assertEq(sr, address(srMock));
    }

    function testResolveShareholderRoyalties_RevertDataBombFallsBackToMineMarket() public {
        // Revert with a large buffer from furnace.shareholderRoyalties(); VeClaimNFT should not copy revertdata,
        // and should fall back to MineMarket.royalties().
        MockShareholderRoyaltiesCheckpoint localSrMock = new MockShareholderRoyaltiesCheckpoint();
        RevertBombShareholderRoyalties bomb = new RevertBombShareholderRoyalties(524_288);
        MockMarketRouterRoyalties mm = new MockMarketRouterRoyalties(address(localSrMock));

        _forceSetFurnace(address(bomb));
        _forceSetMineMarket(address(mm));

        (bool ok, bytes memory ret) = address(ve).call{gas: 1_000_000}(
            abi.encodeWithSelector(VeClaimNFTHarness.resolveShareholderRoyaltiesForTest.selector)
        );
        assertTrue(ok, "resolve should not OOG on revertdata");
        address sr = abi.decode(ret, (address));
        assertEq(sr, address(localSrMock));
    }

    function testSetAutoMaxRevertsWhenResolvedRoyaltiesVeRootMismatches() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT * 3);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(0xDEAD)));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setAutoMax(tokenId, true);
    }

    function testCreateLockRevertsWhenMineMarketHasNoRoyaltiesGetter() public {
        address bareMarket = address(new MockShareholderRoyaltiesCheckpoint());

        _forceSetMineMarket(bareMarket);

        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();
    }

    function testMergeLocksForRevertsWhenFurnaceClaimRootMismatches() public {
        // v1.0.0: the raw `mergeLocksForUser` external is removed. The Furnace-only
        // `mergeLocksFor` sibling preserves the canonical-bundle WiringMismatch path
        // through `onlyFurnace` (`_requireCanonicalFurnaceCaller`), so we drive that
        // by pranking from `furnace` after spoofing `furnace.claim()` to a non-canonical
        // address. The user-facing entrypoint (`Furnace.mergeLocksWithBonus{,For}`) is
        // covered by `Furnace_MergeLocksWithBonus.t.sol`.
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT * 4);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 fromTokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        uint256 intoTokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(0xDEAD)));

        vm.prank(furnace);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.mergeLocksFor(alice, fromTokenId, intoTokenId);

        assertEq(ve.ownerOf(fromTokenId), alice, "source lock must remain owned by user");
        assertEq(ve.ownerOf(intoTokenId), alice, "destination lock must remain owned by user");
    }

    function _mockDirectRootsOnlyFurnace(address badFurnace, address marketAddr) internal {
        vm.etch(badFurnace, hex"00");
        vm.mockCall(badFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineMarket()"), abi.encode(marketAddr));
    }

    function testCreateLockForRevertsWhenSpoofFurnaceOmitsMineCoreGetterEvenIfDirectRootsMatch() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        address badFurnace = makeAddr("badFurnaceMissingMineCoreCreate");
        _mockDirectRootsOnlyFurnace(badFurnace, mineMarket);
        _forceSetFurnace(badFurnace);

        vm.prank(mineCore);
        claim.mint(badFurnace, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(badFurnace);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        assertEq(ve.balanceOf(alice), 0, "missing mineCore getter must not allow spoof furnace lock creation");
        assertEq(ve.totalLockedClaim(), 0, "missing mineCore getter must not mutate principal");
    }

    function testCreateLockForRevertsWhenVeFurnaceDriftsFromCanonicalMineCoreAndRoyalties() public {
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));

        address badFurnace = makeAddr("badFurnace");
        vm.etch(badFurnace, hex"00");
        vm.mockCall(badFurnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        _forceSetFurnace(badFurnace);

        vm.prank(mineCore);
        claim.mint(badFurnace, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(badFurnace);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        assertEq(ve.balanceOf(alice), 0, "foreign furnace must not create a victim lock under drift");
        assertEq(ve.totalLockedClaim(), 0, "foreign furnace drift must not mutate locked principal");
    }

    function testAddToLockForRevertsWhenVeFurnaceDriftsFromCanonicalMineCoreAndRoyalties() public {
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));

        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT * 2);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badFurnace = makeAddr("badFurnace2");
        vm.etch(badFurnace, hex"00");
        vm.mockCall(badFurnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        _forceSetFurnace(badFurnace);

        vm.prank(mineCore);
        claim.mint(badFurnace, Constants.MIN_LOCK_AMOUNT);

        (uint256 oldAmount,,,) = ve.getLockInfo(tokenId);

        vm.startPrank(badFurnace);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.addToLockFor(alice, tokenId, Constants.MIN_LOCK_AMOUNT);
        vm.stopPrank();

        (uint256 newAmount,,,) = ve.getLockInfo(tokenId);
        assertEq(newAmount, oldAmount, "foreign furnace drift must not top up victim lock");
        assertEq(ve.totalLockedClaim(), oldAmount, "principal accounting must stay unchanged on revert");
    }

    function testAddToLockForRevertsWhenSpoofFurnaceOmitsMineCoreGetterEvenIfDirectRootsMatch() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT * 2);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badFurnace = makeAddr("badFurnaceMissingMineCoreAdd");
        _mockDirectRootsOnlyFurnace(badFurnace, mineMarket);
        _forceSetFurnace(badFurnace);

        vm.prank(mineCore);
        claim.mint(badFurnace, Constants.MIN_LOCK_AMOUNT);

        (uint256 oldAmount,,,) = ve.getLockInfo(tokenId);

        vm.startPrank(badFurnace);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.addToLockFor(alice, tokenId, Constants.MIN_LOCK_AMOUNT);
        vm.stopPrank();

        (uint256 newAmount,,,) = ve.getLockInfo(tokenId);
        assertEq(newAmount, oldAmount, "missing mineCore getter must not allow spoof furnace top-up");
        assertEq(ve.totalLockedClaim(), oldAmount, "principal accounting must stay unchanged on revert");
    }

    function testExtendLockToForRevertsWhenVeFurnaceDriftsFromCanonicalMineCoreAndRoyalties() public {
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));

        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badFurnace = makeAddr("badFurnace3");
        vm.etch(badFurnace, hex"00");
        vm.mockCall(badFurnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        _forceSetFurnace(badFurnace);

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);

        vm.prank(badFurnace);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.extendLockToFor(alice, tokenId, oldEnd + 1 days);

        (, uint256 newEnd,,) = ve.getLockInfo(tokenId);
        assertEq(newEnd, oldEnd, "foreign furnace drift must not extend victim lock");
    }

    function testExtendLockToForRevertsWhenSpoofFurnaceOmitsMineCoreGetterEvenIfDirectRootsMatch() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badFurnace = makeAddr("badFurnaceMissingMineCoreExtend");
        _mockDirectRootsOnlyFurnace(badFurnace, mineMarket);
        _forceSetFurnace(badFurnace);

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);

        vm.prank(badFurnace);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.extendLockToFor(alice, tokenId, oldEnd + 1 days);

        (, uint256 newEnd,,) = ve.getLockInfo(tokenId);
        assertEq(newEnd, oldEnd, "missing mineCore getter must not allow spoof furnace extension");
    }

    function testFurnaceOnlyMutatorsStillSucceedWhenCanonicalWiringAgrees() public {
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));

        vm.prank(mineCore);
        claim.mint(furnace, Constants.MIN_LOCK_AMOUNT * 3);

        vm.startPrank(furnace);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        ve.addToLockFor(alice, tokenId, Constants.MIN_LOCK_AMOUNT);
        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);
        ve.extendLockToFor(alice, tokenId, oldEnd + 1 days);
        vm.stopPrank();

        (uint256 amount, uint256 lockEnd,,) = ve.getLockInfo(tokenId);
        assertEq(amount, Constants.MIN_LOCK_AMOUNT * 2);
        assertEq(lockEnd, oldEnd + 1 days);
        assertEq(ve.totalLockedClaim(), Constants.MIN_LOCK_AMOUNT * 2);
    }

    function testSetListedOnlyMineMarket() public {
        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, 7 days, false);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        ve.setListed(tokenId, true);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertTrue(listed);
    }

    function testSetListedRevertsWhenCanonicalMarketUsesFurnaceWithoutMineCoreGetter() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badFurnace = makeAddr("badFurnaceMissingMineCoreList");
        _mockDirectRootsOnlyFurnace(badFurnace, mineMarket);
        _forceSetFurnace(badFurnace);

        vm.prank(mineMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setListed(tokenId, true);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertFalse(listed, "canonical market must fail closed when live furnace omits mineCore getter");
    }

    function testSetListedRevertsWhenVeMineMarketDriftsFromCanonicalFurnaceAndLockRemainsMutable() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badMarket = makeAddr("badMineMarket");
        _mockDriftedMineMarket(badMarket, address(srMock));
        _forceSetMineMarket(badMarket);

        vm.prank(badMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setListed(tokenId, true);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertFalse(listed, "foreign market drift must not freeze the lock");
    }

    function testSetListedRevertsWhenVeMineMarketRoyaltiesRootMismatches() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        MockShareholderRoyaltiesCheckpoint otherSr = new MockShareholderRoyaltiesCheckpoint();
        address badMarket = makeAddr("badMineMarketRoyalties");
        _mockDriftedMineMarket(badMarket, address(otherSr));
        _forceSetMineMarket(badMarket);
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(badMarket));

        vm.prank(badMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setListed(tokenId, true);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertFalse(listed, "mismatched royalties root must not freeze the lock");
    }

    function testDelistRevertsWhenVeMineMarketDriftsFromCanonicalFurnaceAndListingStaysSet() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        address badMarket = makeAddr("badMineMarketDelist");
        _mockDriftedMineMarket(badMarket, address(srMock));
        _forceSetMineMarket(badMarket);

        vm.prank(badMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setListed(tokenId, false);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertTrue(listed, "foreign market drift must not clear canonical listings");
    }

    function testTransferRestrictedToMineMarket() public {
        uint256 tokenId = 1;
        ve.mintForTest(alice, tokenId);

        // Owner cannot transfer directly.
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        ve.transferFrom(alice, bob, tokenId);

        // Seller can approve the market, but market is only allowed to transfer into Furnace custody.
        ve.approveForTest(mineMarket, tokenId);

        vm.prank(mineMarket);
        vm.expectRevert(Errors.MarketMustTransferToFurnace.selector);
        ve.transferFrom(alice, bob, tokenId);

        vm.prank(mineMarket);
        ve.transferFrom(alice, furnace, tokenId);

        assertEq(ve.ownerOf(tokenId), furnace);
    }

    function testTransferFromRevertsWhenVeMineMarketDriftsFromCanonicalFurnace() public {
        uint256 tokenId = 1;
        ve.mintForTest(alice, tokenId);

        address badMarket = makeAddr("badMineMarketTransfer");
        _mockDriftedMineMarket(badMarket, address(srMock));
        _forceSetMineMarket(badMarket);
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(badMarket));

        ve.approveForTest(badMarket, tokenId);

        vm.prank(badMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.transferFrom(alice, furnace, tokenId);

        assertEq(ve.ownerOf(tokenId), alice, "foreign market drift must not transfer custody");
    }

    function testVeNftCapEnforcedOnMintCreateLockAndTransfer() public {
        uint256 cap = Constants.MAX_VE_NFTS_PER_USER;

        // Fill alice to cap using test mints.
        for (uint256 i = 0; i < cap; i++) {
            ve.mintForTest(alice, i + 1);
        }

        // Next mint must revert.
        vm.expectRevert(Errors.TooManyVeNFTs.selector);
        ve.mintForTest(alice, cap + 1);

        // createLock must revert (cap check runs before pulling CLAIM).
        vm.prank(alice);
        vm.expectRevert(Errors.TooManyVeNFTs.selector);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        // Fill bob to cap.
        for (uint256 i = 0; i < cap; i++) {
            ve.mintForTest(bob, 1000 + i);
        }

        // Next mint to bob must revert.
        vm.expectRevert(Errors.TooManyVeNFTs.selector);
        ve.mintForTest(bob, 2000);

        // In strict mode, Market may only transfer veNFTs into Furnace custody.
        ve.approveForTest(mineMarket, 1);

        vm.prank(mineMarket);
        vm.expectRevert(Errors.MarketMustTransferToFurnace.selector);
        ve.transferFrom(alice, bob, 1);
    }

    function testSlopeTimeHeapRemovesClearedTimestampsSoCheckpointCatchesUp() public {
        uint256 startTs = block.timestamp;
        uint256 newEnd = startTs + Constants.MAX_LOCK_DURATION;

        uint256 perLock = Constants.MIN_LOCK_AMOUNT;
        uint256 totalLocks = Constants.MAX_SLOPE_CHANGES_PER_CALL + 1;
        uint256 cap = Constants.MAX_VE_NFTS_PER_USER;

        uint256 usersNeeded = (totalLocks + cap - 1) / cap;
        address[] memory users = new address[](usersNeeded);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = dave;
        for (uint256 u = 4; u < usersNeeded; u++) {
            users[u] = address(uint160(0xBEEF0000 + u));
        }

        uint256 remaining = totalLocks;
        uint256 unique;

        for (uint256 u = 0; u < users.length; u++) {
            if (remaining == 0) break;

            uint256 count = remaining > cap ? cap : remaining;
            remaining -= count;

            // Fund the user for exactly `count` minimum-sized locks.
            vm.prank(mineCore);
            claim.mint(users[u], perLock * count);

            vm.startPrank(users[u]);
            claim.approve(address(ve), perLock * count);

            for (uint256 i = 0; i < count; i++) {
                // Unique end timestamps across ALL users.
                uint256 duration = Constants.MIN_LOCK_DURATION + unique;
                unique++;

                uint256 tokenId = ve.createLock(perLock, duration, false);
                // Move the slope change from `oldEnd` to `newEnd` via the furnace path.
                vm.stopPrank();
                vm.prank(furnace);
                ve.extendLockToFor(users[u], tokenId, newEnd);
                vm.startPrank(users[u]);
            }

            vm.stopPrank();
        }

        assertEq(remaining, 0, "did not create enough locks");
        assertEq(unique, totalLocks, "duration counter mismatch");

        // Warp past all original end times (but still before `newEnd`).
        vm.warp(startTs + Constants.MIN_LOCK_DURATION + totalLocks + 1);

        ve.checkpointGlobalState();
        assertEq(
            ve.globalLastTsForTest(),
            block.timestamp,
            "checkpoint should fully catch up when cleared slope-times are removed from the heap"
        );
    }

    function testAutoMax_KeepsMaxVeForever_AndNeverExpires() public {
        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        // Immediately: ve == amount.
        assertEq(ve.veBalanceOf(alice), amount);
        (uint256 locked0, uint256 lockEnd0, bool autoMax0, bool listed0) = ve.getLockInfo(tokenId);
        assertEq(locked0, amount);
        assertTrue(autoMax0);
        assertFalse(listed0);

        // lockEnd0 is opaque to the via_ir optimizer (returned via external call).
        // Derive creation timestamp from it to avoid TIMESTAMP CSE issues.
        uint256 creationTs = lockEnd0 - Constants.MAX_LOCK_DURATION;

        // After time passes: ve still == amount and effective lockEnd tracks now + MAX.
        vm.warp(creationTs + 200 days);
        assertEq(ve.veBalanceOf(alice), amount);
        (, uint256 lockEnd1, bool autoMax1,) = ve.getLockInfo(tokenId);
        assertTrue(autoMax1);
        assertEq(lockEnd1, lockEnd0 + 200 days);

        // Even after more than a year passes since creation, an AutoMax lock should not be treated as expired.
        vm.warp(lockEnd0 + 1 days);

        // MineMarket should be able to list it (expiry is ignored for AutoMax).
        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        (,,, bool listed2) = ve.getLockInfo(tokenId);
        assertTrue(listed2);
    }

    function testAutoMax_DisableStartsFreshMaxDurationDecay_AndUnlockBlockedWhileEnabled() public {
        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);

        // Cannot unlock while AutoMax is enabled.
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);

        // Disable AutoMax: lock becomes a fresh max-duration decaying lock.
        ve.setAutoMax(tokenId, false);
        vm.stopPrank();

        (uint256 locked, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(tokenId);
        assertEq(locked, amount);
        assertFalse(autoMax);
        assertEq(lockEnd, block.timestamp + Constants.MAX_LOCK_DURATION);

        // Immediately after disabling: still max ve.
        assertEq(ve.veBalanceOf(alice), amount);

        // Halfway through: ~50% ve (floor).
        vm.warp(block.timestamp + (Constants.MAX_LOCK_DURATION / 2));
        assertEq(ve.veBalanceOf(alice), amount / 2);
    }

    function testAutoMax_EnableOnShortLock_BumpsToMaxVeAndStopsDecay() public {
        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);

        // Create a short lock.
        uint256 tokenId = ve.createLock(amount, 30 days, false);
        uint256 veShort = ve.veBalanceOf(alice);
        assertLt(veShort, amount);

        // Enable AutoMax: ve becomes amount and remains there.
        ve.setAutoMax(tokenId, true);
        assertEq(ve.veBalanceOf(alice), amount);

        vm.warp(block.timestamp + 20 days);
        assertEq(ve.veBalanceOf(alice), amount);

        vm.stopPrank();
    }

    function testAutoMax_CreateLockRequiresMaxDuration() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);

        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(amount, Constants.MAX_LOCK_DURATION - 1, true);

        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        assertEq(tokenId, 1);
        vm.stopPrank();
    }

    function testAutoMax_DisableAfterLongTime_ResetsEndAndUnlockAfterOneYear() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);

        // Read the stored lock end from the contract to avoid via_ir TIMESTAMP caching.
        (, uint256 storedEnd,,) = ve.getLockInfo(tokenId);

        // Jump beyond the originally stored end (t0 + MAX), so storage end is stale.
        uint256 t1 = storedEnd + 10 days;
        vm.warp(t1);

        // AutoMax remains active: effective end rolls forward and unlock is still blocked.
        (, uint256 effEnd, bool autoMax0,) = ve.getLockInfo(tokenId);
        assertTrue(autoMax0);
        uint256 expectedEnd = t1 + Constants.MAX_LOCK_DURATION;
        assertEq(effEnd, expectedEnd);

        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);

        // Disabling AutoMax converts it into a fresh max-duration decaying lock starting now.
        ve.setAutoMax(tokenId, false);

        (, uint256 newEnd, bool autoMax1,) = ve.getLockInfo(tokenId);
        assertFalse(autoMax1);
        assertEq(newEnd, expectedEnd);

        // Still not unlockable until the new end.
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);

        // Halfway through the fresh duration: floor(amount * 0.5).
        vm.warp(t1 + (Constants.MAX_LOCK_DURATION / 2));
        assertEq(ve.veBalanceOf(alice), amount / 2);

        // Just before expiry: still locked.
        vm.warp(expectedEnd - 1);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);

        // At expiry: unlock succeeds and burns the veNFT.
        vm.warp(expectedEnd);
        uint256 aliceBefore = claim.balanceOf(alice);
        ve.unlock(tokenId);
        vm.stopPrank();

        assertEq(claim.balanceOf(alice), aliceBefore + amount);
        assertEq(ve.totalLockedClaim(), 0);
        assertEq(claim.balanceOf(address(ve)), 0);

        vm.expectRevert();
        ve.ownerOf(tokenId);
    }

    function testAutoMax_EnableRefreshesEndAndPreventsExpiry() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);

        // Create a short non-AutoMax lock.
        uint256 tokenId = ve.createLock(amount, 30 days, false);
        (, uint256 end0, bool auto0,) = ve.getLockInfo(tokenId);
        assertFalse(auto0);

        // end0 is opaque to the via_ir optimizer (returned via external call).
        // Derive creation timestamp from it to avoid TIMESTAMP CSE issues.
        uint256 creationTs = end0 - 30 days;

        // Let it decay.
        vm.warp(creationTs + 20 days);
        assertLt(ve.veBalanceOf(alice), amount);

        // Enable AutoMax: end becomes rolling now+MAX, and ve becomes amount.
        ve.setAutoMax(tokenId, true);

        (, uint256 end1, bool auto1,) = ve.getLockInfo(tokenId);
        assertTrue(auto1);
        assertEq(end1, creationTs + 20 days + Constants.MAX_LOCK_DURATION);
        assertEq(ve.veBalanceOf(alice), amount);

        // Even after the original end passes, the lock is still not unlockable while AutoMax is on.
        vm.warp(creationTs + 40 days);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);

        // Effective end continues to roll.
        (, uint256 end2, bool auto2,) = ve.getLockInfo(tokenId);
        assertTrue(auto2);
        assertEq(end2, creationTs + 40 days + Constants.MAX_LOCK_DURATION);

        vm.stopPrank();
    }

    function testAutoMax_MergeLocksAutoMaxDominatesAndVeIsSum() public {
        uint256 amount1 = Constants.MIN_LOCK_AMOUNT;
        uint256 amount2 = Constants.MIN_LOCK_AMOUNT;

        vm.prank(mineCore);
        claim.mint(alice, amount1 + amount2);

        vm.startPrank(alice);
        claim.approve(address(ve), amount1 + amount2);

        uint256 id1 = ve.createLock(amount1, 30 days, false);
        uint256 id2 = ve.createLock(amount2, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        // v1.0.0: external user merge lives on Furnace; the AutoMax-OR lock-math
        // under test is reached via the Furnace-only `mergeLocksFor` sibling.
        // (Furnace's `mergeLocksWithBonus` rejects mismatched-AutoMax pairs in
        // `FurnaceGuardHelper.resolveMergeWithBonus`; that policy is exercised in
        // `Furnace_MergeLocksWithBonus.t.sol`.)
        vm.prank(furnace);
        ve.mergeLocksFor(alice, id1, id2);

        vm.startPrank(alice);

        // id1 burned.
        vm.expectRevert();
        ve.ownerOf(id1);

        // Destination is still autoMax and has the combined amount.
        (uint256 amt, uint256 end, bool autoMax, bool listed) = ve.getLockInfo(id2);
        assertTrue(autoMax);
        assertFalse(listed);
        assertEq(amt, amount1 + amount2);
        assertEq(end, block.timestamp + Constants.MAX_LOCK_DURATION);

        // ve == combined amount.
        assertEq(ve.veBalanceOf(alice), amount1 + amount2);

        vm.stopPrank();
    }

    function testExtendLockToFor_CheckpointsShareholderRoyaltiesBeforeChangingLockEnd() public {
        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, 30 days, false);
        vm.stopPrank();

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);

        MockShareholderRoyaltiesCheckpointSpy spy = new MockShareholderRoyaltiesCheckpointSpy(address(ve));
        spy.setTokenIdToInspect(tokenId);
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(spy)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(spy)));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(spy)));
        vm.mockCall(address(spy), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(spy), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(spy), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(spy), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        uint256 newEnd = oldEnd + 30 days;
        vm.prank(furnace);
        ve.extendLockToFor(alice, tokenId, newEnd);

        (, uint256 updatedEnd,,) = ve.getLockInfo(tokenId);
        assertEq(updatedEnd, newEnd);
        assertEq(
            spy.checkpointCalls(), 1, "extend checkpoints resolved ShareholderRoyalties once before changing lock end"
        );
        assertEq(spy.firstObservedLockEnd(), oldEnd, "checkpoint must observe pre-extension end");
        assertEq(spy.lastObservedLockEnd(), oldEnd, "single checkpoint must use old end");
    }

    function testExtendLockToForThenAddToLock_FirstCheckpointUsesOldEnd() public {
        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, 30 days, false);
        vm.stopPrank();

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);

        MockShareholderRoyaltiesCheckpointSpy spy = new MockShareholderRoyaltiesCheckpointSpy(address(ve));
        spy.setTokenIdToInspect(tokenId);
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(spy)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(spy)));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(spy)));
        vm.mockCall(address(spy), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(spy), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(spy), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(spy), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        uint256 topUp = 1_000e18;
        vm.prank(mineCore);
        claim.mint(furnace, topUp);
        vm.prank(furnace);
        claim.approve(address(ve), topUp);

        uint256 newEnd = oldEnd + 60 days;
        vm.startPrank(furnace);
        ve.extendLockToFor(alice, tokenId, newEnd);
        ve.addToLockFor(alice, tokenId, topUp);
        vm.stopPrank();

        assertEq(spy.checkpointCalls(), 2, "extend and add each checkpoint resolved ShareholderRoyalties once");
        assertEq(spy.firstObservedLockEnd(), oldEnd, "historical rewards must settle at the old end");
        assertEq(spy.lastObservedLockEnd(), newEnd, "later checkpoint may observe the new end");
    }

    function testFuzz_extendLockToForThenAddToLock_FirstCheckpointUsesOldEnd(
        uint40 durationRaw,
        uint40 extensionRaw,
        uint96 topUpRaw
    ) public {
        uint256 duration = bound(uint256(durationRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION - 1);
        uint256 extension = bound(uint256(extensionRaw), 1, Constants.MAX_LOCK_DURATION - duration);
        uint256 topUp = bound(uint256(topUpRaw), 1_000e18, 10_000e18);

        uint256 amount = 1_000e18;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, duration, false);
        vm.stopPrank();

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);

        MockShareholderRoyaltiesCheckpointSpy spy = new MockShareholderRoyaltiesCheckpointSpy(address(ve));
        spy.setTokenIdToInspect(tokenId);
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(spy)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(spy)));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(spy)));
        vm.mockCall(address(spy), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(spy), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(spy), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(spy), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(mineCore);
        claim.mint(furnace, topUp);
        vm.prank(furnace);
        claim.approve(address(ve), topUp);

        uint256 newEnd = oldEnd + extension;
        vm.startPrank(furnace);
        ve.extendLockToFor(alice, tokenId, newEnd);
        ve.addToLockFor(alice, tokenId, topUp);
        vm.stopPrank();

        assertEq(spy.firstObservedLockEnd(), oldEnd, "first checkpoint must use the pre-extension end");
    }

    // ====================================================================
    // ====================================================================

    // ------------------------------------------------------------------
    //  F-01  furnaceBurnAndWithdraw missing shareholder checkpoint
    // ------------------------------------------------------------------
    //  furnaceBurnAndWithdraw does NOT call _checkpointShareholderRoyalties
    //  before removing the lock's ve contribution.  This is acceptable ONLY
    //  because the lock is already in Furnace custody (ownerOf == furnace)
    //  and ShareholderRoyalties never accrues to the Furnace address itself.
    //  The following test documents and pins that assumption.
    function testFurnaceBurnAndWithdraw_NoShareholderCheckpointNeeded_BecauseFurnaceIsNotABaron() public {
        vm.prank(mineCore);
        claim.mint(furnace, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(furnace);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        uint256 tokenId = ve.createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        // Transfer lock into Furnace custody (via MineMarket as required by transfer restriction).
        ve.approveForTest(mineMarket, tokenId);
        vm.prank(mineMarket);
        ve.transferFrom(alice, furnace, tokenId);

        // Burn-and-withdraw should succeed without a shareholder checkpoint on furnace.
        vm.prank(furnace);
        uint256 withdrawn = ve.furnaceBurnAndWithdraw(tokenId, alice);
        assertEq(withdrawn, Constants.MIN_LOCK_AMOUNT);
        assertEq(ve.totalLockedClaim(), 0);
    }

    // ------------------------------------------------------------------
    //  F-02  unlock on expired lock returns correct CLAIM
    // ------------------------------------------------------------------
    function testUnlock_ReturnsFullPrincipal_AfterExpiry() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        uint256 balBefore = claim.balanceOf(alice);
        vm.prank(alice);
        ve.unlock(tokenId);

        assertEq(claim.balanceOf(alice), balBefore + amount);
        assertEq(ve.totalLockedClaim(), 0);
        assertEq(claim.balanceOf(address(ve)), 0);
    }

    // ------------------------------------------------------------------
    //  F-03  unlock reverts before expiry
    // ------------------------------------------------------------------
    function testUnlock_RevertsBeforeExpiry() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, false);

        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    //  F-05  addToLock reverts on expired lock
    // ------------------------------------------------------------------
    function testAddToLock_RevertsOnExpiredLock() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount * 2);

        vm.startPrank(alice);
        claim.approve(address(ve), amount * 2);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        vm.prank(alice);
        vm.expectRevert(Errors.LockExpired.selector);
        ve.addToLock(tokenId, amount);
    }

    // ------------------------------------------------------------------
    //  F-06  mergeLocks reverts when one lock is expired
    // ------------------------------------------------------------------
    function testMergeLocks_RevertsWhenSourceExpired() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount * 2);

        vm.startPrank(alice);
        claim.approve(address(ve), amount * 2);
        uint256 id1 = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        uint256 id2 = ve.createLock(amount, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        // Expire id1.
        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        // v1.0.0: expired-source revert lives on `_mergeLocksInternal`; reachable via
        // the Furnace-only `mergeLocksFor` sibling. Furnace's user-facing path also
        // surfaces this via `FurnaceGuardHelper.resolveMergeWithBonus` (covered in
        // `Furnace_MergeLocksWithBonus.t.sol`).
        vm.prank(furnace);
        vm.expectRevert(Errors.LockExpired.selector);
        ve.mergeLocksFor(alice, id1, id2);
    }

    // ------------------------------------------------------------------
    //  F-07  mergeLocks reverts when destination lock is expired
    // ------------------------------------------------------------------
    function testMergeLocks_RevertsWhenDestinationExpired() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount * 2);

        vm.startPrank(alice);
        claim.approve(address(ve), amount * 2);
        uint256 id1 = ve.createLock(amount, Constants.MAX_LOCK_DURATION, false);
        uint256 id2 = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        // Expire id2.
        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        // v1.0.0: expired-destination revert lives on `_mergeLocksInternal`; reachable
        // via the Furnace-only `mergeLocksFor` sibling.
        vm.prank(furnace);
        vm.expectRevert(Errors.LockExpired.selector);
        ve.mergeLocksFor(alice, id1, id2);
    }

    // ------------------------------------------------------------------
    //  F-08  setListed reverts on expired non-autoMax lock
    // ------------------------------------------------------------------
    function testSetListed_RevertsOnExpiredNonAutoMaxLock() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        vm.prank(mineMarket);
        vm.expectRevert(Errors.LockExpired.selector);
        ve.setListed(tokenId, true);
    }

    // ------------------------------------------------------------------
    //  F-09  unlock reverts on listed lock
    // ------------------------------------------------------------------
    function testUnlock_RevertsOnListedLock() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        ve.unlock(tokenId);
    }

    // ------------------------------------------------------------------
    //  F-10  veBalanceOf returns 0 after full expiry
    // ------------------------------------------------------------------
    function testVeBalanceOf_ReturnsZeroAfterExpiry() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);
        assertEq(ve.veBalanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    //  F-11  totalVeCached conservative invariant after multiple operations
    // ------------------------------------------------------------------
    function testTotalVeCached_IsConservative_AfterMixedOps() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount * 4);

        vm.startPrank(alice);
        claim.approve(address(ve), amount * 4);

        // Create 4 locks with different durations.
        ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        ve.createLock(amount, 30 days, false);
        ve.createLock(amount, 180 days, false);
        ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        // Advance time partially.
        vm.warp(block.timestamp + 5 days);
        ve.checkpointTotalVe();

        // Brute-force ve sum.
        uint256 bruteSum = ve.veBalanceOf(alice);
        uint256 cached = ve.totalVeCached();
        assertGe(cached, bruteSum, "totalVeCached must be >= brute-force sum");
    }

    // ------------------------------------------------------------------
    //  F-12  createLock reverts below MIN_LOCK_AMOUNT
    // ------------------------------------------------------------------
    function testCreateLock_RevertsBelowMinAmount() public {
        vm.prank(mineCore);
        claim.mint(alice, Constants.MIN_LOCK_AMOUNT);

        vm.startPrank(alice);
        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);

        vm.expectRevert(Errors.MinLockAmountNotMet.selector);
        ve.createLock(Constants.MIN_LOCK_AMOUNT - 1, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    //  F-14  unlockExpiredForUser delegation test
    // ------------------------------------------------------------------
    function testUnlockExpiredForUser_DelegateCanUnlockExpired() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        canonicalHub.setSession(
            delegate, DelegationPermissions.P_VE_UNLOCK_EXPIRED_FOR, uint64(block.timestamp + 30 days)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        uint256 balBefore = claim.balanceOf(alice);
        vm.prank(delegate);
        ve.unlockExpiredForUser(alice, tokenId);

        assertEq(claim.balanceOf(alice), balBefore + amount, "CLAIM must go to user, not delegate");
    }

    // ==================================================================
    // ==================================================================

    // ------------------------------------------------------------------
    //  createLock reverts on duration too short
    // ------------------------------------------------------------------
    function testCreateLock_RevertsOnDurationTooShort() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);

        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(amount, Constants.MIN_LOCK_DURATION - 1, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    //  createLock reverts on duration too long
    // ------------------------------------------------------------------
    function testCreateLock_RevertsOnDurationTooLong() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);

        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(amount, Constants.MAX_LOCK_DURATION + 1, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    //  createLock reverts on zero amount
    // ------------------------------------------------------------------
    function testCreateLock_RevertsOnZeroAmount() public {
        vm.startPrank(alice);

        vm.expectRevert(Errors.AmountZero.selector);
        ve.createLock(0, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    //  addToLock reverts on zero amount
    // ------------------------------------------------------------------
    function testAddToLock_RevertsOnZeroAmount() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(furnace, amount);

        vm.startPrank(furnace);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLockFor(alice, amount, Constants.MIN_LOCK_DURATION, false);

        vm.expectRevert(Errors.AmountZero.selector);
        ve.addToLockFor(alice, tokenId, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    //  mergeLocks reverts on same tokenId
    // ------------------------------------------------------------------
    function testMergeLocks_RevertsOnSameTokenId() public {
        // v1.0.0: same-id revert lives on `_mergeLocksInternal`; reachable via the
        // Furnace-only `mergeLocksFor` sibling.
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        vm.prank(furnace);
        vm.expectRevert(Errors.NotAuthorized.selector);
        ve.mergeLocksFor(alice, tokenId, tokenId);
    }

    // ------------------------------------------------------------------
    //  totalLockedClaim tracks across lifecycle
    // ------------------------------------------------------------------
    function testTotalLockedClaim_TracksAcrossLifecycle() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount * 2);

        vm.startPrank(alice);
        claim.approve(address(ve), amount * 2);
        uint256 tokenId1 = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        assertEq(ve.totalLockedClaim(), amount, "after first lock");

        uint256 tokenId2 = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        assertEq(ve.totalLockedClaim(), amount * 2, "after second lock");
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION);

        vm.prank(alice);
        ve.unlock(tokenId1);
        assertEq(ve.totalLockedClaim(), amount, "after first unlock");

        vm.prank(alice);
        ve.unlock(tokenId2);
        assertEq(ve.totalLockedClaim(), 0, "after second unlock");
    }

    // ------------------------------------------------------------------
    //  veBalanceOf decays monotonically
    // ------------------------------------------------------------------
    function testVeBalanceOf_DecaysMonotonically() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        vm.prank(mineCore);
        claim.mint(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        ve.createLock(amount, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        uint256 prev = ve.veBalanceOf(alice);
        assertTrue(prev > 0, "initial veBalance must be > 0");

        for (uint256 i = 1; i <= 12; i++) {
            vm.warp(block.timestamp + 30 days);
            uint256 curr = ve.veBalanceOf(alice);
            assertTrue(curr <= prev, "veBalance must decay monotonically");
            prev = curr;
        }
    }
}
