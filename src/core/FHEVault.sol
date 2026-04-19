// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./IVault.sol";
import "../tokens/IEncryptedERC20.sol";
import { FHE, euint64, euint128, ebool } from "cofhe-contracts/FHE.sol";

/**
 * @title FHEVault
 * @notice ShadeSpot vault — collateral is a Fhenix FHERC20 token (euint64 encrypted balances).
 *
Privacy properties:
 *   - totalLiquidity, totalReserved, encryptedTotalSupply and every LP balance
 *     are stored as euint64 ciphertexts — pool depth, open interest, and all
 *     LP share holdings are unreadable on-chain.
 *   - All events that reference amounts emit ciphertext handles (bytes32) so
 *     on-chain observers see only opaque values; authorised parties decrypt
 *     client-side via the CoFHE SDK.
 *
Yield distribution (mirrors Vault proportional-share model, fully in FHE):
 *   - deposit:  shares = (amount * encryptedTotalSupply) / totalLiquidity
 *   - withdraw: amount = (shares * totalLiquidity) / encryptedTotalSupply
 *   - As traders lose (receiveLoss grows totalLiquidity), each share redeems
 *     for more collateral — identical economics to Vault but with encrypted state.
 *
NOTE on overflow: FHE.mul operates on euint64 (max ~1.8 × 10^19).
 *   The product (amount × totalSupply) or (shares × totalLiquidity) must not
 *   exceed this bound. Use tokens with ≤ 6 decimals or enforce deposit caps.
 *
Three-phase pattern for openPosition:
 *   1. submitReserveLiquidityCheck   — compute FHE check, emit handle
 *   2. storeReserveLiquidityProof    — off-chain decrypt → publishDecryptResult, store approval
 *   3. reserveLiquidity(trader)      — consume approval, update encrypted state
 *
Two-phase pattern for removeLiquidity:
 *   1. submitWithdrawCheck  — compute FHE checks, emit handles
 *   2. withdrawWithProof    — off-chain decrypt → publishDecryptResult, execute transfer
 *
releaseLiquidity and payTrader are called from PositionManager.finalizeClosePosition /
 * finalizeLiquidation where amounts are finalized verified values via publishDecryptResult.
 * They update encrypted state directly without further decrypt steps.
 *
Operator setup (done once per user, off-chain before first trade):
 *   fheToken.setOperator(address(fheRouter), untilTimestamp)
 */
