// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { euint64, InEuint64 } from "cofhe-contracts/FHE.sol";

/**
 * @title IEncryptedERC20
 * @notice Minimal FHERC20 interface required by ShadeSpot contracts.
 */
interface IEncryptedERC20 {
    /// @notice Grants transfer permission to `operator` until `until`.
    function setOperator(address operator, uint48 until) external;

    /// @notice Returns true if `spender` is an active operator for `holder`.
    function isOperator(address holder, address spender) external view returns (bool);

    /// @notice Transfers encrypted balance from the caller.
    function confidentialTransfer(address to, euint64 value) external returns (euint64 transferred);

    /// @notice Transfers encrypted balance from `from` when caller is an operator.
    function confidentialTransferFrom(
        address from,
        address to,
        euint64 value
    ) external returns (euint64 transferred);
}
