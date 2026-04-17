// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./IVault.sol";
import "../tokens/IEncryptedERC20.sol";
import { FHE, euint64, ebool } from "cofhe-contracts/FHE.sol";
import {ITaskManager} from "cofhe-contracts/ICofhe.sol";

/**
 * @title FHEVault
 * @notice Pool 2 vault — collateral is a Fhenix FHERC20 token (euint64 encrypted balances).
 *
 * Privacy properties:
 *   - totalLiquidity, totalReserved, encryptedTotalSupply and every LP balance
 *     are stored as euint64 ciphertexts — pool depth, open interest, and all
 *     LP share holdings are unreadable on-chain.
 *
 * Yield distribution (mirrors Vault proportional-share model, fully in FHE):
 *   - deposit:  shares = (amount * encryptedTotalSupply) / totalLiquidity
 *   - withdraw: amount = (shares * totalLiquidity) / encryptedTotalSupply
 *   - As traders lose (receiveLoss grows totalLiquidity), each share redeems
 *     for more collateral — identical economics to Vault but with encrypted state.
 *
 * NOTE on overflow: FHE.mul operates on euint64 (max ~1.8 × 10^19).
 *   The product (amount × totalSupply) or (shares × totalLiquidity) must not
 *   exceed this bound. Use tokens with ≤ 6 decimals or enforce deposit caps.
 *
 * Two-phase pattern:
 *   - openPosition:  submitReserveLiquidityCheck → reserveLiquidity
 *   - removeLiquidity: submitWithdrawCheck → withdraw
 *   Both phases commit a CoFHE decrypt task so the dispatcher can process it
 *   before the state-changing call is made.
 *
 * Operator setup (done once per user, off-chain before first trade):
 *   fheToken.setOperator(address(fheRouter), untilTimestamp)
 */
