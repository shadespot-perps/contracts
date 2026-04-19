// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHERC20 } from "fhenix-confidential-contracts/FHERC20.sol";

/**
 * @title MockFHEToken
 * @notice Concrete FHERC20 token used as collateral in ShadeSpot (Encrypted Protocol).
 *
Extends the Fhenix confidential-contracts FHERC20 base which:
 *   - Stores per-address balances as `euint64` FHE ciphertexts.
 *   - Provides `confidentialTransfer` / `confidentialTransferFrom` instead of
 *     the standard ERC-20 transfer functions (those deliberately revert).
 *   - Uses an operator model (setOperator) securely.
 *
In Foundry tests, etch MockTaskManager at TASK_MANAGER_ADDRESS in setUp so all
 * FHE operations execute synchronously with plaintext-as-handle semantics.
 */
contract MockFHEToken is FHERC20 {

    constructor(
        string memory name_,
        string memory symbol_
    ) FHERC20(name_, symbol_, 18) {}

    // -------------------------------------------------------
    // Mint / burn — no access control (test / dev token)
    // -------------------------------------------------------

    function mint(address to, uint64 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint64 amount) external {
        _burn(from, amount);
    }
}
