// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { FHE, euint64, InEuint64, InEuint128 } from "cofhe-contracts/FHE.sol";

import "../../src/core/FHEVault.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/FHEFundingRateManager.sol";

import "../../src/trading/FHERouter.sol";
import "../../src/trading/FHEOrderManager.sol";
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
 *   - publishDecryptResult(...) → no-op (always succeeds).
 *   - isAllowed(...)         → always true.
 *   So all euint64 handles equal their plaintext values, enabling
 *   assertEq on decrypted results.
 *
 * Proof conventions in tests:
 *   Since MockTaskManager's publishDecryptResult is a no-op, the plaintext
 *   values passed to openPosition / removeLiquidity are used directly by the
 *   require checks. Tests pass the expected boolean that reflects the actual
 *   FHE computation result (true = check passes, false = check fails).
 *
 * Operator note:
 *   FHERC20 replaces approve/allowance with time-bounded operators.
 *   Each user must call fheToken.setOperator(router, until) before
 *   any confidentialTransferFrom. Tests set until = type(uint48).max.
 */
contract FHEPoolTest is Test {
    function getPosId(address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), uint256(0)));
    }


    address constant TASK_MANAGER_ADDR = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    // ── contracts ─────────────────────────────────────────────────────────
    MockFHEToken       fheToken;
    FHEVault           vault;
    PositionManager    pm;
    LiquidationManager lm;
    FHEFundingRateManager fheFRM;    FHEOrderManager    om;
    FHERouter          router;
    PriceOracle        oracle;

    /// Last position ID returned by openPositionFHE — used in finalize calls.
    bytes32 lastPosId;

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
        vm.etch(TASK_MANAGER_ADDR, address(new MockTaskManager()).code);

        // ETH index token (address used for oracle prices + position keys)
        ethToken = address(0xE7);

        // Deploy FHE token (6 decimals to stay within euint64 range)
        fheToken = new MockFHEToken("Encrypted USDC", "eUSDC");

        oracle = new PriceOracle();
        fheFRM = new FHEFundingRateManager();
        vault  = new FHEVault(address(fheToken), owner);
        pm     = new PositionManager(address(vault), address(oracle));
        lm     = new LiquidationManager(address(pm), address(fheFRM));
        om     = new FHEOrderManager(address(oracle), address(fheFRM), owner);
        router = new FHERouter(
            address(pm),
            address(vault),
            address(om),
            address(fheFRM),
            address(fheToken),
            ethToken
        );

        // Wire contracts
        vault.setPositionManager(address(pm));
        vault.setRouter(address(router));
        pm.setRouter(address(router));
        pm.setFheRouter(address(router));
        pm.setLiquidationManager(address(lm));
        pm.setFinalizer(address(this)); // test contract acts as trusted finalizer
        
        pm.setFHEFundingManager(address(fheFRM));
        fheFRM.setPositionManager(address(pm));
        fheFRM.initializeToken(ethToken);
        om.setRouter(address(router));

        oracle.setPrice(ethToken, PRICE_ENTRY);

        // Seed LP liquidity
        fheToken.mint(lp, LP_SEED);
        vm.prank(lp);
        fheToken.setOperator(address(router), type(uint48).max);
        vm.prank(lp);
        router.addLiquidity(mockInEuint64(LP_SEED));

        // Fund trader
        fheToken.mint(trader, COLLATERAL * 10);
        vm.prank(trader);
        fheToken.setOperator(address(router), type(uint48).max);
    }



    function mockInEbool(bool value) public pure returns (InEbool memory) {
        return InEbool({ctHash: uint256(value ? 1 : 0), securityZone: 0, utype: 0, signature: bytes('')});
    }

    function mockInEuint64(uint256 val) internal pure returns (InEuint64 memory) {
        return InEuint64({
            ctHash: val,
            securityZone: 0,
            utype: 5,
            signature: ""
        });
    }

    function mockInEuint128(uint256 val) internal pure returns (InEuint128 memory) {
        return InEuint128({
            ctHash: val,
            securityZone: 0,
            utype: 6,
            signature: ""
        });
    }
    // ── helper: open a position via the full three-phase flow ──────────────

    function _openPosition(address _trader, address token, uint256 col, uint256 lev, bool isLong) internal {
        vm.prank(_trader);
        router.submitDecryptTaskForOpen(token, mockInEuint64(col), mockInEuint64(uint64(lev)), mockInEbool(true));
        vm.prank(_trader);
        lastPosId = router.openPosition(token, mockInEuint64(col), mockInEuint64(uint64(lev)), mockInEbool(isLong),  true, "");
    }


    // ── helper: remove liquidity via the full two-phase flow ──────────────

    function _removeLiquidity(address _lp, uint256 shares) internal {
        vm.prank(_lp);
        router.submitWithdrawCheck(shares);
        vm.prank(_lp);
        router.removeLiquidity(shares, true, "", true, "");
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
        _removeLiquidity(lp, withdrawAmt);

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED - withdrawAmt);
    }

    function test_FHEVault_Withdraw_TransfersTokensToLP() public {
        uint64 withdrawAmt = uint64(10_000e6);
        _removeLiquidity(lp, withdrawAmt);

        // lp directly receives the tokens via vault.withdrawWithProof
        (uint64 lpBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(lp)
        );
        assertEq(lpBal, withdrawAmt);
    }

    function test_FHEVault_Withdraw_InsufficientBalance_Reverts() public {
        // submitWithdrawCheck with LP_SEED+1 — encrypted balance check returns false
        vm.prank(lp);
        router.submitWithdrawCheck(LP_SEED + 1);

        // Pass balPlain=false to simulate insufficient balance (LP_SEED+1 > lpBalance[lp])
        vm.prank(lp);
        vm.expectRevert("Insufficient shares");
        router.removeLiquidity(LP_SEED + 1, false, "", true, "");
    }

    function test_FHEVault_Withdraw_LiquidityLocked_Reverts() public {
        // Open a position that reserves SIZE = 5_000e6
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        // available = LP_SEED - SIZE = 95_000e6
        // LP_SEED (100_000e6) > available — fails liquidity check, passes balance check
        vm.prank(lp);
        router.submitWithdrawCheck(LP_SEED);

        vm.prank(lp);
        vm.expectRevert("Liquidity locked");
        router.removeLiquidity(LP_SEED, true, "", false, "");
    }

    function test_FHEVault_ReserveLiquidity_EncryptedReservedUpdated() public {
        // Go through the full three-phase flow via router
        euint64 e_size = FHE.asEuint64(SIZE);
        vm.prank(address(router));
        vault.submitReserveLiquidityCheck(address(pm), e_size);

        vm.prank(address(router));
        vault.storeReserveLiquidityProof(address(pm), true, "");

        vm.prank(address(pm));
        vault.reserveLiquidity(address(pm));

        (uint64 reserved, bool ok) = FHE.getDecryptResultSafe(vault.totalReserved());
        assertTrue(ok);
        assertEq(reserved, SIZE);
    }

    function test_FHEVault_ReserveLiquidity_Insufficient_Reverts() public {
        // Simulate the FHE check returning false (insufficient liquidity)
        euint64 e_size = FHE.asEuint64(LP_SEED + 1);
        vm.prank(address(router));
        vault.submitReserveLiquidityCheck(address(pm), e_size);

        vm.prank(address(router));
        vault.storeReserveLiquidityProof(address(pm), false, ""); // false = insufficient

        vm.prank(address(pm));
        vm.expectRevert("Insufficient vault liquidity");
        vault.reserveLiquidity(address(pm));
    }

    function test_FHEVault_ReleaseLiquidity_EncryptedReservedDecreases() public {
        euint64 e_size = FHE.asEuint64(SIZE);
        vm.prank(address(router));
        vault.submitReserveLiquidityCheck(trader, e_size);
        vm.prank(address(router));
        vault.storeReserveLiquidityProof(trader, true, "");

        vm.prank(address(pm));
        vault.reserveLiquidity(trader);

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
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        vm.prank(trader);
        PositionManager.Position memory pos = pm.getMyPosition(lastPosId);

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

        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        (uint64 afterBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        assertEq(afterBal, beforeBal - COLLATERAL);
    }

    function test_FHERouter_OpenPosition_WrongToken_Reverts() public {
        address wrongToken = address(0xBAD);
        vm.prank(trader);
        vm.expectRevert("unsupported index token");
        router.submitDecryptTaskForOpen(wrongToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));
    }

    function test_FHERouter_OpenPosition_NoOperator_Reverts() public {
        address newTrader = address(0x80);
        fheToken.mint(newTrader, COLLATERAL);
        // newTrader has NOT set router as operator

        vm.prank(newTrader);
        router.submitDecryptTaskForOpen(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));

        vm.prank(newTrader);
        vm.expectRevert();  // FHERC20UnauthorizedSpender
        router.openPosition(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");
    }

    function test_FHERouter_OpenPosition_MissingSubmit_Reverts() public {
        // openPosition without a prior submitDecryptTaskForOpen must revert
        vm.prank(trader);
        vm.expectRevert("no pending check");
        router.openPosition(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");
    }

    function test_FHERouter_ClosePosition_Profit_TraderReceivesPayout() public {
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        // Price rises 10 % → +PNL
        oracle.setPrice(ethToken, PRICE_UP);

        (uint64 balBefore, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        vm.prank(trader);
        router.closePosition(lastPosId);
        // Finalize with proof (MockTaskManager accepts any signature).
        pm.finalizeClosePosition(lastPosId, uint256(COLLATERAL + PNL), "", uint256(SIZE), "", true);

        (uint64 balAfter, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        // Payout = COLLATERAL + PNL = 1_000e6 + 500e6 = 1_500e6
        assertEq(balAfter - balBefore, COLLATERAL + PNL);
    }

    function test_FHERouter_ClosePosition_Profit_VaultTokenBalanceDecreases() public {
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        // Vault holds LP_SEED (from LP) + COLLATERAL (from trader) in FHE token balance
        oracle.setPrice(ethToken, PRICE_UP);

        vm.prank(trader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(lastPosId, uint256(COLLATERAL + PNL), "", uint256(SIZE), "", true);

        // Vault paid out COLLATERAL + PNL to trader.
        // Remaining vault balance = LP_SEED + COLLATERAL - (COLLATERAL + PNL) = LP_SEED - PNL
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED - PNL);
    }

    function test_FHERouter_ClosePosition_Loss_TraderReceivesReducedPayout() public {
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        // Price falls 10 % → loss
        oracle.setPrice(ethToken, PRICE_DOWN);

        (uint64 balBefore, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        vm.prank(trader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(lastPosId, uint256(COLLATERAL - PNL), "", uint256(SIZE), "", true);

        (uint64 balAfter, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(trader)
        );

        // Payout = COLLATERAL - PNL = 1_000e6 - 500e6 = 500e6
        assertEq(balAfter - balBefore, COLLATERAL - PNL);
    }

    function test_FHERouter_ClosePosition_Loss_VaultTokenBalanceIncreases() public {
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        oracle.setPrice(ethToken, PRICE_DOWN);

        vm.prank(trader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(lastPosId, uint256(COLLATERAL - PNL), "", uint256(SIZE), "", true);

        // Vault received COLLATERAL on open, paid out (COLLATERAL - PNL) on close.
        // Net gain = PNL. Vault token balance = LP_SEED + PNL.
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED + PNL);
    }

    function test_FHERouter_ClosePosition_PositionDeleted() public {
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        oracle.setPrice(ethToken, PRICE_UP);

        vm.prank(trader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(lastPosId, uint256(COLLATERAL + PNL), "", uint256(SIZE), "", true);

        assertFalse(pm.positionExists(lastPosId));
    }

    function test_FHERouter_AddLiquidity_VaultEncryptedLiquidityGrows() public {
        uint64 extra = uint64(5_000e6);
        fheToken.mint(lp, extra);
        // lp already has operator set in setUp

        vm.prank(lp);
        router.addLiquidity(mockInEuint64(extra));

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED + extra);
    }

    function test_FHERouter_RemoveLiquidity_Works() public {
        uint64 withdrawAmt = uint64(10_000e6);
        _removeLiquidity(lp, withdrawAmt);

        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED - withdrawAmt);
    }

    // ======================================================================
    // SECTION 4 — Liquidation via LiquidationManager
    // ======================================================================

    function test_FHERouter_Liquidation_LiquidatorReceivesReward() public {
        // Open a 10x long — max leverage for liquidation scenario
        uint64 bigLeverage = 10;
        _openPosition(trader, ethToken, COLLATERAL, bigLeverage, true);

        // Price drops 10 %: loss = (200e18 * 10_000e6) / 2_000e18 = 1_000e6 = 100% collateral
        oracle.setPrice(ethToken, PRICE_DOWN);

        vm.prank(liquidator);
        lm.liquidate(lastPosId, ethToken);
        vm.prank(liquidator);
        lm.finalizeLiquidation(
            lastPosId,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            "",
            true
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
        _openPosition(trader, ethToken, COLLATERAL, bigLeverage, true);

        oracle.setPrice(ethToken, PRICE_DOWN);

        vm.prank(liquidator);
        lm.liquidate(lastPosId, ethToken);
        vm.prank(liquidator);
        lm.finalizeLiquidation(
            lastPosId,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            "",
            true
        );

        assertFalse(pm.positionExists(lastPosId));
    }

    function test_FHERouter_Liquidation_NotLiquidatable_Reverts() public {
        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        // Price unchanged — position not liquidatable
        vm.prank(liquidator);
        lm.liquidate(lastPosId, ethToken);

        vm.prank(liquidator);
        vm.expectRevert("not liquidatable");
        lm.finalizeLiquidation(
            lastPosId,
            false,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(LEVERAGE),
            "",
            true
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
        router.submitDecryptTaskForOpen(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));

        vm.prank(trader);
        vm.expectRevert("Insufficient ETH fee");
        router.openPosition(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");

        vm.deal(trader, fee);
        vm.prank(trader);
        lastPosId = router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");
    }

    function test_FHERouter_SetActionFee_EnforcedOnClosePosition() public {
        uint256 fee = 0.01 ether;

        _openPosition(trader, ethToken, COLLATERAL, LEVERAGE, true);

        router.setActionFee(fee);

        vm.prank(trader);
        vm.expectRevert("Insufficient ETH fee");
        router.closePosition(lastPosId);

        vm.deal(trader, fee);
        vm.prank(trader);
        router.closePosition{value: fee}(lastPosId);
    }

    function test_FHERouter_SetActionFee_AccumulatesCollectedFees() public {
        uint256 fee = 0.01 ether;
        router.setActionFee(fee);

        vm.prank(trader);
        router.submitDecryptTaskForOpen(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));

        vm.deal(trader, fee);
        vm.prank(trader);
        lastPosId = router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");

        assertEq(router.collectedFees(), fee);
    }

    function test_FHERouter_SetActionFee_AccumulatesAcrossMultipleActions() public {
        uint256 fee = 0.01 ether;
        router.setActionFee(fee);

        vm.prank(trader);
        router.submitDecryptTaskForOpen(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));

        vm.deal(trader, fee * 2);
        vm.prank(trader);
        lastPosId = router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");

        vm.prank(trader);
        router.closePosition{value: fee}(lastPosId);

        assertEq(router.collectedFees(), fee * 2);
    }
}
