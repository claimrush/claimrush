// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IFurnaceRootsView_RevertBomb {
    function claim() external view returns (address);
    function ve() external view returns (address);
}

/// @notice LP rewards vault mock that reverts with a large revert-data buffer.
/// @dev Used to ensure callers do not copy unbounded revert data into memory.
contract MockLpRewardsVaultRevertBomb {
    /// @dev Mirrors LpStakingVault7D's public immutable getter so Furnace can validate wiring.
    address public furnace;

    /// @dev Size (bytes) of the revert-data buffer.
    uint256 public revertSize;

    function setFurnace(address _furnace) external {
        furnace = _furnace;
    }

    function claim() external view returns (address) {
        address f = furnace;
        if (f == address(0)) return address(0);
        return IFurnaceRootsView_RevertBomb(f).claim();
    }

    function ve() external view returns (address) {
        address f = furnace;
        if (f == address(0)) return address(0);
        return IFurnaceRootsView_RevertBomb(f).ve();
    }

    function setRevertSize(uint256 size) external {
        revertSize = size;
    }

    function notifyRewards(uint256) external view {
        uint256 size = revertSize;
        assembly {
            mstore(0x00, 1)
            revert(0x00, size)
        }
    }
}

/// @notice ShareholderRoyalties mock that can revert with a large revert-data buffer.
/// @dev Used to ensure MineCore's best-effort royalty paths cannot be griefed via revert-data bombs.
contract MockRoyaltiesRevertBomb {
    uint256 public revertSize;

    bool public revertOnTakeover = true;
    bool public revertOnFlush = true;
    bool public revertOnAddPending;

    function setRevertSize(uint256 size) external {
        revertSize = size;
    }

    function setRevertOnTakeover(bool v) external {
        revertOnTakeover = v;
    }

    function setRevertOnFlush(bool v) external {
        revertOnFlush = v;
    }

    function setRevertOnAddPending(bool v) external {
        revertOnAddPending = v;
    }

    function onTakeover(uint256) external payable {
        if (revertOnTakeover) _revertBomb();
    }

    function addPendingShareholderETH(uint256) external payable {
        if (revertOnAddPending) _revertBomb();
    }

    function flushPendingShareholderETH() external {
        if (revertOnFlush) _revertBomb();
    }

    function _revertBomb() internal view {
        uint256 size = revertSize;
        assembly {
            mstore(0x00, 1)
            revert(0x00, size)
        }
    }
}

/// @notice Furnace mock that reverts with a large revert-data buffer on enterWithClaimFor.
/// @dev Used to ensure MineCore's King auto-lock fallback cannot be griefed via revert-data bombs.
contract MockFurnaceRevertBomb {
    uint256 public revertSize;
    address public claim;
    address public ve;
    address public mineCore;
    address public shareholderRoyalties;

    function setRevertSize(uint256 size) external {
        revertSize = size;
    }

    function setWiring(address claim_, address ve_, address mineCore_, address shareholderRoyalties_) external {
        claim = claim_;
        ve = ve_;
        mineCore = mineCore_;
        shareholderRoyalties = shareholderRoyalties_;
    }

    function creditReserve(uint256) external {
        // no-op
    }

    function enterWithClaimFor(address, uint256, uint256, uint256, bool, uint256) external view returns (uint256) {
        uint256 size = revertSize;
        assembly {
            mstore(0x00, 1)
            revert(0x00, size)
        }
    }
}

/// @notice FurnaceQuoter mock that returns or reverts with a large data buffer.
/// @dev Used to ensure Furnace's quote-forwarding does not copy unbounded returndata/revertdata.
contract MockFurnaceQuoterReturnBomb {
    /// @dev Must match IFurnaceQuoter.furnace() for Furnace.setFurnaceQuoter wiring checks.
    address public furnace;

    /// @dev Size (bytes) of the return/revert data buffer.
    uint256 public dataSize;

    /// @dev If true, fallback reverts with dataSize bytes. If false, fallback returns dataSize bytes.
    bool public revertOnCall;

    function setFurnace(address _furnace) external {
        furnace = _furnace;
    }

    function setDataSize(uint256 size) external {
        dataSize = size;
    }

    function setRevertOnCall(bool v) external {
        revertOnCall = v;
    }

    function userSpotBonusBps(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function lpScaleBps(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    fallback() external {
        uint256 size = dataSize;
        bool doRevert = revertOnCall;
        assembly {
            mstore(0x00, 1)
            if doRevert { revert(0x00, size) }
            return(0x00, size)
        }
    }
}
