// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, euint64, ebool } from "cofhe-contracts/FHE.sol";

/**
 * @title EncryptedLPToken
 * @notice Encrypted LP share token for ShadeSpot.
 *
 * Balances are stored as FHE ciphertexts (euint64) — the exact number
 * of shares held by any address is never exposed on-chain.
 *
 * Access control:
 *   - Only the bound vault may mint or burn shares.
 *   - Any holder may initiate an encrypted transfer to another address.
 *
 * Transfer pattern mirrors the FHEVault withdrawal flow:
 *   1. `submitTransfer`  — encrypts the balance-sufficiency check and
 *      emits handles for Threshold Network decryption.
 *   2. `finalizeTransfer` — verifies the decrypt proof then moves shares.
 */
contract EncryptedLPToken {

    // ── Metadata ─────────────────────────────────────────────

    string public constant name     = "Shadespot LP Token";
    string public constant symbol   = "SLP";
    uint8  public constant decimals = 6;

    // ── State ────────────────────────────────────────────────

    address public immutable vault;

    euint64 public encryptedTotalSupply;
    mapping(address => euint64) public encryptedBalanceOf;

    struct PendingTransfer {
        ebool   hasBal;
        euint64 eAmount;
        address to;
    }
    mapping(address => PendingTransfer) public pendingTransfer;

    // ── Events ───────────────────────────────────────────────

    event Mint(address indexed to,   bytes32 amountHandle);
    event Burn(address indexed from, bytes32 amountHandle);

    event TransferSubmitted(
        address indexed from,
        address indexed to,
        bytes32         hasBalHandle,
        bytes32         amountHandle
    );
    event Transfer(address indexed from, address indexed to, bytes32 amountHandle);

    // ── Access control ───────────────────────────────────────

    modifier onlyVault() {
        require(msg.sender == vault, "Not vault");
        _;
    }

    // ── Constructor ──────────────────────────────────────────

    constructor(address _vault) {
        require(_vault != address(0), "Zero vault");
        vault = _vault;
    }

    // ── Vault-controlled mint / burn ─────────────────────────

    /**
     * @notice Mint encrypted LP shares to `to`.
     *         FHEVault calls this after recording a deposit.
     *         Vault must FHE.allow(eAmount, address(this)) before calling.
     */
    function mint(address to, euint64 eAmount) external onlyVault {
        encryptedBalanceOf[to] = FHE.add(encryptedBalanceOf[to], eAmount);
        encryptedTotalSupply   = FHE.add(encryptedTotalSupply,   eAmount);

        FHE.allow(encryptedBalanceOf[to], address(this));
        FHE.allow(encryptedBalanceOf[to], to);
        FHE.allow(encryptedTotalSupply,   address(this));

        emit Mint(to, euint64.unwrap(eAmount));
    }

    /**
     * @notice Burn encrypted LP shares from `from`.
     *         FHEVault calls this when finalizing a withdrawal.
     *         Vault must FHE.allow(eAmount, address(this)) before calling.
     */
    function burn(address from, euint64 eAmount) external onlyVault {
        encryptedBalanceOf[from] = FHE.sub(encryptedBalanceOf[from], eAmount);
        encryptedTotalSupply     = FHE.sub(encryptedTotalSupply,     eAmount);

        FHE.allow(encryptedBalanceOf[from], address(this));
        FHE.allow(encryptedBalanceOf[from], from);
        FHE.allow(encryptedTotalSupply,     address(this));

        emit Burn(from, euint64.unwrap(eAmount));
    }

    // ── Encrypted transfer — phase 1 ─────────────────────────

    /**
     * @notice Initiate an encrypted LP token transfer.
     *         Computes an encrypted balance check and emits handles for
     *         off-chain decryption via the Threshold Network.
     *         Caller must FHE.allow(eAmount, address(this)) before calling.
     * @param to      Recipient (non-zero).
     * @param eAmount Encrypted share amount to send.
     */
    function submitTransfer(address to, euint64 eAmount) external {
        require(to != address(0),                         "Zero address");
        require(pendingTransfer[msg.sender].to == address(0), "Transfer pending");

        ebool hasBal = FHE.gte(encryptedBalanceOf[msg.sender], eAmount);

        FHE.allow(hasBal,  address(this));
        FHE.allow(hasBal,  msg.sender);
        FHE.allow(eAmount, address(this));

        pendingTransfer[msg.sender] = PendingTransfer(hasBal, eAmount, to);

        emit TransferSubmitted(
            msg.sender,
            to,
            ebool.unwrap(hasBal),
            euint64.unwrap(eAmount)
        );
    }

    // ── Encrypted transfer — phase 2 ─────────────────────────

    /**
     * @notice Complete an encrypted LP token transfer.
     *         Verifies the Threshold Network decrypt proof for the balance
     *         check, then moves the encrypted shares.
     *         The exact share amount is never revealed on-chain.
     * @param balPlain Decrypted boolean from the Threshold Network.
     * @param balSig   Threshold Network signature for the hasBal handle.
     */
    function finalizeTransfer(bool balPlain, bytes calldata balSig) external {
        PendingTransfer storage pt = pendingTransfer[msg.sender];
        require(pt.to != address(0), "No pending transfer");

        require(FHE.verifyDecryptResult(pt.hasBal, balPlain, balSig), "Invalid decrypt proof");
        require(balPlain, "Insufficient LP balance");

        address from    = msg.sender;
        address to      = pt.to;
        euint64 eAmount = pt.eAmount;
        delete pendingTransfer[msg.sender];

        encryptedBalanceOf[from] = FHE.sub(encryptedBalanceOf[from], eAmount);
        encryptedBalanceOf[to]   = FHE.add(encryptedBalanceOf[to],   eAmount);

        FHE.allow(encryptedBalanceOf[from], address(this));
        FHE.allow(encryptedBalanceOf[from], from);
        FHE.allow(encryptedBalanceOf[to],   address(this));
        FHE.allow(encryptedBalanceOf[to],   to);

        emit Transfer(from, to, euint64.unwrap(eAmount));
    }
}
