// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IEncryptedERC20
 * @notice Interface for an ERC-20 token whose on-chain balances are stored as FHE
 *         ciphertexts (euint128). The transfer API remains plaintext-compatible so
 *         the Router and Vault can use standard ERC-20 call patterns; privacy comes
 *         from the fact that storage slots are ciphertexts readable only by the
 *         balance owner via the CoFHE decryption gateway.
 */
interface IEncryptedERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
