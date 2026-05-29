// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice ClaimToken external interface (complete ABI surface).
/// @dev MUST match `src/ClaimToken.sol` for every external/public function exposed by the token.
interface IClaimToken is IERC20Metadata {
    function isRestrictedRecipient(address to) external view returns (bool);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function renounceOwnership() external;

    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;

    function mineCore() external view returns (address);
    function configFrozen() external view returns (bool);
    function setMineCore(address _mineCore) external;
    function freezeConfig() external;
}
