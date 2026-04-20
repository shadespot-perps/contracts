// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./IVault.sol";
import "../tokens/IEncryptedERC20.sol";
import { FHE, euint64, euint128, ebool } from "cofhe-contracts/FHE.sol";

/**
 * @title FHEVault
 * @notice Encrypted collateral vault for liquidity, reservation, and settlement.
 */
contract FHEVault is IVault {

    IEncryptedERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    address public owner;

    euint64 public totalLiquidity;
    euint64 public totalReserved;

    euint64 public encryptedTotalSupply;
    mapping(address => euint64) public lpBalance;

    bool public initialized;

    struct PendingLiqCheck {
        ebool   hasLiq;
        euint64 eSize;
    }
    mapping(address => PendingLiqCheck) public pendingLiqCheck;

    mapping(address => bool)    private _liqApproved;
    mapping(address => euint64) private _liqApprovedSize;

    struct PendingWithdraw {
        ebool   hasBal;
        ebool   hasLiq;
        euint64 eAmount;
        uint256 shares;
    }
    mapping(address => PendingWithdraw) public pendingWithdraw;

    event Deposit(address indexed user, bytes32 amountHandle);
    event Withdraw(address indexed user, bytes32 amountHandle);

    event IncreaseReserved(bytes32 sizeHandle);
    event DecreaseReserved(uint256 amount);

    event PayOut(address indexed user, bytes32 payoutHandle);
    event ReceiveLoss(bytes32 amountHandle);

    event ReserveLiquidityCheckSubmitted(
        address indexed trader,
        bytes32 hasLiqHandle,
        bytes32 sizeHandle
    );
    event WithdrawCheckSubmitted(
        address indexed lp,
        bytes32 hasBalHandle,
        bytes32 hasLiqHandle,
        uint256 shares
    );

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
     * @notice Record an LP deposit with proportional share issuance (fully encrypted).
     *         The Router must call confidentialTransferFrom(lp, vault, eAmount) BEFORE
     *         calling this so tokens are already in the vault.
     * @param lp      LP address.
     * @param eAmount Encrypted deposit amount (euint64).
     */
    function deposit(address lp, euint64 eAmount) external onlyRouter {
        euint64 shares;

        if (!initialized) {
            shares = eAmount;
            initialized = true;
        } else {
            shares = FHE.div(FHE.mul(eAmount, encryptedTotalSupply), totalLiquidity);
        }

        lpBalance[lp]         = FHE.add(lpBalance[lp], shares);
        encryptedTotalSupply   = FHE.add(encryptedTotalSupply, shares);
        totalLiquidity         = FHE.add(totalLiquidity, eAmount);

        FHE.allow(lpBalance[lp],       address(this));
        FHE.allow(encryptedTotalSupply, address(this));
        FHE.allow(totalLiquidity,       address(this));

        FHE.allow(lpBalance[lp],       lp);

        emit Deposit(lp, euint64.unwrap(eAmount));
    }

    function deposit(address, uint256) external pure override {
        revert("FHEVault: use deposit(address,euint64)");
    }

    /**
     * @notice Phase 1 of withdrawal: compute encrypted balance/liquidity checks and store handles.
     *         Off-chain clients decrypt emitted handles, then call `finalizeWithdrawalWithProof`.
     * @param lp     LP address.
     * @param shares Standard share amount to redeem.
     */
    function submitWithdrawalCheck(address lp, uint256 shares) public onlyRouter {
        require(shares > 0, "Invalid shares");
        euint64 eShares = FHE.asEuint64(uint64(shares));

        ebool hasBal = FHE.gte(lpBalance[lp], eShares);

        euint64 eAmount = FHE.div(FHE.mul(eShares, totalLiquidity), encryptedTotalSupply);

        euint64 eAvail = FHE.sub(totalLiquidity, totalReserved);
        ebool   hasLiq = FHE.gte(eAvail, eAmount);

        FHE.allow(hasBal,  address(this));
        FHE.allow(hasBal,  lp);
        FHE.allow(eAmount, address(this));
        FHE.allow(hasLiq,  address(this));
        FHE.allow(hasLiq,  lp);

        pendingWithdraw[lp] = PendingWithdraw(hasBal, hasLiq, eAmount, shares);

        emit WithdrawCheckSubmitted(lp, ebool.unwrap(hasBal), ebool.unwrap(hasLiq), shares);
    }

    /**
     * @notice Phase 2 of withdrawal: verify CoFHE decrypt proofs and execute transfer.
     *         Payout amount is transferred as an encrypted euint64 — the exact amount
     *         is never exposed on-chain.
     * @param lp       LP redeeming shares.
     * @param shares   Must match the value submitted in `submitWithdrawalCheck`.
     * @param balPlain Decrypted balance-check boolean from the Threshold Network.
     * @param balSig   Threshold Network signature for hasBal.
     * @param liqPlain Decrypted liquidity-check boolean from the Threshold Network.
     * @param liqSig   Threshold Network signature for hasLiq.
     * @return amountHandle The euint64 handle of the withdrawn amount (bytes32);
     *         callers emit this in the RemoveLiquidity event.
     */
    function finalizeWithdrawalWithProof(
        address lp,
        uint256 shares,
        bool    balPlain,
        bytes calldata balSig,
        bool    liqPlain,
        bytes calldata liqSig
    ) public onlyRouter returns (bytes32 amountHandle) {
        PendingWithdraw storage pw = pendingWithdraw[lp];
        require(pw.shares == shares && pw.shares > 0, "No pending withdraw or shares mismatch");

        require(FHE.verifyDecryptResult(pw.hasBal, balPlain, balSig), "Invalid bal decrypt");
        require(balPlain, "Insufficient shares");

        require(FHE.verifyDecryptResult(pw.hasLiq, liqPlain, liqSig), "Invalid liq decrypt");
        require(liqPlain, "Liquidity locked");

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
        FHE.allow(eAmount,              lp);

        collateralToken.confidentialTransfer(lp, eAmount);

        amountHandle = euint64.unwrap(eAmount);
        emit Withdraw(lp, amountHandle);
    }

    function withdraw(address, uint256) external pure override returns (uint256) {
        revert("FHEVault: use withdrawWithProof");
    }

    // --------------------------------------------------------
    // POSITION MANAGER FUNCTIONS (IVault)
    // --------------------------------------------------------

    /**
     * @notice Phase 1 of open-position liquidity: compute encrypted availability check.
     *         Emits check and size handles for off-chain decryption and proof generation.
     * @param trader Address for whom the check is computed.
     * @param eSize  Encrypted position size (collateral * leverage) (remains fully encrypted).
     */
    function submitOpenLiquidityCheck(address trader, euint64 eSize) public onlyRouter {
        euint64 eAvail  = FHE.sub(totalLiquidity, totalReserved);
        ebool   hasLiq  = FHE.gte(eAvail, eSize);

        FHE.allow(hasLiq, address(this));
        FHE.allow(hasLiq, trader);
        FHE.allow(eSize,  address(this));

        pendingLiqCheck[trader] = PendingLiqCheck(hasLiq, eSize);

        emit ReserveLiquidityCheckSubmitted(
            trader,
            ebool.unwrap(hasLiq),
            euint64.unwrap(eSize)
        );
    }

    /**
     * @notice Phase 1.5 of open-position liquidity: verify decrypt proof and store approved size.
     *         Must be called before `consumeOpenLiquidityApproval`.
     * @param trader      Trader address (must match the key used in `submitOpenLiquidityCheck`).
     * @param hasLiqPlain Decrypted boolean from the Threshold Network.
     * @param hasLiqSig   Threshold Network signature for the hasLiq handle.
     */
    function confirmOpenLiquidityCheck(
        address trader,
        bool    hasLiqPlain,
        bytes calldata hasLiqSig
    ) public onlyRouter {
        PendingLiqCheck storage plc = pendingLiqCheck[trader];
        require(ebool.unwrap(plc.hasLiq) != bytes32(0), "no pending check");

        require(FHE.verifyDecryptResult(plc.hasLiq, hasLiqPlain, hasLiqSig), "Invalid hasLiq decrypt");

        _liqApproved[trader]      = hasLiqPlain;
        _liqApprovedSize[trader]  = plc.eSize;
        FHE.allow(plc.eSize, address(this));
        delete pendingLiqCheck[trader];
    }

    function consumeOpenLiquidityApproval(address trader) public onlyPositionManager {
        require(_liqApproved[trader], "Insufficient vault liquidity");
        euint64 eSize = _liqApprovedSize[trader];
        delete _liqApproved[trader];
        _liqApprovedSize[trader] = euint64.wrap(bytes32(0));

        totalReserved = FHE.add(totalReserved, eSize);
        FHE.allow(totalReserved, address(this));

        emit IncreaseReserved(euint64.unwrap(eSize));
    }

    function releaseLiquidity(uint256 amount) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        totalReserved = FHE.sub(totalReserved, eAmount);
        FHE.allow(totalReserved, address(this));
        emit DecreaseReserved(amount);
    }

    function payTrader(address user, uint256 profit, uint256 returnedCollateral)
        external
        onlyPositionManager
    {
        uint256 total = profit + returnedCollateral;

        if (profit > 0) {
            totalLiquidity = FHE.sub(totalLiquidity, FHE.asEuint64(uint64(profit)));
            FHE.allow(totalLiquidity, address(this));
        }
        if (returnedCollateral > 0) {
            totalLiquidity = FHE.sub(totalLiquidity, FHE.asEuint64(uint64(returnedCollateral)));
            FHE.allow(totalLiquidity, address(this));
        }

        euint64 ePayout = FHE.asEuint64(uint64(total));
        FHE.allow(ePayout, address(collateralToken));
        FHE.allow(ePayout, user);
        collateralToken.confidentialTransfer(user, ePayout);

        emit PayOut(user, euint64.unwrap(ePayout));
    }

    function receiveLoss(uint256 amount) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        totalLiquidity = FHE.add(totalLiquidity, eAmount);
        FHE.allow(totalLiquidity, address(this));
        emit ReceiveLoss(euint64.unwrap(eAmount));
    }

    /**
     * @notice Refund collateral to a user (e.g. on order cancellation).
     * @param eAmount Encrypted refund amount.
     */
    function refundCollateral(address user, euint64 eAmount) external onlyRouter {
        FHE.allow(eAmount, address(collateralToken));
        FHE.allow(eAmount, user);
        collateralToken.confidentialTransfer(user, eAmount);
    }

    function refundCollateral(address, uint256) external pure override {
        revert("FHEVault: use refundCollateral(address,euint64)");
    }

    // Backward-compatible aliases for existing integrations.
    function submitWithdrawCheck(address lp, uint256 shares) external {
        submitWithdrawalCheck(lp, shares);
    }

    function withdrawWithProof(
        address lp,
        uint256 shares,
        bool    balPlain,
        bytes calldata balSig,
        bool    liqPlain,
        bytes calldata liqSig
    ) external returns (bytes32 amountHandle) {
        return finalizeWithdrawalWithProof(lp, shares, balPlain, balSig, liqPlain, liqSig);
    }

    function submitReserveLiquidityCheck(address trader, euint64 eSize) external {
        submitOpenLiquidityCheck(trader, eSize);
    }

    function storeReserveLiquidityProof(
        address trader,
        bool    hasLiqPlain,
        bytes calldata hasLiqSig
    ) external {
        confirmOpenLiquidityCheck(trader, hasLiqPlain, hasLiqSig);
    }

    function reserveLiquidity(address trader) external override {
        consumeOpenLiquidityApproval(trader);
    }
}
