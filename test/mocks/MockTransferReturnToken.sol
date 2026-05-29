// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice ERC20-like token with configurable transfer/transferFrom return data for testing.
contract MockTransferReturnToken {
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

    mapping(address owner => uint256) internal _bal;
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

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _bal[owner];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allow[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        _returnWithMode();
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= value, "MockTransferReturnToken: allowance");
        unchecked {
            _allow[from][msg.sender] = a - value;
        }

        _transfer(from, to, value);
        _returnWithMode();
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(_bal[from] >= value, "MockTransferReturnToken: balance");
        unchecked {
            _bal[from] -= value;
        }
        _bal[to] += value;
    }

    function _returnWithMode() internal view {
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
    }
}
