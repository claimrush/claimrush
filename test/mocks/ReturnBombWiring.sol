// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Returns an ABI-encoded address, but with an oversized returndata buffer.
/// @dev Used to test that callers do not copy full returndata into memory.
contract ReturnBombShareholderRoyalties {
    address public immutable sr;
    uint256 public immutable retSize;

    constructor(address sr_, uint256 retSize_) {
        sr = sr_;
        retSize = retSize_;
    }

    function shareholderRoyalties() external view returns (address) {
        address _sr = sr;
        uint256 size = retSize;
        assembly {
            mstore(0x00, _sr)
            return(0x00, size)
        }
    }
}

/// @notice Reverts with a very large revert-data buffer.
contract RevertBombShareholderRoyalties {
    uint256 public immutable revertSize;

    constructor(uint256 revertSize_) {
        revertSize = revertSize_;
    }

    function shareholderRoyalties() external view returns (address) {
        uint256 size = revertSize;
        assembly {
            // First word is nonzero to make it "look" like an address if copied.
            mstore(0x00, 1)
            revert(0x00, size)
        }
    }
}

/// @notice Minimal MarketRouter-like royalties getter.
/// @dev Uses a public immutable so Solidity autogenerates `royalties()`.
contract MockMarketRouterRoyalties {
    address public immutable royalties;

    constructor(address royalties_) {
        royalties = royalties_;
    }
}
