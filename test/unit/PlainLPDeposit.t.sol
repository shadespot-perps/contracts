// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { FHE, euint64, InEuint64, InEbool } from "cofhe-contracts/FHE.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/core/FHEVault.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/FHEFundingRateManager.sol";
import "../../src/trading/FHERouter.sol";
import "../../src/trading/FHEOrderManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../../src/tokens/MockFHEToken.sol";
import "../mocks/MockTaskManager.sol";

contract MockPlainERC20 is ERC20 {
    constructor() ERC20("Plain USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title PlainLPDepositTest
 * @notice Tests for addLiquidityPlain and finalizeLiquidityWithdrawalPlain.
 *
 * addLiquidityPlain flow:
 *   LP approves router on underlying → router.addLiquidityPlain(amount)
 *     → transferFrom(lp → vault)         vault: +amount underlying
 *     → vault.depositPlain(lp, amount)
 *         plainUnderlyingReserve += amount
 *         collateralToken.wrap(vault, amount)  vault: +amount encrypted (minted)
 *         LP shares issued, totalLiquidity += amount
 *
 * finalizeLiquidityWithdrawalPlain flow (two-phase, mirrors encrypted withdrawal):
 *   1. router.submitLiquidityWithdrawalCheck(shares)
 *      → emits WithdrawCheckSubmitted(..., amountHandle, shares)
 *   2. Off-chain: decrypt hasBal, hasLiq, eAmount
 *   3. router.finalizeLiquidityWithdrawalPlain(shares, balPlain, balSig,
 *                                               liqPlain, liqSig,
 *                                               amountPlain, amountSig)
 *      → collateralToken.unwrap(vault, amountPlain)  burns vault encrypted
 *      → underlyingToken.transfer(lp, amountPlain)   sends USDC to LP
 *      → plainUnderlyingReserve -= amountPlain
 *      → totalLiquidity -= amountPlain
 */
contract PlainLPDepositTest is Test {
    address constant TASK_MANAGER_ADDR = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    MockPlainERC20        underlying;
    MockFHEToken          fheToken;
    FHEVault              vault;
    PositionManager       pm;
    LiquidationManager    lm;
    FHEFundingRateManager fheFRM;
    FHEOrderManager       om;
    FHERouter             router;
    PriceOracle           oracle;

    bytes32 lastPosId;

    address owner     = address(this);
    address encLP     = address(0x10); // seeds vault with encrypted liquidity
    address plainLP   = address(0x11); // deposits underlying directly
    address encTrader = address(0x20); // opens positions via encrypted path

    address ethToken;

    uint64 constant ENC_LP_SEED = 100_000e6;
    uint64 constant LP_PLAIN    =  50_000e6;
    uint64 constant COLLATERAL  =   1_000e6;
    uint64 constant LEVERAGE    =           5;
    uint64 constant SIZE        = COLLATERAL * LEVERAGE;
    uint64 constant PNL         =     500e6;

    uint256 constant PRICE_ENTRY = 2_000e18;
    uint256 constant PRICE_UP    = 2_200e18;
    uint256 constant PRICE_DOWN  = 1_800e18;

    // ── setup ─────────────────────────────────────────────────────────────

    function setUp() public {
        vm.etch(TASK_MANAGER_ADDR, address(new MockTaskManager()).code);

        ethToken   = address(0xE7);
        underlying = new MockPlainERC20();
        fheToken   = new MockFHEToken("Encrypted USDC", "eUSDC");

        oracle = new PriceOracle();
        fheFRM = new FHEFundingRateManager();
        vault  = new FHEVault(address(fheToken), owner);
        pm     = new PositionManager(address(vault), address(oracle));
        lm     = new LiquidationManager(address(pm), address(fheFRM));
        om     = new FHEOrderManager(address(oracle), address(fheFRM), owner);
        router = new FHERouter(
            address(pm), address(vault), address(om),
            address(fheFRM), address(fheToken), ethToken, address(underlying)
        );

        vault.setPositionManager(address(pm));
        vault.setRouter(address(router));
        vault.setUnderlyingToken(address(underlying));
        pm.setRouter(address(router));
        pm.setFheRouter(address(router));
        pm.setLiquidationManager(address(lm));
        pm.setFinalizer(address(this));
        pm.setFHEFundingManager(address(fheFRM));
        fheFRM.setPositionManager(address(pm));
        fheFRM.initializeToken(ethToken);
        om.setRouter(address(router));
        oracle.setPrice(ethToken, PRICE_ENTRY);

        // Encrypted LP seeds the vault (first deposit — sets initialized = true, shares = amount)
        fheToken.mint(encLP, ENC_LP_SEED);
        vm.prank(encLP);
        fheToken.setOperator(address(router), type(uint48).max);
        vm.prank(encLP);
        router.addLiquidity(_enc64(ENC_LP_SEED));

        // Encrypted trader
        fheToken.mint(encTrader, COLLATERAL * 10);
        vm.prank(encTrader);
        fheToken.setOperator(address(router), type(uint48).max);

        // Plain LP holds only underlying ERC-20
        underlying.mint(plainLP, uint256(LP_PLAIN) * 3);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _enc64(uint256 v) internal pure returns (InEuint64 memory) {
        return InEuint64({ ctHash: v, securityZone: 0, utype: 5, signature: "" });
    }

    function _encBool(bool v) internal pure returns (InEbool memory) {
        return InEbool({ ctHash: v ? 1 : 0, securityZone: 0, utype: 0, signature: "" });
    }

    /// Approve router and deposit plain liquidity in one call.
    function _addPlainLiquidity(address lp_, uint64 amount) internal {
        vm.prank(lp_);
        underlying.approve(address(router), amount);
        vm.prank(lp_);
        router.addLiquidityPlain(amount);
    }

    /// Submit withdrawal check then finalize plain withdrawal.
    function _withdrawPlain(address lp_, uint256 shares, uint64 amountPlain) internal {
        vm.prank(lp_);
        router.submitLiquidityWithdrawalCheck(shares);
        vm.prank(lp_);
        router.finalizeLiquidityWithdrawalPlain(
            shares,
            true, "",         // hasBal
            true, "",         // hasLiq
            amountPlain, ""   // amountPlain + sig
        );
    }

    /// Open a position with encrypted collateral.
    function _openEncrypted(address t, bool isLong) internal {
        vm.prank(t);
        router.submitDecryptTaskForOpen(ethToken, _enc64(COLLATERAL), _enc64(LEVERAGE), _encBool(isLong));
        vm.prank(t);
        lastPosId = router.openPosition(
            ethToken, _enc64(COLLATERAL), _enc64(LEVERAGE), _encBool(isLong), true, ""
        );
    }

    /// Request + finalize plain-payout close.
    function _closePlain(address t, bytes32 posId, uint64 finalAmt) internal {
        vm.prank(t);
        router.requestClosePlainPayout(posId);
        router.finalizeClosePlainPayout(
            posId, uint256(finalAmt), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    // ======================================================================
    // SECTION 1 — addLiquidityPlain guards
    // ======================================================================

    function test_PlainLPDeposit_NoApproval_Reverts() public {
        vm.prank(plainLP);
        vm.expectRevert();
        router.addLiquidityPlain(LP_PLAIN);
    }

    function test_PlainLPDeposit_DirectVaultCall_Reverts() public {
        vm.expectRevert("Not router");
        vault.depositPlain(plainLP, LP_PLAIN);
    }

    function test_PlainLPDeposit_UnderlyingNotConfigured_Reverts() public {
        FHEVault freshVault = new FHEVault(address(fheToken), owner);
        FHERouter freshRouter = new FHERouter(
            address(pm), address(freshVault), address(om),
            address(fheFRM), address(fheToken), ethToken,
            address(0) // no underlying
        );
        freshVault.setRouter(address(freshRouter));

        vm.prank(plainLP);
        underlying.approve(address(freshRouter), LP_PLAIN);
        vm.prank(plainLP);
        vm.expectRevert("underlying not configured");
        freshRouter.addLiquidityPlain(LP_PLAIN);
    }

    // ======================================================================
    // SECTION 2 — addLiquidityPlain accounting
    // ======================================================================

    function test_PlainLPDeposit_PlainReserveIncreased() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        assertEq(vault.plainUnderlyingReserve(), LP_PLAIN);
    }

    function test_PlainLPDeposit_TotalLiquidityIncreased() public {
        (uint64 liqBefore, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        _addPlainLiquidity(plainLP, LP_PLAIN);
        (uint64 liqAfter, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liqAfter - liqBefore, LP_PLAIN);
    }

    function test_PlainLPDeposit_VaultHoldsUnderlying() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        assertEq(underlying.balanceOf(address(vault)), LP_PLAIN);
    }

    function test_PlainLPDeposit_LPUnderlyingDecreased() public {
        uint256 before_ = underlying.balanceOf(plainLP);
        _addPlainLiquidity(plainLP, LP_PLAIN);
        assertEq(underlying.balanceOf(plainLP), before_ - LP_PLAIN);
    }

    function test_PlainLPDeposit_VaultEncryptedBalanceIncreased() public {
        (uint64 encBefore, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(address(vault)));
        _addPlainLiquidity(plainLP, LP_PLAIN);
        (uint64 encAfter, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(address(vault)));
        // vault minted LP_PLAIN encrypted to itself via wrap()
        assertEq(encAfter - encBefore, LP_PLAIN);
    }

    function test_PlainLPDeposit_TwoDeposits_ReserveAccumulates() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        _addPlainLiquidity(plainLP, LP_PLAIN);
        assertEq(vault.plainUnderlyingReserve(), uint256(LP_PLAIN) * 2);
    }

    function test_PlainLPDeposit_TotalLiquidityCorrectAfterBothPaths() public {
        // ENC_LP_SEED already deposited in setUp; now add LP_PLAIN via plain path
        _addPlainLiquidity(plainLP, LP_PLAIN);
        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, ENC_LP_SEED + LP_PLAIN);
    }

    function test_PlainLPDeposit_EmitsDepositEvent() public {
        vm.prank(plainLP);
        underlying.approve(address(router), LP_PLAIN);

        vm.prank(plainLP);
        vm.expectEmit(true, false, false, false);
        emit FHEVault.Deposit(plainLP, bytes32(0));
        router.addLiquidityPlain(LP_PLAIN);
    }

    // ======================================================================
    // SECTION 3 — finalizeLiquidityWithdrawalPlain
    // ======================================================================

    function test_PlainLPWithdraw_ReceivesUnderlying() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        uint256 before_ = underlying.balanceOf(plainLP);
        _withdrawPlain(plainLP, LP_PLAIN, LP_PLAIN);
        assertEq(underlying.balanceOf(plainLP) - before_, LP_PLAIN);
    }

    function test_PlainLPWithdraw_VaultUnderlyingZero() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        _withdrawPlain(plainLP, LP_PLAIN, LP_PLAIN);
        assertEq(underlying.balanceOf(address(vault)), 0);
    }

    function test_PlainLPWithdraw_PlainReserveDecreased() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        _withdrawPlain(plainLP, LP_PLAIN, LP_PLAIN);
        assertEq(vault.plainUnderlyingReserve(), 0);
    }

    function test_PlainLPWithdraw_TotalLiquidityDecreased() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        (uint64 liqBefore, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        _withdrawPlain(plainLP, LP_PLAIN, LP_PLAIN);
        (uint64 liqAfter, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liqBefore - liqAfter, LP_PLAIN);
    }

    function test_PlainLPWithdraw_VaultEncryptedDecreased() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        (uint64 encBefore, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(address(vault)));
        _withdrawPlain(plainLP, LP_PLAIN, LP_PLAIN);
        (uint64 encAfter, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(address(vault)));
        // unwrap() burned LP_PLAIN encrypted from vault
        assertEq(encBefore - encAfter, LP_PLAIN);
    }

    function test_PlainLPWithdraw_NoPendingWithdraw_Reverts() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        vm.prank(plainLP);
        vm.expectRevert("No pending withdraw or shares mismatch");
        router.finalizeLiquidityWithdrawalPlain(LP_PLAIN, true, "", true, "", LP_PLAIN, "");
    }

    function test_PlainLPWithdraw_SharesMismatch_Reverts() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        vm.prank(plainLP);
        router.submitLiquidityWithdrawalCheck(LP_PLAIN);

        vm.prank(plainLP);
        vm.expectRevert("No pending withdraw or shares mismatch");
        router.finalizeLiquidityWithdrawalPlain(LP_PLAIN / 2, true, "", true, "", LP_PLAIN / 2, "");
    }

    function test_PlainLPWithdraw_InsufficientShares_Reverts() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        vm.prank(plainLP);
        router.submitLiquidityWithdrawalCheck(LP_PLAIN);

        vm.prank(plainLP);
        vm.expectRevert("Insufficient shares");
        router.finalizeLiquidityWithdrawalPlain(
            LP_PLAIN,
            false, "",   // balPlain = false → not enough shares
            true,  "",
            LP_PLAIN, ""
        );
    }

    function test_PlainLPWithdraw_LiquidityLocked_Reverts() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        vm.prank(plainLP);
        router.submitLiquidityWithdrawalCheck(LP_PLAIN);

        vm.prank(plainLP);
        vm.expectRevert("Liquidity locked");
        router.finalizeLiquidityWithdrawalPlain(
            LP_PLAIN,
            true,  "",
            false, "",   // liqPlain = false → liquidity reserved by open positions
            LP_PLAIN, ""
        );
    }

    function test_PlainLPWithdraw_InsufficientReserve_Reverts() public {
        // plainLP deposits COLLATERAL; an enc-open position closes plain → drains reserve
        _addPlainLiquidity(plainLP, COLLATERAL);
        _openEncrypted(encTrader, true);
        _closePlain(encTrader, lastPosId, COLLATERAL);
        assertEq(vault.plainUnderlyingReserve(), 0);

        // plainLP tries plain-withdraw — no reserve left
        vm.prank(plainLP);
        router.submitLiquidityWithdrawalCheck(COLLATERAL);
        vm.prank(plainLP);
        vm.expectRevert("insufficient plain reserve");
        router.finalizeLiquidityWithdrawalPlain(COLLATERAL, true, "", true, "", COLLATERAL, "");
    }

    function test_PlainLPWithdraw_EmitsWithdrawEvent() public {
        _addPlainLiquidity(plainLP, LP_PLAIN);
        vm.prank(plainLP);
        router.submitLiquidityWithdrawalCheck(LP_PLAIN);

        vm.prank(plainLP);
        vm.expectEmit(true, false, false, false);
        emit FHEVault.Withdraw(plainLP, bytes32(0));
        router.finalizeLiquidityWithdrawalPlain(LP_PLAIN, true, "", true, "", LP_PLAIN, "");
    }

    // ======================================================================
    // SECTION 4 — plain LP reserve funds encrypted-open → plain-close
    // ======================================================================

    function test_PlainLPDeposit_FundsEncOpen_PlainClose_BreakEven() public {
        _addPlainLiquidity(plainLP, COLLATERAL);

        _openEncrypted(encTrader, true);
        _closePlain(encTrader, lastPosId, COLLATERAL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL);
        assertEq(vault.plainUnderlyingReserve(), 0);
    }

    function test_PlainLPDeposit_FundsEncOpen_PlainClose_Profitable() public {
        // Deposit enough for profit + collateral
        _addPlainLiquidity(plainLP, COLLATERAL + PNL);

        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_UP);
        _closePlain(encTrader, lastPosId, COLLATERAL + PNL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL + PNL);
        assertEq(vault.plainUnderlyingReserve(), 0);
    }

    function test_PlainLPDeposit_FundsEncOpen_PlainClose_Loss() public {
        _addPlainLiquidity(plainLP, COLLATERAL);

        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_DOWN);
        _closePlain(encTrader, lastPosId, COLLATERAL - PNL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL - PNL);
        // Loss portion (PNL) stays in reserve — available for future payouts
        assertEq(vault.plainUnderlyingReserve(), PNL);
    }

    function test_PlainLPDeposit_WithoutReserve_EncOpen_PlainClose_Reverts() public {
        // No plain LP deposit; encrypted-open trader requests plain payout → reverts
        _openEncrypted(encTrader, true);
        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        vm.expectRevert("insufficient plain reserve");
        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );

        // Position not deleted — no limbo state
        assertTrue(pm.positionExists(lastPosId));
    }

    function test_PlainLPDeposit_ReservePartiallyReplenishedByLoss() public {
        // plainLP deposits COLLATERAL; encTrader loses → PNL stays in reserve
        _addPlainLiquidity(plainLP, COLLATERAL);
        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_DOWN);
        _closePlain(encTrader, lastPosId, COLLATERAL - PNL);

        // Reserve now has PNL — a second close for PNL can succeed
        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_ENTRY);
        _closePlain(encTrader, lastPosId, PNL);
        assertEq(vault.plainUnderlyingReserve(), 0);
    }

    // ======================================================================
    // SECTION 5 — LP can switch between encrypted and plain withdrawal
    // ======================================================================

    function test_EncLP_CanWithdrawPlain_WhenReserveAvailable() public {
        // encLP deposited ENC_LP_SEED encrypted; plainLP adds LP_PLAIN plain.
        // Plain reserve = LP_PLAIN, so encLP can withdraw at most LP_PLAIN shares in plain.
        // Pool is 1:1 (totalLiquidity = encryptedTotalSupply), so LP_PLAIN shares = LP_PLAIN underlying.
        _addPlainLiquidity(plainLP, LP_PLAIN);

        vm.prank(encLP);
        router.submitLiquidityWithdrawalCheck(LP_PLAIN);
        vm.prank(encLP);
        router.finalizeLiquidityWithdrawalPlain(
            LP_PLAIN, true, "", true, "", LP_PLAIN, ""
        );

        assertEq(underlying.balanceOf(encLP), LP_PLAIN);
        assertEq(vault.plainUnderlyingReserve(), 0);
    }

    function test_EncLP_CannotWithdrawPlain_WithoutReserve() public {
        // No plain reserve; encLP tries plain withdrawal → reverts
        vm.prank(encLP);
        router.submitLiquidityWithdrawalCheck(ENC_LP_SEED);
        vm.prank(encLP);
        vm.expectRevert("insufficient plain reserve");
        router.finalizeLiquidityWithdrawalPlain(
            ENC_LP_SEED, true, "", true, "", ENC_LP_SEED, ""
        );
    }
}
