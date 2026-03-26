// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./IVault.sol";
import "../tokens/IEncryptedERC20.sol";
import { FHE, euint64, ebool } from "cofhe-contracts/FHE.sol";

/**
 * @title FHEVault
 * @notice Pool 2 vault — collateral is a Fhenix FHERC20 token (euint64 encrypted balances).
 *
 * Privacy properties:
 *   - totalLiquidity and totalReserved are stored as euint64 ciphertexts.
 *   - LP balances (lpBalance) are stored as euint64 ciphertexts.
 *   - On-chain observers cannot read pool depth or any LP's share.
 *
 * Token interface:
 *   - Uses FHERC20's confidentialTransfer / confidentialTransferFrom.
 *   - Standard transfer / transferFrom / approve on FHERC20 deliberately revert —
 *     this vault never calls those.
 *   - Payouts to traders and LPs go via confidentialTransfer (vault is msg.sender,
 *     so it is always authorised to spend its own balance).
 *
 * Operator setup (done once per user, off-chain before first trade):
 *   fheToken.setOperator(address(fheRouter), untilTimestamp)
 *
 * Implements IVault so PositionManager can use it interchangeably with Vault.
 */
contract FHEVault is IVault {

    IEncryptedERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    address public owner;

    // Encrypted accounting — ciphertext handles, not readable on-chain
    euint64 public totalLiquidity;
    euint64 public totalReserved;
    mapping(address => euint64) public lpBalance;

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
     * @notice Record an LP deposit. The Router must call
     *         fheToken.confidentialTransferFrom(lp, vault, eAmount) BEFORE
     *         calling this — so tokens are already in the vault.
     * @param amount Plaintext deposit amount (LP knows their own amount).
     */
    function deposit(uint256 amount) external onlyRouter {
        require(amount > 0, "Invalid amount");
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        lpBalance[msg.sender] = FHE.add(lpBalance[msg.sender], eAmount);
        totalLiquidity        = FHE.add(totalLiquidity, eAmount);
        emit Deposit(msg.sender, amount);
    }

    /**
     * @notice Withdraw LP liquidity. Performs encrypted balance checks,
     *         decrypting only one bit each, then pays via confidentialTransfer.
     */
    function withdraw(uint256 amount) external onlyRouter {
        euint64 eAmount = FHE.asEuint64(uint64(amount));

        // Encrypted check: LP has enough balance
        ebool hasBal = FHE.gte(lpBalance[msg.sender], eAmount);
        (bool balOk, bool decBal) = FHE.getDecryptResultSafe(hasBal);
        require(decBal && balOk, "Insufficient balance");

        // Encrypted check: enough free liquidity
        euint64 eAvail = FHE.sub(totalLiquidity, totalReserved);
        ebool hasLiq = FHE.gte(eAvail, eAmount);
        (bool liqOk, bool decLiq) = FHE.getDecryptResultSafe(hasLiq);
        require(decLiq && liqOk, "Liquidity locked");

        lpBalance[msg.sender] = FHE.sub(lpBalance[msg.sender], eAmount);
        totalLiquidity        = FHE.sub(totalLiquidity, eAmount);

        // Vault is msg.sender on the token — always authorised to spend its balance
        FHE.allow(eAmount, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, eAmount);

        emit Withdraw(msg.sender, amount);
    }

    // --------------------------------------------------------
    // POSITION MANAGER FUNCTIONS (IVault)
    // --------------------------------------------------------

    function reserveLiquidity(uint256 amount) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        euint64 eAvail  = FHE.sub(totalLiquidity, totalReserved);

        ebool hasLiq = FHE.gte(eAvail, eAmount);
        (bool ok, bool decOk) = FHE.getDecryptResultSafe(hasLiq);
        require(decOk && ok, "Insufficient vault liquidity");

        totalReserved = FHE.add(totalReserved, eAmount);
        emit IncreaseReserved(amount);
    }

    function releaseLiquidity(uint256 amount) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));

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
            euint64 eProfit = FHE.asEuint64(uint64(profit));
            euint64 eAvail  = FHE.sub(totalLiquidity, totalReserved);

            // Cap profit at available liquidity (encrypted select, then decrypt result)
            euint64 eActual = FHE.select(FHE.gt(eProfit, eAvail), eAvail, eProfit);
            (uint64 decProfit, bool decOk) = FHE.getDecryptResultSafe(eActual);
            require(decOk, "decrypt not ready");

            actualProfit   = uint256(decProfit);
            totalLiquidity = FHE.sub(totalLiquidity, FHE.asEuint64(uint64(actualProfit)));
        }

        uint256 payout = actualProfit + returnedCollateral;
        euint64 ePayout = FHE.asEuint64(uint64(payout));
        FHE.allow(ePayout, address(collateralToken));
        collateralToken.confidentialTransfer(user, ePayout);

        emit PayOut(user, payout);
    }

    function receiveLoss(uint256 amount) external onlyPositionManager {
        totalLiquidity = FHE.add(totalLiquidity, FHE.asEuint64(uint64(amount)));
        emit ReceiveLoss(amount);
    }

    function refundCollateral(address user, uint256 amount) external onlyRouter {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        FHE.allow(eAmount, address(collateralToken));
        collateralToken.confidentialTransfer(user, eAmount);
    }
}