contract FHEVault is IVault {
    address public immutable TASK_MANAGER;

    IEncryptedERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    address public owner;

    euint64 public totalLiquidity;
    euint64 public totalReserved;

    // Encrypted LP share accounting
    euint64 public encryptedTotalSupply;
    mapping(address => euint64) public lpBalance;

    // Plaintext sentinel — only reveals that the first deposit occurred (amount stays hidden)
    bool public initialized;

    // Two-phase: open position
    mapping(address => ebool) public pendingLiqCheck;

    // Two-phase: withdraw
    struct PendingWithdraw {
        ebool   hasBal;
        ebool   hasLiq;
        euint64 eAmount;
        uint256 shares;
    }
    mapping(address => PendingWithdraw) public pendingWithdraw;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 shares);
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

    constructor(address _token, address _owner, address _taskManager) {
        require(_taskManager != address(0), "invalid task manager");
        collateralToken = IEncryptedERC20(_token);
        owner = _owner;
        TASK_MANAGER = _taskManager;
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
     * @notice Record an LP deposit with proportional share issuance (fully encrypted).
     *         The Router must call confidentialTransferFrom(lp, vault, eAmount) BEFORE
     *         calling this so tokens are already in the vault.
     * @param amount Plaintext deposit amount (LP knows their own amount).
     */
    function deposit(address lp, uint256 amount) external onlyRouter {
        require(amount > 0, "Invalid amount");
        require(amount <= type(uint64).max, "amount exceeds uint64 max");
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        euint64 shares;

        if (!initialized) {
            // First deposit: 1:1 to avoid division by zero on encryptedTotalSupply
            shares = eAmount;
            initialized = true;
        } else {
            // shares = (amount * encryptedTotalSupply) / totalLiquidity
            shares = FHE.div(FHE.mul(eAmount, encryptedTotalSupply), totalLiquidity);
        }

        lpBalance[lp]        = FHE.add(lpBalance[lp], shares);
        encryptedTotalSupply  = FHE.add(encryptedTotalSupply, shares);
        totalLiquidity        = FHE.add(totalLiquidity, eAmount);

        FHE.allow(lpBalance[lp],       address(this));
        FHE.allow(encryptedTotalSupply, address(this));
        FHE.allow(totalLiquidity,       address(this));

        emit Deposit(lp, amount);
    }

    /**
     * @notice Phase 1 of withdraw: compute the encrypted share-to-token ratio and
     *         submit decrypt tasks for the balance and liquidity checks.
     *         Wait for the CoFHE dispatcher (~15–30 s) then call withdraw.
     * @param lp     LP address.
     * @param shares Plaintext share amount to redeem.
     */
    function submitWithdrawCheck(address lp, uint256 shares) external onlyRouter {
        require(shares > 0, "Invalid shares");
        euint64 eShares = FHE.asEuint64(uint64(shares));

        // Encrypted balance check
        ebool hasBal = FHE.gte(lpBalance[lp], eShares);

        // amount = (shares * totalLiquidity) / encryptedTotalSupply
        euint64 eAmount = FHE.div(FHE.mul(eShares, totalLiquidity), encryptedTotalSupply);

        // Encrypted liquidity check
        euint64 eAvail = FHE.sub(totalLiquidity, totalReserved);
        ebool   hasLiq = FHE.gte(eAvail, eAmount);

        FHE.allow(hasBal,   address(this));
        FHE.allow(eAmount,  address(this));
        FHE.allow(hasLiq,   address(this));

        pendingWithdraw[lp] = PendingWithdraw(hasBal, hasLiq, eAmount, shares);

        ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(hasBal)), address(this));
        ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(hasLiq)), address(this));
    }

    /**
     * @notice Phase 2 of withdraw: execute using pre-submitted decrypt results.
     *         Payout amount is transferred as an encrypted euint64 — the exact
     *         amount is never exposed on-chain.
     * @param lp     LP redeeming shares.
     * @param shares Must match the value submitted in submitWithdrawCheck.
     */
    // Returns 0 — payout amount is encrypted and never exposed as plaintext in this vault.
    function withdraw(address lp, uint256 shares) external onlyRouter returns (uint256) {
        PendingWithdraw storage pw = pendingWithdraw[lp];
        require(pw.shares == shares && pw.shares > 0, "No pending withdraw or shares mismatch");

        (bool balOk, bool decBal) = FHE.getDecryptResultSafe(pw.hasBal);
        if (!decBal) {
            ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(pw.hasBal)), lp);
            revert("decrypt not ready");
        }
        require(balOk, "Insufficient shares");

        (bool liqOk, bool decLiq) = FHE.getDecryptResultSafe(pw.hasLiq);
        if (!decLiq) {
            ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(pw.hasLiq)), lp);
            revert("decrypt not ready");
        }
        require(liqOk, "Liquidity locked");

        euint64 eAmount = pw.eAmount;
        euint64 eShares = FHE.asEuint64(uint64(shares));
        delete pendingWithdraw[lp];

        lpBalance[lp]        = FHE.sub(lpBalance[lp], eShares);
        encryptedTotalSupply  = FHE.sub(encryptedTotalSupply, eShares);
        totalLiquidity        = FHE.sub(totalLiquidity, eAmount);

        FHE.allow(lpBalance[lp],       address(this));
        FHE.allow(encryptedTotalSupply, address(this));
        FHE.allow(totalLiquidity,       address(this));
        FHE.allow(eAmount,              address(collateralToken));

        collateralToken.confidentialTransfer(lp, eAmount);

        emit Withdraw(lp, shares);
        return 0; // payout amount is encrypted; plaintext not available in this vault
    }

    // --------------------------------------------------------
    // POSITION MANAGER FUNCTIONS (IVault)
    // --------------------------------------------------------

    function submitReserveLiquidityCheck(address trader, uint256 amount) external onlyRouter {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        euint64 eAvail  = FHE.sub(totalLiquidity, totalReserved);
        ebool hasLiq    = FHE.gte(eAvail, eAmount);
        FHE.allow(hasLiq, address(this));
        pendingLiqCheck[trader] = hasLiq;
        ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(hasLiq)), address(this));
    }

    function reserveLiquidity(uint256 amount, address trader) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        ebool hasLiq;

        ebool pending = pendingLiqCheck[trader];
        if (ebool.unwrap(pending) != bytes32(0)) {
            hasLiq = pending;
            pendingLiqCheck[trader] = ebool.wrap(bytes32(0));
        } else {
            euint64 eAvail = FHE.sub(totalLiquidity, totalReserved);
            hasLiq = FHE.gte(eAvail, eAmount);
            FHE.allowTransient(hasLiq, address(this));
        }

        (bool ok, bool decOk) = FHE.getDecryptResultSafe(hasLiq);
        if (!decOk) {
            ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(hasLiq)), address(this));
            revert("decrypt not ready");
        }
        require(ok, "Insufficient vault liquidity");

        totalReserved = FHE.add(totalReserved, eAmount);
        FHE.allow(totalReserved, address(this));
        emit IncreaseReserved(amount);
    }

    function releaseLiquidity(uint256 amount) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));

        ebool ok = FHE.gte(totalReserved, eAmount);
        FHE.allowTransient(ok, address(this));
        (bool valid, bool decOk) = FHE.getDecryptResultSafe(ok);
        if (!decOk) {
            ITaskManager(TASK_MANAGER).createDecryptTask(uint256(ebool.unwrap(ok)), msg.sender);
            revert("decrypt not ready");
        }
        require(valid, "Invalid release");

        totalReserved = FHE.sub(totalReserved, eAmount);
        FHE.allow(totalReserved, address(this));
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

            euint64 eActual = FHE.select(FHE.gt(eProfit, eAvail), eAvail, eProfit);
            FHE.allowTransient(eActual, address(this));
            (uint64 decProfit, bool decOk) = FHE.getDecryptResultSafe(eActual);
            if (!decOk) {
                ITaskManager(TASK_MANAGER).createDecryptTask(uint256(euint64.unwrap(eActual)), user);
                revert("decrypt not ready");
            }

            actualProfit   = uint256(decProfit);
            totalLiquidity = FHE.sub(totalLiquidity, FHE.asEuint64(uint64(actualProfit)));
            FHE.allow(totalLiquidity, address(this));
        }
        if (returnedCollateral > 0) {
            totalLiquidity = FHE.sub(totalLiquidity, FHE.asEuint64(uint64(returnedCollateral)));
            FHE.allow(totalLiquidity, address(this));
        }

        uint256 payout  = actualProfit + returnedCollateral;
        euint64 ePayout = FHE.asEuint64(uint64(payout));
        FHE.allow(ePayout, address(collateralToken));
        collateralToken.confidentialTransfer(user, ePayout);

        emit PayOut(user, payout);
    }

    function receiveLoss(uint256 amount) external onlyPositionManager {
        totalLiquidity = FHE.add(totalLiquidity, FHE.asEuint64(uint64(amount)));
        FHE.allow(totalLiquidity, address(this));
        emit ReceiveLoss(amount);
    }

    function refundCollateral(address user, uint256 amount) external onlyRouter {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        FHE.allow(eAmount, address(collateralToken));
        collateralToken.confidentialTransfer(user, eAmount);
    }
}
