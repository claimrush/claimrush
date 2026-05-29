// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice ERC20-like token that can "return bomb" on view functions (balanceOf/allowance).
/// @dev Used to test that callers do not copy full returndata into memory when reading ERC20 views.
contract MockViewReturnToken {
    enum Mode {
        ReturnNormal32,
        ReturnLarge,
        RevertLarge,
        ReturnShort1
    }

    Mode public balanceMode;
    Mode public allowanceMode;
    Mode public decimalsMode;
    uint256 public returnSize;
    uint256 public decimalsValue;

    mapping(address owner => uint256) internal _bal;
    mapping(address owner => mapping(address spender => uint256)) internal _allow;

    constructor() {
        balanceMode = Mode.ReturnNormal32;
        allowanceMode = Mode.ReturnNormal32;
        decimalsMode = Mode.ReturnNormal32;
        returnSize = 4096;
        decimalsValue = 18;
    }

    function setBalanceMode(Mode m) external {
        balanceMode = m;
    }

    function setAllowanceMode(Mode m) external {
        allowanceMode = m;
    }

    function setDecimalsMode(Mode m) external {
        decimalsMode = m;
    }

    function setReturnSize(uint256 s) external {
        returnSize = s;
    }

    function setDecimalsValue(uint256 v) external {
        decimalsValue = v;
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
    }

    function balanceOf(address owner) external view returns (uint256) {
        uint256 v = _bal[owner];
        Mode m = balanceMode;
        uint256 s = returnSize;
        assembly {
            mstore(0x00, v)
            switch m
            case 0 { return(0x00, 0x20) }
            case 1 { return(0x00, s) }
            case 2 { revert(0x00, s) }
            case 3 { return(0x1f, 0x01) }
        }
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        uint256 v = _allow[owner][spender];
        Mode m = allowanceMode;
        uint256 s = returnSize;
        assembly {
            mstore(0x00, v)
            switch m
            case 0 { return(0x00, 0x20) }
            case 1 { return(0x00, s) }
            case 2 { revert(0x00, s) }
            case 3 { return(0x1f, 0x01) }
        }
    }

    function decimals() external view returns (uint256) {
        uint256 v = decimalsValue;
        Mode m = decimalsMode;
        uint256 s = returnSize;
        assembly {
            mstore(0x00, v)
            switch m
            case 0 { return(0x00, 0x20) }
            case 1 { return(0x00, s) }
            case 2 { revert(0x00, s) }
            case 3 { return(0x1f, 0x01) }
        }
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allow[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= value, "MockViewReturnToken: allowance");
        unchecked {
            _allow[from][msg.sender] = a - value;
        }

        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(_bal[from] >= value, "MockViewReturnToken: balance");
        unchecked {
            _bal[from] -= value;
        }
        _bal[to] += value;
    }
}
