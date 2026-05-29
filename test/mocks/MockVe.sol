// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Constants} from "src/lib/Constants.sol";

/// @notice Minimal veCLAIM mock (only veBalanceOf is required for ShareholderRoyalties views).
contract MockVe {
    mapping(address => uint256) public veBalance;

    // Minimal ERC721-like ownership + lock info for ShareholderRoyalties auto-compound.
    struct LockInfo {
        uint256 amount;
        uint256 lockEnd;
        bool autoMax;
        bool listed;
    }

    mapping(uint256 => address) internal _ownerOf;
    mapping(uint256 => LockInfo) internal _lockInfo;

    // Optional cached aggregates to satisfy protocol dependencies.
    uint256 public totalVeCached;
    uint256 public totalLockedClaim;
    address public claimToken;
    address public furnace;
    address public mineMarket;

    // Global checkpoint timestamp (used by MineCore gas-guarded loops).
    uint256 public globalLastTs;
    bool public checkpointAdvances = true;

    function setVeBalance(address user, uint256 amount) external {
        veBalance[user] = amount;
    }

    function setOwner(uint256 tokenId, address owner) external {
        _ownerOf[tokenId] = owner;
    }

    function setLockInfo(uint256 tokenId, uint256 amount, uint256 lockEnd, bool autoMax, bool listed) external {
        _lockInfo[tokenId] = LockInfo(amount, lockEnd, autoMax, listed);
    }

    function setTotalVeCached(uint256 v) external {
        totalVeCached = v;
    }

    function setTotalLockedClaim(uint256 v) external {
        totalLockedClaim = v;
    }

    function setClaimToken(address t) external {
        claimToken = t;
    }

    function setFurnace(address f) external {
        furnace = f;
    }

    function setMineMarket(address m) external {
        mineMarket = m;
    }

    function setGlobalLastTs(uint256 ts) external {
        globalLastTs = ts;
    }

    function setCheckpointAdvances(bool v) external {
        checkpointAdvances = v;
    }

    // No-op checkpointing hooks used by MineCore.
    function checkpointGlobalState() external {
        if (checkpointAdvances) globalLastTs = block.timestamp;
    }

    function checkpointTotalVe() external {
        if (checkpointAdvances) globalLastTs = block.timestamp;
    }

    function veBalanceOf(address user) external view returns (uint256) {
        return veBalance[user];
    }

    function totalVeBiasScaled() external view returns (uint256) {
        return totalVeCached * 1e18;
    }

    struct CustomLockParams {
        uint256[] amounts;
        uint256[] lockEnds;
        bool[] autoMaxFlags;
    }

    mapping(address => bool) internal _hasCustomLockParams;
    mapping(address => CustomLockParams) internal _customLockParams;

    function setShareholderLockParams(
        address user,
        uint256[] memory amounts,
        uint256[] memory lockEnds,
        bool[] memory autoMaxFlags
    ) external {
        require(amounts.length == lockEnds.length && amounts.length == autoMaxFlags.length, "MockVe: length mismatch");
        _hasCustomLockParams[user] = true;
        _customLockParams[user].amounts = amounts;
        _customLockParams[user].lockEnds = lockEnds;
        _customLockParams[user].autoMaxFlags = autoMaxFlags;
    }

    function clearShareholderLockParams(address user) external {
        _hasCustomLockParams[user] = false;
    }

    function getShareholderLockParams(address user)
        external
        view
        returns (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags)
    {
        if (_hasCustomLockParams[user]) {
            return
                (
                    _customLockParams[user].amounts,
                    _customLockParams[user].lockEnds,
                    _customLockParams[user].autoMaxFlags
                );
        }

        uint256 bal = veBalance[user];
        if (bal == 0) {
            return (new uint256[](0), new uint256[](0), new bool[](0));
        }

        amounts = new uint256[](1);
        lockEnds = new uint256[](1);
        autoMaxFlags = new bool[](1);

        // Synthetic perpetual lock so ShareholderRoyalties tests that manually set veBalance
        // keep their previous constant-balance semantics.
        amounts[0] = bal;
        lockEnds[0] = type(uint256).max;
        autoMaxFlags[0] = true;
    }

    // ------------------------------------------------------------
    // Minimal veNFT surfaces (used by ShareholderRoyalties)
    // ------------------------------------------------------------

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "ERC721: invalid token ID");
        return o;
    }

    function getLockInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint256 lockEnd, bool autoMax, bool listed)
    {
        LockInfo storage li = _lockInfo[tokenId];

        // Mirror VeClaimNFT AutoMax semantics: autoMax locks are treated as if they are
        // continuously extended to the maximum duration.
        uint256 effectiveEnd = li.lockEnd;
        if (li.autoMax && li.amount != 0) {
            effectiveEnd = block.timestamp + Constants.MAX_LOCK_DURATION;
        }

        return (li.amount, effectiveEnd, li.autoMax, li.listed);
    }
}