contract FHEVault is IVault {

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

    // Phase 1: open position — stores the FHE check handle and the encrypted size it was
    // computed for. The size is kept encrypted so PositionManager never sees it as plaintext.
    struct PendingLiqCheck {
        ebool   hasLiq;
        euint64 eSize; // collateral * leverage, encrypted
    }
    mapping(address => PendingLiqCheck) public pendingLiqCheck;

    // Phase 1.5: after publishDecryptResult verifies the proof, the approved encrypted size
    // is stored here. Consumed (deleted) atomically in reserveLiquidity.
    mapping(address => bool)    private _liqApproved;
    mapping(address => euint64) private _liqApprovedSize; // encrypted size, no plaintext

    // Phase 1: withdraw
    struct PendingWithdraw {
        ebool   hasBal;
        ebool   hasLiq;
        euint64 eAmount;
        uint256 shares;
    }
    mapping(address => PendingWithdraw) public pendingWithdraw;

    // ---------------------------------------------------------------------------
    // EVENTS — all amounts are ciphertext handles (bytes32) so observers cannot
    //          read values; authorised parties decrypt client-side via CoFHE SDK.
    // ---------------------------------------------------------------------------

    event Deposit(address indexed user, bytes32 amountHandle);
    event Withdraw(address indexed user, bytes32 amountHandle);

    /// @dev Emitted from reserveLiquidity; handle is the encrypted size reserved.
    event IncreaseReserved(bytes32 sizeHandle);
    /// @dev Emitted from releaseLiquidity; plaintext amount (already public at this stage
    ///      because it came from a publishDecryptResult in PositionManager).
    event DecreaseReserved(uint256 amount);

    /// @dev Payout handle — authorised party (trader) decrypts client-side.
    event PayOut(address indexed user, bytes32 payoutHandle);
    /// @dev Loss handle — pool delta, decryptable by vault owner for accounting.
    event ReceiveLoss(bytes32 amountHandle);

    // Off-chain clients watch these to discover handles for decryption.
    event ReserveLiquidityCheckSubmitted(
        address indexed trader,
        bytes32 hasLiqHandle,
        bytes32 sizeHandle    // encrypted size (collateral*leverage)
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
            // First deposit: 1:1 to avoid division by zero on encryptedTotalSupply
            shares = eAmount;
            initialized = true;
        } else {
            // shares = (amount * encryptedTotalSupply) / totalLiquidity
            shares = FHE.div(FHE.mul(eAmount, encryptedTotalSupply), totalLiquidity);
        }

        lpBalance[lp]         = FHE.add(lpBalance[lp], shares);
        encryptedTotalSupply   = FHE.add(encryptedTotalSupply, shares);
        totalLiquidity         = FHE.add(totalLiquidity, eAmount);

        FHE.allow(lpBalance[lp],       address(this));
        FHE.allow(encryptedTotalSupply, address(this));
        FHE.allow(totalLiquidity,       address(this));

        // Enable LP to use EIP-712 permits to fetch their balance in the UI
        FHE.allow(lpBalance[lp],       lp);

        emit Deposit(lp, euint64.unwrap(eAmount));
    }

    // IVault.deposit stub — FHEVault uses deposit(address, euint64) instead.
    function deposit(address, uint256) external pure override {
        revert("FHEVault: use deposit(address,euint64)");
    }

    /**
     * @notice Phase 1 of withdraw: compute encrypted balance and liquidity checks, store
     *         handles, and allow this contract to publishDecryptResult in Phase 2.
     *         Off-chain: decrypt the emitted handles, then call withdrawWithProof.
     * @param lp     LP address.
     * @param shares Standard share amount to redeem.
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

        // Allow this contract to publishDecryptResult in Phase 2.
        // Allow the LP to decrypt both check handles via a self-permit.
        FHE.allow(hasBal,  address(this));
        FHE.allow(hasBal,  lp);
        FHE.allow(eAmount, address(this));
        FHE.allow(hasLiq,  address(this));
        FHE.allow(hasLiq,  lp);

        pendingWithdraw[lp] = PendingWithdraw(hasBal, hasLiq, eAmount, shares);

        emit WithdrawCheckSubmitted(lp, ebool.unwrap(hasBal), ebool.unwrap(hasLiq), shares);
    }

    /**
     * @notice Phase 2 of withdraw: verify CoFHE decrypt proofs and execute the withdrawal.
     *         Payout amount is transferred as an encrypted euint64 — the exact amount
     *         is never exposed on-chain.
     * @param lp       LP redeeming shares.
     * @param shares   Must match the value submitted in submitWithdrawCheck.
     * @param balPlain Decrypted balance-check boolean from the Threshold Network.
     * @param balSig   Threshold Network signature for hasBal.
     * @param liqPlain Decrypted liquidity-check boolean from the Threshold Network.
     * @param liqSig   Threshold Network signature for hasLiq.
     * @return amountHandle The euint64 handle of the withdrawn amount (bytes32);
     *         callers emit this in the RemoveLiquidity event.
     */
    function withdrawWithProof(
        address lp,
        uint256 shares,
        bool    balPlain,
        bytes calldata balSig,
        bool    liqPlain,
        bytes calldata liqSig
    ) external onlyRouter returns (bytes32 amountHandle) {
        PendingWithdraw storage pw = pendingWithdraw[lp];
        require(pw.shares == shares && pw.shares > 0, "No pending withdraw or shares mismatch");

        // Verify Threshold Network proofs without publishing the booleans globally on-chain.
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
        FHE.allow(eAmount,              lp); // LP can verify their payout client-side

        collateralToken.confidentialTransfer(lp, eAmount);

        amountHandle = euint64.unwrap(eAmount);
        emit Withdraw(lp, amountHandle);
    }

    // IVault.withdraw stub — FHEVault uses withdrawWithProof instead.
    function withdraw(address, uint256) external pure override returns (uint256) {
        revert("FHEVault: use withdrawWithProof");
    }

    // --------------------------------------------------------
    // POSITION MANAGER FUNCTIONS (IVault)
    // --------------------------------------------------------

    /**
     * @notice Phase 1: compute the encrypted availability check for a new position and
     *         store the handle so the off-chain client can decrypt and provide a proof.
     *         Emit both the check handle and the encrypted size handle for keepers/clients.
     *         Off-chain: decrypt handle, obtain (bool plain, bytes sig), call storeReserveLiquidityProof.
     * @param trader Address for whom the check is computed.
     * @param eSize  Encrypted position size (collateral * leverage) (remains fully encrypted).
     */
    function submitReserveLiquidityCheck(address trader, euint64 eSize) external onlyRouter {
        euint64 eAvail  = FHE.sub(totalLiquidity, totalReserved);
        ebool   hasLiq  = FHE.gte(eAvail, eSize);

        // Allow this contract to publishDecryptResult in Phase 1.5.
        // Allow the trader to decrypt hasLiq via a self-permit (withPermit route).
        FHE.allow(hasLiq, address(this));
        FHE.allow(hasLiq, trader);
        FHE.allow(eSize,  address(this));

        pendingLiqCheck[trader] = PendingLiqCheck(hasLiq, eSize);

        emit ReserveLiquidityCheckSubmitted(
            trader,
            ebool.unwrap(hasLiq),
            euint64.unwrap(eSize)  // ciphertext handle — no plaintext
        );
    }

    /**
     * @notice Phase 1.5: verify the off-chain decrypt proof and store the approved size.
     *         Must be called (by the router) before the router calls positionManager.openPosition.
     * @param trader      Trader address (must match the key used in submitReserveLiquidityCheck).
     * @param hasLiqPlain Decrypted boolean from the Threshold Network.
     * @param hasLiqSig   Threshold Network signature for the hasLiq handle.
     */
    function storeReserveLiquidityProof(
        address trader,
        bool    hasLiqPlain,
        bytes calldata hasLiqSig
    ) external onlyRouter {
        PendingLiqCheck storage plc = pendingLiqCheck[trader];
        require(ebool.unwrap(plc.hasLiq) != bytes32(0), "no pending check");

        // Verifies the Threshold Network proof on-chain without publishing the boolean globally.
        require(FHE.verifyDecryptResult(plc.hasLiq, hasLiqPlain, hasLiqSig), "Invalid hasLiq decrypt");

        // Store encrypted size; no plaintext ever written here.
        _liqApproved[trader]      = hasLiqPlain;
        _liqApprovedSize[trader]  = plc.eSize;
        FHE.allow(plc.eSize, address(this));
        delete pendingLiqCheck[trader];
    }

    /**
     * @notice Called by PositionManager.openPosition — consumes the pre-verified approval.
     *         The approval was set by storeReserveLiquidityProof with a valid Threshold Network proof.
     *         the vault reads its internally stored euint64.
     */
    function reserveLiquidity(address trader) external onlyPositionManager {
        require(_liqApproved[trader], "Insufficient vault liquidity");
        euint64 eSize = _liqApprovedSize[trader];
        delete _liqApproved[trader];
        _liqApprovedSize[trader] = euint64.wrap(bytes32(0));

        totalReserved = FHE.add(totalReserved, eSize);
        FHE.allow(totalReserved, address(this));

        emit IncreaseReserved(euint64.unwrap(eSize));
    }

    /**
     * @notice Release reserved liquidity after a position is closed or liquidated.
     *         `amount` is a verified decrypted value from publishDecryptResult in
     *         PositionManager.finalizeClosePosition / finalizeLiquidation.
     *         The invariant totalReserved >= amount is maintained by the protocol.
     */
    function releaseLiquidity(uint256 amount) external onlyPositionManager {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        totalReserved = FHE.sub(totalReserved, eAmount);
        FHE.allow(totalReserved, address(this));
        // amount is already public at this stage (came via publishDecryptResult)
        emit DecreaseReserved(amount);
    }

    /**
     * @notice Pay out a trader's settlement amount (profit + returned collateral).
     *         Both values are finalized verified values from publishDecryptResult in the
     *         PositionManager finalize step — no additional FHE cap is needed.
     */
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
        FHE.allow(ePayout, user); // trader can verify their payout client-side
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

    // IVault.refundCollateral stub — FHEVault uses refundCollateral(address, euint64).
    function refundCollateral(address, uint256) external pure override {
        revert("FHEVault: use refundCollateral(address,euint64)");
    }
}
