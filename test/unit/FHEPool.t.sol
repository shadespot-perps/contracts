// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { FHE, euint64 } from "cofhe-contracts/FHE.sol";

import "../../src/core/FHEVault.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/trading/FHERouter.sol";
import "../../src/trading/OrderManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../../src/tokens/MockFHEToken.sol";
import "../mocks/MockTaskManager.sol";

/**
 * @title FHEPoolTest
 * @notice End-to-end tests for Pool 2 — FHE token collateral / ETH trade.
 *
 * Amount conventions (6-decimal token, oracle prices in 1e18):
 *   1 token  = 1e6 units
 *   Amounts  : collateral = 1_000e6, leverage ≤ 10, LP seed = 100_000e6
 *   ETH price: 2_000e18  (oracle precision unchanged from Pool 1)
 *
 * How the mock enables synchronous FHE:
 *   - MockTaskManager is etched at TASK_MANAGER_ADDRESS.
 *   - trivialEncrypt(x) → handle == x (plaintext).
 *   - getDecryptResultSafe(h) → (h, true) always.
 *   - isAllowed(...)         → always true.
 *   So all euint64 handles equal their plaintext values, enabling
 *   assertEq on decrypted results.
 *
 * Operator note:
 *   FHERC20 replaces approve/allowance with time-bounded operators.
 *   Each user must call fheToken.setOperator(router, until) before
 *   any confidentialTransferFrom. Tests set until = type(uint48).max.
 */
