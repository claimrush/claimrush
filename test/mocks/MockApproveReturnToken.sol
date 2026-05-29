// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice ERC20-like token with configurable approve() return data for testing.
contract MockApproveReturnToken {
    enum Mode {
        ReturnNone,
        ReturnTrue32,
        ReturnFalse32,
        ReturnShort1,
        ReturnExtra64True,
        ReturnExtra64False,
        ReturnLargeTrue,
        RevertLarge
    }

    Mode public mode;
    uint256 public returnSize;

    mapping(address owner => mapping(address spender => uint256)) internal _allow;

    constructor() {
        mode = Mode.ReturnTrue32;
        returnSize = 4096;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReturnSize(uint256 s) external {
        // Keep this bounded in tests to avoid excessive memory expansion.
        returnSize = s;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allow[msg.sender][spender] = value;

        Mode m = mode;
        if (m == Mode.ReturnNone) {
            assembly {
                return(0x00, 0x00)
            }
        }
        if (m == Mode.ReturnTrue32) {
            assembly {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
        }
        if (m == Mode.ReturnFalse32) {
            assembly {
                mstore(0x00, 0)
                return(0x00, 0x20)
            }
        }
        if (m == Mode.ReturnShort1) {
            // Return a single byte (0x01) instead of a full ABI word.
            assembly {
                mstore(0x00, 1)
                return(0x1f, 0x01)
            }
        }
        if (m == Mode.ReturnExtra64True) {
            assembly {
                mstore(0x00, 1)
                mstore(0x20, 0)
                return(0x00, 0x40)
            }
        }
        if (m == Mode.ReturnExtra64False) {
            assembly {
                mstore(0x00, 0)
                mstore(0x20, 0)
                return(0x00, 0x40)
            }
        }
        if (m == Mode.ReturnLargeTrue) {
            uint256 s = returnSize;
            assembly {
                mstore(0x00, 1)
                return(0x00, s)
            }
        }
        if (m == Mode.RevertLarge) {
            uint256 s = returnSize;
            assembly {
                mstore(0x00, 0)
                revert(0x00, s)
            }
        }

        return true;
    }
}
