// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVault.sol";
import "../tokens/IEncryptedERC20.sol";
import "cofhe-contracts/FHE.sol";

/**
 * @title FHEVault
 * @notice Pool 2 vault — collateral is an FHE-encrypted ERC-20 token.
 *
 * Privacy properties (vs standard Vault):
 *   - totalLiquidity and totalReserved are stored as euint128 ciphertexts.
 *   - LP balances (lpBalance) are stored as euint128 ciphertexts.
 *   - On-chain observers cannot read the vault's liquidity depth or any LP's share.
 *   - Only the CoFHE decryption gateway can reveal individual values to authorised
 *     parties.
 *
 * Interface compatibility:
 *   - Implements IVault so PositionManager can use it interchangeably with Vault.
 *   - deposit/withdraw accept plaintext uint256 (the amount is known to the LP;
 *     privacy is provided by the FHE token's encrypted on-chain balance storage).
 */
contract FHEVault is IVault {

    IEncryptedERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    address public owner;

    // Encrypted accounting — not readable on-chain without FHE gateway
    euint128 public totalLiquidity;
    euint128 public totalReserved;
    mapping(address => euint128) public lpBalance;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event IncreaseReserved(uint256 amount);
    event DecreaseReserved(uint256 amount);
    event PayOut(address indexed user, uint256 amount);
    event ReceiveLoss(uint256 amount);

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "Not position manager");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "Not router");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _token, address _owner) {
        collateralToken = IEncryptedERC20(_token);
        owner = _owner;
    }

    function setPositionManager(address _pm) external onlyOwner {
        require(positionManager == address(0), "Already set");
        positionManager = _pm;
    }

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "Already set");
        router = _router;
    }

    // --------------------------------------------------------
    // LP FUNCTIONS
    // --------------------------------------------------------

    /**
     * @notice Record an LP deposit. The actual token transfer must be done by the
     *         Router (collateralToken.transferFrom → vault) before calling this.
     * @param amount Plaintext amount deposited (known to the LP; stored encrypted).
     */
    function deposit(uint256 amount) external onlyRouter {
        require(amount > 0, "Invalid amount");

        euint128 eAmount = FHE.asEuint128(amount);
        lpBalance[msg.sender] = FHE.add(lpBalance[msg.sender], eAmount);
        totalLiquidity        = FHE.add(totalLiquidity, eAmount);

        emit Deposit(msg.sender, amount);
    }

    /**
     * @notice Withdraw LP liquidity. Checks both the LP's encrypted balance and
     *         the encrypted available-liquidity check, decrypting only one bit each.
     */
    function withdraw(uint256 amount) external onlyRouter {
        euint128 eAmount = FHE.asEuint128(amount);

        // Encrypted check: LP has enough balance
        ebool hasBal = FHE.gte(lpBalance[msg.sender], eAmount);
        (bool balOk, bool decBal) = FHE.getDecryptResultSafe(hasBal);
        require(decBal && balOk, "Insufficient balance");

        // Encrypted check: enough free liquidity
        euint128 eAvail = FHE.sub(totalLiquidity, totalReserved);
        ebool hasLiq = FHE.gte(eAvail, eAmount);
        (bool liqOk, bool decLiq) = FHE.getDecryptResultSafe(hasLiq);
        require(decLiq && liqOk, "Liquidity locked");

        lpBalance[msg.sender] = FHE.sub(lpBalance[msg.sender], eAmount);
        totalLiquidity        = FHE.sub(totalLiquidity, eAmount);

        collateralToken.transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // --------------------------------------------------------
    // POSITION MANAGER FUNCTIONS (IVault)
    // --------------------------------------------------------

    function reserveLiquidity(uint256 amount) external onlyPositionManager {
        euint128 eAmount = FHE.asEuint128(amount);
        euint128 eAvail  = FHE.sub(totalLiquidity, totalReserved);

        ebool hasLiq = FHE.gte(eAvail, eAmount);
        (bool ok, bool decOk) = FHE.getDecryptResultSafe(hasLiq);
        require(decOk && ok, "Insufficient vault liquidity");

        totalReserved = FHE.add(totalReserved, eAmount);

        emit IncreaseReserved(amount);
    }

    function releaseLiquidity(uint256 amount) external onlyPositionManager {
        euint128 eAmount = FHE.asEuint128(amount);

        ebool ok = FHE.gte(totalReserved, eAmount);
        (bool valid, bool decOk) = FHE.getDecryptResultSafe(ok);
        require(decOk && valid, "Invalid release");

        totalReserved = FHE.sub(totalReserved, eAmount);

        emit DecreaseReserved(amount);
    }

    function payTrader(address user, uint256 profit, uint256 returnedCollateral)
        external
        onlyPositionManager
    {
        uint256 actualProfit = profit;

        if (profit > 0) {
            euint128 eProfit = FHE.asEuint128(profit);
            euint128 eAvail  = FHE.sub(totalLiquidity, totalReserved);

            // Cap profit at available liquidity (encrypted select, decrypt result)
            euint128 eActual = FHE.select(FHE.gt(eProfit, eAvail), eAvail, eProfit);
            (uint128 decProfit, bool decOk) = FHE.getDecryptResultSafe(eActual);
            require(decOk, "decrypt not ready");

            actualProfit   = uint256(decProfit);
            totalLiquidity = FHE.sub(totalLiquidity, FHE.asEuint128(actualProfit));
        }

        uint256 payout = actualProfit + returnedCollateral;
        collateralToken.transfer(user, payout);

        emit PayOut(user, payout);
    }

    function receiveLoss(uint256 amount) external onlyPositionManager {
        totalLiquidity = FHE.add(totalLiquidity, FHE.asEuint128(amount));
        emit ReceiveLoss(amount);
    }

    function refundCollateral(address user, uint256 amount) external onlyRouter {
        collateralToken.transfer(user, amount);
    }
}