contract FHEPoolTest is Test {

    address constant TASK_MANAGER = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    // ── contracts ─────────────────────────────────────────────────────────
    MockFHEToken       fheToken;
    FHEVault           vault;
    PositionManager    pm;
    LiquidationManager lm;
    FundingRateManager frm;
    OrderManager       om;
    FHERouter          router;
    PriceOracle        oracle;

    // ── test accounts ─────────────────────────────────────────────────────
    address owner      = address(this);
    address lp         = address(0x10);
    address trader     = address(0x20);
    address liquidator = address(0x30);

    // ── ETH index token (price feed only — no real transfers) ─────────────
    address ethToken;

    // ── amount constants (6-decimal FHE token) ────────────────────────────
    uint64  constant LP_SEED     = 100_000e6;  // LP initial deposit
    uint64  constant COLLATERAL  = 1_000e6;    // trader collateral per test
    uint64  constant LEVERAGE    = 5;
    uint64  constant SIZE        = COLLATERAL * LEVERAGE;  // 5_000e6
    uint64  constant PNL         = 500e6;      // expected PnL for 10 % move

    // Oracle prices keep 1e18 precision — too large for uint64, use uint256
    uint256 constant PRICE_ENTRY = 2_000e18;
    uint256 constant PRICE_UP    = 2_200e18;   // +10 %
    uint256 constant PRICE_DOWN  = 1_800e18;   // -10 %
    // PnL check: (200e18 * 5_000e6) / 2_000e18 = 500e6 ✓

    // ── setup ─────────────────────────────────────────────────────────────

    function setUp() public {
        vm.etch(TASK_MANAGER, address(new MockTaskManager()).code);

        // ETH index token (address used for oracle prices + position keys)
        ethToken = address(0xE7);

        // Deploy FHE token (6 decimals to stay within euint64 range)
        fheToken = new MockFHEToken("Encrypted USDC", "eUSDC");

        oracle = new PriceOracle();
        frm    = new FundingRateManager();
        vault  = new FHEVault(address(fheToken), owner, TASK_MANAGER_ADDRESS );
        pm     = new PositionManager(address(vault), address(oracle), address(frm));
        lm     = new LiquidationManager(address(pm), address(frm));
        om     = new OrderManager(address(oracle), address(frm), owner);
        router = new FHERouter(
            address(pm),
            address(vault),
            address(om),
            address(frm),
            address(fheToken),
            ethToken
        );

        // Wire contracts
        vault.setPositionManager(address(pm));
        vault.setRouter(address(router));
        pm.setRouter(address(router));
        pm.setLiquidationManager(address(lm));
        frm.setPositionManager(address(pm));
        frm.setRouter(address(router));
        frm.setLiquidationManager(address(lm));
        om.setRouter(address(router));

        oracle.setPrice(ethToken, PRICE_ENTRY);

        // Seed LP liquidity
        fheToken.mint(lp, LP_SEED);
        vm.prank(lp);
        fheToken.setOperator(address(router), type(uint48).max);
        vm.prank(lp);
        router.addLiquidity(LP_SEED);

        // Fund trader
        fheToken.mint(trader, COLLATERAL * 10);
        vm.prank(trader);
        fheToken.setOperator(address(router), type(uint48).max);
    }

    // ======================================================================
    // SECTION 1 — MockFHEToken (FHERC20 behaviour)
    // ======================================================================

    function test_FHEToken_Mint_EncryptedBalanceCorrect() public {
        fheToken.mint(address(0xAB), uint64(500e6));

        (uint64 bal, bool ok) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(0xAB))
        );
        assertTrue(ok);
        assertEq(bal, uint64(500e6));
    }

    function test_FHEToken_StandardTransfer_Reverts() public {
        vm.expectRevert();
        fheToken.transfer(address(0xAB), 100);
    }

    function test_FHEToken_StandardTransferFrom_Reverts() public {
        vm.expectRevert();
        fheToken.transferFrom(address(0xAB), address(0xCD), 100);
    }

    function test_FHEToken_StandardApprove_Reverts() public {
        vm.expectRevert();
        fheToken.approve(address(0xAB), 100);
    }

    function test_FHEToken_SetOperator_IsOperator_True() public {
        address user    = address(0x50);
        address spender = address(0x51);

        assertFalse(fheToken.isOperator(user, spender));

        vm.prank(user);
        fheToken.setOperator(spender, type(uint48).max);

        assertTrue(fheToken.isOperator(user, spender));
    }

    function test_FHEToken_ConfidentialTransferFrom_NoOperator_Reverts() public {
        address user = address(0x60);
        fheToken.mint(user, uint64(200e6));

        // user has NOT set router as operator
        euint64 eAmt = FHE.asEuint64(uint64(100e6));
        vm.prank(address(router));
        vm.expectRevert();
        fheToken.confidentialTransferFrom(user, address(vault), eAmt);
    }

    function test_FHEToken_ConfidentialTransferFrom_WithOperator_Works() public {
        address user = address(0x61);
        fheToken.mint(user, uint64(200e6));

        vm.prank(user);
        fheToken.setOperator(address(router), type(uint48).max);

        euint64 eAmt = FHE.asEuint64(uint64(100e6));
        FHE.allow(eAmt, address(fheToken));

        vm.prank(address(router));
        fheToken.confidentialTransferFrom(user, address(vault), eAmt);

        (uint64 userBal, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(user));
        assertEq(userBal, uint64(100e6));
    }

    // ======================================================================
    // SECTION 2 — FHEVault (encrypted LP accounting)
    // ======================================================================

    function test_FHEVault_Deposit_EncryptedLiquidityUpdated() public {
        // setUp already added LP_SEED via router.addLiquidity → vault.deposit
        (uint64 liq, bool ok) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertTrue(ok);
        assertEq(liq, LP_SEED);
    }

    function test_FHEVault_LPBalance_Encrypted() public {
        // lpBalance[lp] should equal LP_SEED (lp address is passed through router.addLiquidity)
        (uint64 bal, bool ok) = FHE.getDecryptResultSafe(vault.lpBalance(lp));
        assertTrue(ok);
        assertEq(bal, LP_SEED);
    }

    function test_FHEVault_Withdraw_ReducesEncryptedBalance() public {
        uint64 withdrawAmt = uint64(10_000e6);

        vm.startPrank(lp);
        router.submitWithdrawCheck(withdrawAmt);
        router.removeLiquidity(withdrawAmt);
        vm.stopPrank();

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED - withdrawAmt);
    }

    function test_FHEVault_Withdraw_TransfersTokensToLP() public {
        uint64 withdrawAmt = uint64(10_000e6);

        vm.startPrank(lp);
        router.submitWithdrawCheck(withdrawAmt);
        router.removeLiquidity(withdrawAmt);
        vm.stopPrank();

        // lp directly receives the tokens (vault.withdraw sends to lp address)
        (uint64 lpBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(lp)
        );
        assertEq(lpBal, withdrawAmt);
    }

    function test_FHEVault_Withdraw_InsufficientBalance_Reverts() public {
        // submitWithdrawCheck with LP_SEED+1 — encrypted balance check returns false
        vm.prank(lp);
        router.submitWithdrawCheck(LP_SEED + 1);

        vm.prank(address(router));
        vm.expectRevert("Insufficient shares");
        vault.withdraw(lp, LP_SEED + 1);
    }

    function test_FHEVault_Withdraw_LiquidityLocked_Reverts() public {
        // Open a position that reserves SIZE = 5_000e6
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);
        // available = LP_SEED - SIZE = 95_000e6 < LP_SEED
        // lpBalance[lp] = LP_SEED — passes balance check
        // but LP_SEED > available → fails liquidity check
        vm.prank(lp);
        router.submitWithdrawCheck(LP_SEED);

        vm.prank(address(router));
        vm.expectRevert("Liquidity locked");
        vault.withdraw(lp, LP_SEED);
    }

    function test_FHEVault_ReserveLiquidity_EncryptedReservedUpdated() public {
        vm.prank(address(pm));
        vault.reserveLiquidity(SIZE, address(this));

        (uint64 reserved, bool ok) = FHE.getDecryptResultSafe(vault.totalReserved());
        assertTrue(ok);
        assertEq(reserved, SIZE);
    }

    function test_FHEVault_ReserveLiquidity_Insufficient_Reverts() public {
        vm.prank(address(pm));
        vm.expectRevert("Insufficient vault liquidity");
        vault.reserveLiquidity(LP_SEED + 1, address(this));
    }

    function test_FHEVault_ReleaseLiquidity_EncryptedReservedDecreases() public {
        vm.prank(address(pm));
        vault.reserveLiquidity(SIZE, address(this));

        vm.prank(address(pm));
        vault.releaseLiquidity(SIZE);

        (uint64 reserved, ) = FHE.getDecryptResultSafe(vault.totalReserved());
        assertEq(reserved, 0);
    }

    function test_FHEVault_ReceiveLoss_EncryptedLiquidityIncreases() public {
        uint64 loss = uint64(200e6);
        vm.prank(address(pm));
        vault.receiveLoss(loss);

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED + loss);
    }

    // ======================================================================
    // SECTION 3 — FHERouter: full position lifecycle
    // ======================================================================

    function test_FHERouter_OpenPosition_Long_PositionExists() public {
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        bytes32 key = pm.getPositionKey(trader, ethToken, true);
        PositionManager.Position memory pos = pm.getPosition(key);

        assertTrue(pos.exists);
        assertEq(pos.owner, trader);

        // pos.size / pos.collateral are euint128 in PositionManager
        (uint128 decSize,  bool ok1) = FHE.getDecryptResultSafe(pos.size);
        (uint128 decCol,   bool ok2) = FHE.getDecryptResultSafe(pos.collateral);
        (bool    decLong,  bool ok3) = FHE.getDecryptResultSafe(pos.isLong);
        assertTrue(ok1 && ok2 && ok3);

        // values fit in uint64 range for 6-decimal token
        assertEq(uint64(decSize), SIZE);
        assertEq(uint64(decCol),  COLLATERAL);
        assertTrue(decLong);
    }

    function test_FHERouter_OpenPosition_CollateralMovedToVault() public {
        (uint64 beforeBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        (uint64 afterBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        assertEq(afterBal, beforeBal - COLLATERAL);
    }

    function test_FHERouter_OpenPosition_WrongToken_Reverts() public {
        address wrongToken = address(0xBAD);
        vm.prank(trader);
        vm.expectRevert("unsupported index token");
        router.openPosition(wrongToken, COLLATERAL, LEVERAGE, true);
    }

    function test_FHERouter_OpenPosition_NoOperator_Reverts() public {
        address newTrader = address(0x80);
        fheToken.mint(newTrader, COLLATERAL);
        // newTrader has NOT set router as operator

        vm.prank(newTrader);
        vm.expectRevert();  // FHERC20UnauthorizedSpender
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);
    }

    function test_FHERouter_ClosePosition_Profit_TraderReceivesPayout() public {
        // Open long at 2000
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        // Price rises 10 % → +PNL
        oracle.setPrice(ethToken, PRICE_UP);

        (uint64 balBefore, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        vm.prank(trader);
        router.closePosition(ethToken, true);
        // Finalize with proof (MockTaskManager accepts any signature).
        pm.finalizeClosePosition(trader, ethToken, true, uint256(COLLATERAL + PNL), "", uint256(SIZE), "", false, "");

        (uint64 balAfter, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        // Payout = COLLATERAL + PNL = 1_000e6 + 500e6 = 1_500e6
        assertEq(balAfter - balBefore, COLLATERAL + PNL);
    }

    function test_FHERouter_ClosePosition_Profit_VaultTokenBalanceDecreases() public {
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        // Vault holds LP_SEED (from LP) + COLLATERAL (from trader) in FHE token balance
        oracle.setPrice(ethToken, PRICE_UP);

        vm.prank(trader);
        router.closePosition(ethToken, true);
        pm.finalizeClosePosition(trader, ethToken, true, uint256(COLLATERAL + PNL), "", uint256(SIZE), "", false, "");

        // Vault paid out COLLATERAL + PNL to trader.
        // Remaining vault balance = LP_SEED + COLLATERAL - (COLLATERAL + PNL) = LP_SEED - PNL
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED - PNL);
    }

    function test_FHERouter_ClosePosition_Loss_TraderReceivesReducedPayout() public {
        // Open long at 2000
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        // Price falls 10 % → loss
        oracle.setPrice(ethToken, PRICE_DOWN);

        (uint64 balBefore, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        vm.prank(trader);
        router.closePosition(ethToken, true);
        pm.finalizeClosePosition(trader, ethToken, true, uint256(COLLATERAL - PNL), "", uint256(SIZE), "", false, "");

        (uint64 balAfter, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        // Payout = COLLATERAL - PNL = 1_000e6 - 500e6 = 500e6
        assertEq(balAfter - balBefore, COLLATERAL - PNL);
    }

    function test_FHERouter_ClosePosition_Loss_VaultTokenBalanceIncreases() public {
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        oracle.setPrice(ethToken, PRICE_DOWN);

        vm.prank(trader);
        router.closePosition(ethToken, true);
        pm.finalizeClosePosition(trader, ethToken, true, uint256(COLLATERAL - PNL), "", uint256(SIZE), "", false, "");

        // Vault received COLLATERAL on open, paid out (COLLATERAL - PNL) on close.
        // Net gain = PNL. Vault token balance = LP_SEED + PNL.
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED + PNL);
    }

    function test_FHERouter_ClosePosition_PositionDeleted() public {
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        oracle.setPrice(ethToken, PRICE_UP);

        vm.prank(trader);
        router.closePosition(ethToken, true);
        pm.finalizeClosePosition(trader, ethToken, true, uint256(COLLATERAL + PNL), "", uint256(SIZE), "", false, "");

        bytes32 key = pm.getPositionKey(trader, ethToken, true);
        assertFalse(pm.getPosition(key).exists);
    }

    function test_FHERouter_AddLiquidity_VaultEncryptedLiquidityGrows() public {
        uint64 extra = uint64(5_000e6);
        fheToken.mint(lp, extra);
        // lp already has operator set in setUp

        vm.prank(lp);
        router.addLiquidity(extra);

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED + extra);
    }

    function test_FHERouter_RemoveLiquidity_Works() public {
        uint64 withdrawAmt = uint64(10_000e6);

        vm.startPrank(lp);
        router.submitWithdrawCheck(withdrawAmt);
        router.removeLiquidity(withdrawAmt);
        vm.stopPrank();

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED - withdrawAmt);
    }

    // ======================================================================
    // SECTION 4 — Liquidation via LiquidationManager
    // ======================================================================

    function test_FHERouter_Liquidation_LiquidatorReceivesReward() public {
        // Open a 10x long — max leverage for liquidation scenario
        uint64 bigLeverage = 10;
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, bigLeverage, true);

        // Price drops 10 %: loss = (200e18 * 10_000e6) / 2_000e18 = 1_000e6 = 100% collateral
        oracle.setPrice(ethToken, PRICE_DOWN);

        vm.prank(liquidator);
        lm.liquidate(trader, ethToken, true);
        vm.prank(liquidator);
        lm.finalizeLiquidation(
            trader,
            ethToken,
            true,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            ""
        );

        // 5 % of COLLATERAL = 50e6
        uint64 expectedReward = uint64(COLLATERAL) * 5 / 100;

        (uint64 liqBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(liquidator)
        );
        assertEq(liqBal, expectedReward);
    }

    function test_FHERouter_Liquidation_PositionDeleted() public {
        uint64 bigLeverage = 10;
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, bigLeverage, true);

        oracle.setPrice(ethToken, PRICE_DOWN);

        vm.prank(liquidator);
        lm.liquidate(trader, ethToken, true);
        vm.prank(liquidator);
        lm.finalizeLiquidation(
            trader,
            ethToken,
            true,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            ""
        );

        bytes32 key = pm.getPositionKey(trader, ethToken, true);
        assertFalse(pm.getPosition(key).exists);
    }

    function test_FHERouter_Liquidation_NotLiquidatable_Reverts() public {
        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        // Price unchanged — position not liquidatable
        vm.prank(liquidator);
        lm.liquidate(trader, ethToken, true);

        vm.prank(liquidator);
        vm.expectRevert("not liquidatable");
        lm.finalizeLiquidation(
            trader,
            ethToken,
            true,
            false,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(LEVERAGE),
            ""
        );
    }

    // ======================================================================
    // SECTION 5 — Privacy sanity checks
    // ======================================================================

    function test_FHEVault_TotalLiquidity_IsEncrypted_NotPlaintext() public {
        // The vault does NOT expose a plaintext totalLiquidity()
        // (unlike Vault which has uint256 public totalLiquidity)
        // Verify the returned type is euint64 (bytes32 handle, never a raw uint256 slot)
        euint64 encLiq = vault.totalLiquidity();
        // In mock: handle == plaintext; in production handle is a ciphertext hash
        (uint64 val, bool ok) = FHE.getDecryptResultSafe(encLiq);
        assertTrue(ok);
        assertEq(val, LP_SEED);

        // Confirm there is no public uint256 totalLiquidity that leaks the value
        // (this is a compile-time guarantee — the function returns euint64, not uint256)
    }

    function test_FHEVault_LPBalance_IsEncrypted() public {
        euint64 encBal = vault.lpBalance(lp);
        (uint64 val, bool ok) = FHE.getDecryptResultSafe(encBal);
        assertTrue(ok);
        assertEq(val, LP_SEED);
    }

    // ======================================================================
    // SECTION 6 — FHERouter: setActionFee
    // ======================================================================

    function test_FHERouter_SetActionFee_UpdatesState() public {
        uint256 fee = 0.01 ether;
        router.setActionFee(fee);
        assertEq(router.actionFee(), fee);
    }

    function test_FHERouter_SetActionFee_EmitsEvent() public {
        uint256 fee = 0.005 ether;
        vm.expectEmit(false, false, false, true);
        emit FHERouter.ActionFeeSet(fee);
        router.setActionFee(fee);
    }

    function test_FHERouter_SetActionFee_CanBeSetToZero() public {
        router.setActionFee(0.01 ether);
        router.setActionFee(0);
        assertEq(router.actionFee(), 0);
    }

    function test_FHERouter_SetActionFee_Revert_NotOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("Not owner");
        router.setActionFee(0.01 ether);
    }

    function test_FHERouter_SetActionFee_EnforcedOnOpenPosition() public {
        uint256 fee = 0.01 ether;
        router.setActionFee(fee);

        vm.prank(trader);
        vm.expectRevert("Insufficient ETH fee");
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        vm.deal(trader, fee);
        vm.prank(trader);
        router.openPosition{value: fee}(ethToken, COLLATERAL, LEVERAGE, true);
    }

    function test_FHERouter_SetActionFee_EnforcedOnClosePosition() public {
        uint256 fee = 0.01 ether;

        vm.prank(trader);
        router.openPosition(ethToken, COLLATERAL, LEVERAGE, true);

        router.setActionFee(fee);

        vm.prank(trader);
        vm.expectRevert("Insufficient ETH fee");
        router.closePosition(ethToken, true);

        vm.deal(trader, fee);
        vm.prank(trader);
        router.closePosition{value: fee}(ethToken, true);
    }

    function test_FHERouter_SetActionFee_AccumulatesCollectedFees() public {
        uint256 fee = 0.01 ether;
        router.setActionFee(fee);

        vm.deal(trader, fee);
        vm.prank(trader);
        router.openPosition{value: fee}(ethToken, COLLATERAL, LEVERAGE, true);

        assertEq(router.collectedFees(), fee);
    }

    function test_FHERouter_SetActionFee_AccumulatesAcrossMultipleActions() public {
        uint256 fee = 0.01 ether;
        router.setActionFee(fee);

        vm.deal(trader, fee * 2);
        vm.prank(trader);
        router.openPosition{value: fee}(ethToken, COLLATERAL, LEVERAGE, true);

        vm.prank(trader);
        router.closePosition{value: fee}(ethToken, true);

        assertEq(router.collectedFees(), fee * 2);
    }
}
