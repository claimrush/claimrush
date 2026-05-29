// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {VeClaimNFT} from "src/VeClaimNFT.sol";

/// @notice Test harness that allows minting + pointer manipulation and exposes internal state for tests.
contract VeClaimNFTHarness is VeClaimNFT {
    constructor(address claimToken_, address initialOwner) VeClaimNFT(claimToken_, initialOwner) {}

    function mintForTest(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function globalLastTsForTest() external view returns (uint256) {
        return _globalLastTs;
    }

    function resolveShareholderRoyaltiesForTest() external view returns (address) {
        return _resolveShareholderRoyalties();
    }

    // ---------------------------------------------------------------------
    // Test-only helpers
    // ---------------------------------------------------------------------

    function createLock(uint256 amount, uint256 duration, bool autoMax)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        return _createLock(msg.sender, msg.sender, amount, duration, autoMax);
    }

    function addToLock(uint256 tokenId, uint256 amount) external nonReentrant {
        _addToLock(msg.sender, msg.sender, tokenId, amount);
    }

    function approveForTest(address to, uint256 tokenId) external {
        _approve(to, tokenId, address(0));
    }

    function setApprovalForAllForTest(address tokenOwner, address operator, bool approved) external {
        _setApprovalForAll(tokenOwner, operator, approved);
    }

    /// @dev Test-only: force the ve-level listed flag without MarketRouter auth checks.
    function setListedForTest(uint256 tokenId, bool listed) external {
        _locks[tokenId].listed = listed;
    }

    /// @dev Test-only: advance the pending-mint counter without going through the full lock path.
    function setNextTokenIdForTest(uint256 next) external {
        _nextTokenId = next;
    }
}
