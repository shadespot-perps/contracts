// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./IVault.sol";
import "../tokens/IEncryptedERC20.sol";
import {FHE, euint64, ebool} from "cofhe-contracts/FHE.sol";
import {ITaskManager} from "cofhe-contracts/ICofhe.sol";

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
    // Must match the address used by cofhe-contracts' `FHE.sol` in this repo.
    address private constant TASK_MANAGER =
        0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    IEncryptedERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    address public owner;

    // Hybrid accounting — Pool depth is plaintext, LP balances are FHE ciphertexts
    uint256 public totalLiquidity;
    uint256 public totalReserved;
    mapping(address => euint64) public lpBalance;

    // Two-phase decrypt: trader → pending hasLiq ebool submitted in a prior
    // successful tx so the CoFHE dispatcher can see and process the TaskCreated event.
    mapping(address => ebool) public pendingLiqCheck;

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
        totalLiquidity += amount;

        // CoFHE ACL: persistently allow this vault to use updated stored handles.
        FHE.allow(lpBalance[msg.sender], address(this));
        emit Deposit(msg.sender, amount);
    }

    // Withdraw request storage
    mapping(address => euint64) public pendingWithdraw;
    event WithdrawRequested(
        address indexed user,
        uint256 amount,
        bytes32 hasBalHandle
    );

    /**
     * @notice Request LP withdrawal. Starts an FHE decryption process for user balance.
     */
    function withdraw(uint256 amount) external onlyRouter {
        require(
            totalLiquidity - totalReserved >= amount,
            "Liquidity locked by positions"
        );

        euint64 eAmount = FHE.asEuint64(uint64(amount));
        ebool hasBal = FHE.gte(lpBalance[msg.sender], eAmount);

        pendingWithdraw[msg.sender] = eAmount;
        FHE.allowPublic(hasBal);

        emit WithdrawRequested(msg.sender, amount, ebool.unwrap(hasBal));
    }

    /**
     * @notice Finalize LP withdrawal with off-chain Keeper proof.
     */
    function finalizeWithdraw(
        address user,
        uint256 amount,
        bool balOk,
        bytes calldata sig
    ) external {
        euint64 eAmount = pendingWithdraw[user];
        require(euint64.unwrap(eAmount) != bytes32(0), "No pending withdraw");

        ebool hasBal = FHE.gte(lpBalance[user], eAmount);
        FHE.publishDecryptResult(hasBal, balOk, sig);
        require(balOk, "Insufficient balance");

        totalLiquidity -= amount;
        lpBalance[user] = FHE.sub(lpBalance[user], eAmount);
        FHE.allow(lpBalance[user], address(this));

        FHE.allow(eAmount, address(collateralToken));
        collateralToken.confidentialTransfer(user, eAmount);

        pendingWithdraw[user] = euint64.wrap(bytes32(0));
        emit Withdraw(user, amount);
    }

    // --------------------------------------------------------
    // POSITION MANAGER FUNCTIONS (IVault)
    // --------------------------------------------------------

    function reserveLiquidity(uint256 amount) external onlyPositionManager {
        require(
            totalLiquidity - totalReserved >= amount,
            "Insufficient vault liquidity"
        );
        totalReserved += amount;
        emit IncreaseReserved(amount);
    }

    function releaseLiquidity(uint256 amount) external onlyPositionManager {
        require(totalReserved >= amount, "Invalid release");
        totalReserved -= amount;
        emit DecreaseReserved(amount);
    }

    function payTrader(
        address user,
        uint256 profit,
        uint256 returnedCollateral
    ) external onlyPositionManager {
        uint256 actualProfit = profit;

        if (profit > 0) {
            uint256 avail = totalLiquidity - totalReserved;
            actualProfit = profit > avail ? avail : profit;
            totalLiquidity -= actualProfit;
        }

        uint256 payout = actualProfit + returnedCollateral;
        euint64 ePayout = FHE.asEuint64(uint64(payout));
        FHE.allow(ePayout, address(collateralToken));
        collateralToken.confidentialTransfer(user, ePayout);

        emit PayOut(user, payout);
    }

    function receiveLoss(uint256 amount) external onlyPositionManager {
        totalLiquidity += amount;
        emit ReceiveLoss(amount);
    }

    function refundCollateral(
        address user,
        uint256 amount
    ) external onlyRouter {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        FHE.allow(eAmount, address(collateralToken));
        collateralToken.confidentialTransfer(user, eAmount);
    }
}
