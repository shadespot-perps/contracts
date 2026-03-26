// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "cofhe-contracts/FHE.sol";
import "./IEncryptedERC20.sol";

/**
 * @title MockFHEToken
 * @notice ERC-20 token whose per-address balances are stored as FHE ciphertexts
 *         (euint128). Transfer amounts are accepted as plaintext (the caller knows
 *         their own amount); the on-chain state is never readable as plaintext by
 *         observers — only the balance owner can decrypt via the CoFHE gateway.
 *
 * In Foundry tests, etch MockTaskManager at TASK_MANAGER_ADDRESS so all FHE ops
 * execute synchronously with plaintext handles.
 *
 * Allowances are stored as plaintext uint256 for simplicity (standard ERC-20
 * approve/transferFrom pattern).
 */
contract MockFHEToken is IEncryptedERC20 {

    string public name;
    string public symbol;
    uint8  public constant decimals = 18;

    // Encrypted balances — not readable on-chain without FHE gateway
    mapping(address => euint128) private _encBalances;

    // Plaintext allowances (standard ERC-20)
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    // -------------------------------------------------------
    // MINT (test / admin only — no access control for mock)
    // -------------------------------------------------------

    function mint(address to, uint256 amount) external {
        euint128 eAmount = FHE.asEuint128(amount);
        _encBalances[to] = FHE.add(_encBalances[to], eAmount);
        emit Transfer(address(0), to, amount);
    }

    // -------------------------------------------------------
    // ERC-20 INTERFACE
    // -------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _encTransfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "FHEToken: insufficient allowance");
        _allowances[from][msg.sender] = allowed - amount;
        _encTransfer(from, to, amount);
        return true;
    }

    // -------------------------------------------------------
    // INTERNAL — encrypted balance update
    // -------------------------------------------------------

    function _encTransfer(address from, address to, uint256 amount) internal {
        euint128 eAmount = FHE.asEuint128(amount);

        // Encrypted balance-sufficient check — only one bit is decrypted
        ebool hasBal = FHE.gte(_encBalances[from], eAmount);
        (bool ok, bool decOk) = FHE.getDecryptResultSafe(hasBal);
        require(decOk && ok, "FHEToken: insufficient encrypted balance");

        _encBalances[from] = FHE.sub(_encBalances[from], eAmount);
        _encBalances[to]   = FHE.add(_encBalances[to],   eAmount);

        emit Transfer(from, to, amount);
    }
}
