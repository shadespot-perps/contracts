// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { euint64, InEuint64 } from "cofhe-contracts/FHE.sol";

/**
 * @title IEncryptedERC20
 * @notice Subset of IFHERC20 (Fhenix confidential-contracts) that ShadeSpot Pool 2
 *         contracts depend on.
 *
 * Key differences from a standard ERC-20:
 *   - transfer / transferFrom / approve / allowance all REVERT — never call them.
 *   - Amounts are always euint64 ciphertexts; balances are encrypted on-chain.
 *   - Instead of approve, callers grant operators via setOperator(spender, untilTimestamp).
 *     FHERouter must be granted operator status by each user before trading.
 */
interface IEncryptedERC20 {
    // -------------------------------------------------------
    // Operator model (replaces approve/allowance)
    // -------------------------------------------------------

    /// @notice Grant `operator` permission to transfer on behalf of msg.sender
    ///         until `until` (unix timestamp). FHERouter address should be used.
    function setOperator(address operator, uint48 until) external;

    /// @notice Returns true if `spender` is an active operator for `holder`.
    function isOperator(address holder, address spender) external view returns (bool);

    // -------------------------------------------------------
    // Confidential transfers (used by FHEVault and FHERouter)
    // -------------------------------------------------------

    /// @notice Transfer from caller's balance. Used by FHEVault to pay out traders/LPs.
    function confidentialTransfer(address to, euint64 value) external returns (euint64 transferred);

    /// @notice Transfer on behalf of `from` (caller must be active operator).
    ///         Used by FHERouter to move user collateral into the vault.
    function confidentialTransferFrom(
        address from,
        address to,
        euint64 value
    ) external returns (euint64 transferred);
}
