// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract VeClaimNFT_MetadataTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(0)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("delegationHub()"), abi.encode(address(0)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(0)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(0)));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();
    }

    // ---- tokenURI / baseURI ----

    function test_tokenURI_emptyByDefault() public {
        ve.mintForTest(alice, 1);
        assertEq(ve.tokenURI(1), "");
    }

    function test_setBaseURI_updatesTokenURI() public {
        ve.mintForTest(alice, 42);

        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        assertEq(ve.tokenURI(42), "https://example.com/api/nft/42");
    }

    function test_baseURI_returnsCurrentValue() public {
        assertEq(ve.baseURI(), "");

        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");
        assertEq(ve.baseURI(), "https://example.com/api/nft/");
    }

    function test_setBaseURI_emitsBatchMetadataUpdate() public {
        vm.prank(owner);

        vm.expectEmit(true, true, false, true);
        emit Events.BatchMetadataUpdate(0, type(uint256).max);

        ve.setBaseURI("https://x.com/meta/");
    }

    function test_setBaseURI_emitsBaseURISet() public {
        vm.prank(owner);

        vm.expectEmit(false, false, false, true);
        emit Events.BaseURISet("", "https://x.com/meta/");

        ve.setBaseURI("https://x.com/meta/");
    }

    function test_setBaseURI_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ve.setBaseURI("https://evil.com/");
    }

    function test_setBaseURI_canBeCleared() public {
        vm.startPrank(owner);
        ve.setBaseURI("https://example.com/v1/");
        ve.setBaseURI("");
        vm.stopPrank();

        ve.mintForTest(alice, 1);
        assertEq(ve.tokenURI(1), "");
        assertEq(ve.baseURI(), "");
    }

    function test_setBaseURI_emitsOldAndNewURI() public {
        vm.startPrank(owner);
        ve.setBaseURI("https://v1.example.com/");

        vm.expectEmit(false, false, false, true);
        emit Events.BaseURISet("https://v1.example.com/", "https://v2.example.com/");
        ve.setBaseURI("https://v2.example.com/");

        vm.stopPrank();
    }

    // ---- contractURI ----

    function test_contractURI_emptyByDefault() public view {
        assertEq(ve.contractURI(), "");
    }

    function test_setContractURI_updatesContractURI() public {
        vm.prank(owner);
        ve.setContractURI("https://example.com/collection.json");
        assertEq(ve.contractURI(), "https://example.com/collection.json");
    }

    function test_setContractURI_emitsContractURISet() public {
        vm.prank(owner);

        vm.expectEmit(false, false, false, true);
        emit Events.ContractURISet("", "https://example.com/c.json");

        ve.setContractURI("https://example.com/c.json");
    }

    function test_setContractURI_emitsContractURIUpdated() public {
        vm.prank(owner);

        vm.expectEmit(false, false, false, false);
        emit Events.ContractURIUpdated();

        ve.setContractURI("https://example.com/c.json");
    }

    function test_setContractURI_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ve.setContractURI("https://evil.com/c.json");
    }

    // ---- supportsInterface (ERC-4906) ----

    function test_supportsInterface_ERC4906() public view {
        assertTrue(ve.supportsInterface(bytes4(0x49064906)));
    }

    function test_supportsInterface_ERC721() public view {
        assertTrue(ve.supportsInterface(type(IERC165).interfaceId));
        // ERC-721 interface id
        assertTrue(ve.supportsInterface(bytes4(0x80ac58cd)));
    }

    function test_supportsInterface_ERC721Metadata() public view {
        // ERC-721 Metadata interface id
        assertTrue(ve.supportsInterface(bytes4(0x5b5e139f)));
    }

    function test_supportsInterface_ERC7572() public view {
        // ERC-7572 contractURI interface id
        assertTrue(ve.supportsInterface(bytes4(0xe8a3d485)));
    }

    function test_setBaseURI_revertsOnURITooLong() public {
        bytes memory longUri = new bytes(513);
        for (uint256 i; i < 513; i++) {
            longUri[i] = "x";
        }

        vm.prank(owner);
        vm.expectRevert(Errors.URITooLong.selector);
        ve.setBaseURI(string(longUri));
    }

    function test_setContractURI_revertsOnURITooLong() public {
        bytes memory longUri = new bytes(513);
        for (uint256 i; i < 513; i++) {
            longUri[i] = "x";
        }

        vm.prank(owner);
        vm.expectRevert(Errors.URITooLong.selector);
        ve.setContractURI(string(longUri));
    }

    function test_setBaseURI_acceptsExactly512Bytes() public {
        bytes memory uri = new bytes(512);
        for (uint256 i; i < 512; i++) {
            uri[i] = "x";
        }

        vm.prank(owner);
        ve.setBaseURI(string(uri));
        assertEq(bytes(ve.baseURI()).length, 512);
    }

    function test_supportsInterface_returnsFalseForRandom() public view {
        assertFalse(ve.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ---- pending-mint tokenURI window ----

    function test_tokenURI_pendingWindow_nextTokenId_returnsPlaceholder() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        // _nextTokenId defaults to 1, window is [1, 5). Token 1 is unminted.
        assertEq(ve.tokenURI(1), "https://example.com/api/nft/1");
    }

    function test_tokenURI_pendingWindow_upperBoundary_returnsPlaceholder() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        // Window [1, 5): id 4 is the last id in the window.
        assertEq(ve.tokenURI(4), "https://example.com/api/nft/4");
    }

    function test_tokenURI_pendingWindow_outsideWindow_reverts() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        // Window [1, 5): id 5 is the first id outside the window.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5));
        ve.tokenURI(5);
    }

    function test_tokenURI_pendingWindow_farFuture_reverts() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1_000_000));
        ve.tokenURI(1_000_000);
    }

    function test_tokenURI_pendingWindow_belowNextTokenId_reverts() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        // Advance next to 10, so ids 10..13 are in window; id 5 is "never-minted gap".
        ve.setNextTokenIdForTest(10);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5));
        ve.tokenURI(5);
    }

    function test_tokenURI_pendingWindow_shiftsWithNextTokenId() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        ve.setNextTokenIdForTest(100);

        assertEq(ve.tokenURI(100), "https://example.com/api/nft/100");
        assertEq(ve.tokenURI(103), "https://example.com/api/nft/103");

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 104));
        ve.tokenURI(104);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        ve.tokenURI(99);
    }

    function test_tokenURI_pendingWindow_mintedTokenPrefersMintedBranch() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        // _nextTokenId is still 1, but we mint id 3 directly via harness.
        ve.mintForTest(alice, 3);

        // id 3 is minted → super.tokenURI(3) → baseURI + "3".
        assertEq(ve.tokenURI(3), "https://example.com/api/nft/3");

        // Neighbors in the window are unminted → placeholder branch.
        assertEq(ve.tokenURI(1), "https://example.com/api/nft/1");
        assertEq(ve.tokenURI(2), "https://example.com/api/nft/2");
        assertEq(ve.tokenURI(4), "https://example.com/api/nft/4");

        // Outside window.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5));
        ve.tokenURI(5);
    }

    function test_tokenURI_pendingWindow_emptyBaseURI_returnsEmptyString() public {
        // baseURI is empty by default.
        assertEq(ve.tokenURI(1), "");
        assertEq(ve.tokenURI(4), "");

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5));
        ve.tokenURI(5);
    }

    function test_tokenURI_pendingWindow_bytesToStringCorrectness() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        ve.setNextTokenIdForTest(42);

        // Verify Strings.toString handles multi-digit correctly.
        assertEq(ve.tokenURI(42), "https://example.com/api/nft/42");
        assertEq(ve.tokenURI(45), "https://example.com/api/nft/45");
    }

    function test_tokenURI_burnedToken_fallsThroughToSuper_reverts() public {
        vm.prank(owner);
        ve.setBaseURI("https://example.com/api/nft/");

        // Advance nextTokenId past the burned id so it's not in pending window.
        ve.setNextTokenIdForTest(100);

        // id 50 was never minted and is below nextTokenId; treat as burned/nonexistent.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 50));
        ve.tokenURI(50);
    }

    // ---- optional metadata freeze ----

    function test_metadataFrozen_defaultFalse() public view {
        assertFalse(ve.metadataFrozen());
    }

    function test_freezeMetadata_setsFlag_andEmits() public {
        vm.expectEmit(false, false, false, true, address(ve));
        emit Events.MetadataFrozen();

        vm.prank(owner);
        ve.freezeMetadata();

        assertTrue(ve.metadataFrozen());
    }

    function test_freezeMetadata_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ve.freezeMetadata();
    }

    function test_freezeMetadata_revertsIfAlreadyFrozen() public {
        vm.prank(owner);
        ve.freezeMetadata();

        vm.prank(owner);
        vm.expectRevert(Errors.MetadataFrozen.selector);
        ve.freezeMetadata();
    }

    function test_setBaseURI_revertsWhenMetadataFrozen() public {
        // Set a baseURI pre-freeze so we can verify it's preserved.
        vm.prank(owner);
        ve.setBaseURI("https://frozen.example.com/");

        vm.prank(owner);
        ve.freezeMetadata();

        vm.prank(owner);
        vm.expectRevert(Errors.MetadataFrozen.selector);
        ve.setBaseURI("https://postfreeze.example.com/");

        // Storage unchanged.
        assertEq(ve.baseURI(), "https://frozen.example.com/");
    }

    function test_setContractURI_revertsWhenMetadataFrozen() public {
        vm.prank(owner);
        ve.setContractURI("ipfs://bafy.../collection.json");

        vm.prank(owner);
        ve.freezeMetadata();

        vm.prank(owner);
        vm.expectRevert(Errors.MetadataFrozen.selector);
        ve.setContractURI("ipfs://evil.../collection.json");

        assertEq(ve.contractURI(), "ipfs://bafy.../collection.json");
    }

    function test_metadataFreeze_independentOfConfigFreeze() public {
        // configFrozen requires furnace + mineMarket set, which setUp already wires.
        // Verify metadata mutable both before and after configFreeze until freezeMetadata() is called.
        vm.prank(owner);
        ve.freezeConfig();
        assertTrue(ve.configFrozen());
        assertFalse(ve.metadataFrozen());

        vm.prank(owner);
        ve.setBaseURI("https://post-configfreeze.example.com/");
        assertEq(ve.baseURI(), "https://post-configfreeze.example.com/");

        vm.prank(owner);
        ve.freezeMetadata();

        vm.prank(owner);
        vm.expectRevert(Errors.MetadataFrozen.selector);
        ve.setBaseURI("https://blocked.example.com/");
    }

    function test_freezeMetadata_preservesReadSurface() public {
        vm.prank(owner);
        ve.setBaseURI("https://keep.example.com/");
        vm.prank(owner);
        ve.setContractURI("https://keep.example.com/collection.json");

        vm.prank(owner);
        ve.freezeMetadata();

        // Reads still work; tokenURI(unminted in window) still returns placeholder.
        assertEq(ve.baseURI(), "https://keep.example.com/");
        assertEq(ve.contractURI(), "https://keep.example.com/collection.json");
        assertEq(ve.tokenURI(1), "https://keep.example.com/1");
    }
}
