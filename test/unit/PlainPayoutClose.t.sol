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
 * @title PlainPayoutCloseTest
 * @notice Tests for the plain-ERC-20 payout path on position close.
 *
 * Flow (now fully atomic):
 *   1. user  → router.requestClosePlainPayout(posId)
 *   2. owner → router.finalizeClosePlainPayout(posId, finalAmount, ...)
 *              └─ pm.finalizeClosePositionPlain(...)
 *                 └─ vault.payTraderPlain(trader, profit, collateral)
 *                    ├─ burns `finalAmount` encrypted from vault's own balance
 *                    └─ transfers `finalAmount` underlying ERC-20 directly to trader
 *
 * Plain-open → plain-close: underlying deposited to vault on open funds the payout.
 * Encrypted-open → plain-close: vault must hold underlying reserve (from prior plain-opens
 *   or admin deposit); otherwise finalizeClosePlainPayout reverts — no limbo state.
 */
contract PlainPayoutCloseTest is Test {
    address constant TASK_MANAGER_ADDR = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    // ── contracts ─────────────────────────────────────────────────────────
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

    // ── accounts ──────────────────────────────────────────────────────────
    address owner       = address(this);
    address lp          = address(0x10);
    address encTrader   = address(0x20); // opens via encrypted path
    address plainTrader = address(0x40); // opens via plain path

    address ethToken;

    // ── amount constants ──────────────────────────────────────────────────
    uint64 constant LP_SEED    = 100_000e6;
    uint64 constant COLLATERAL = 1_000e6;
    uint64 constant LEVERAGE   = 5;
    uint64 constant SIZE       = COLLATERAL * LEVERAGE;
    uint64 constant PNL        = 500e6;

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

        fheToken.mint(lp, LP_SEED);
        vm.prank(lp);
        fheToken.setOperator(address(router), type(uint48).max);
        vm.prank(lp);
        router.addLiquidity(_enc64(LP_SEED));

        fheToken.mint(encTrader, COLLATERAL * 10);
        vm.prank(encTrader);
        fheToken.setOperator(address(router), type(uint48).max);

        underlying.mint(plainTrader, COLLATERAL * 10);
    }

    // ── encoding helpers ──────────────────────────────────────────────────

    function _enc64(uint256 v) internal pure returns (InEuint64 memory) {
        return InEuint64({ ctHash: v, securityZone: 0, utype: 5, signature: "" });
    }

    function _encBool(bool v) internal pure returns (InEbool memory) {
        return InEbool({ ctHash: v ? 1 : 0, securityZone: 0, utype: 0, signature: "" });
    }

    // ── position helpers ──────────────────────────────────────────────────

    function _openEncrypted(address t, bool isLong) internal {
        vm.prank(t);
        router.submitDecryptTaskForOpen(ethToken, _enc64(COLLATERAL), _enc64(LEVERAGE), _encBool(isLong));
        vm.prank(t);
        lastPosId = router.openPosition(
            ethToken, _enc64(COLLATERAL), _enc64(LEVERAGE), _encBool(isLong), true, ""
        );
    }

    function _openPlain(address t, bool isLong) internal {
        vm.prank(t);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(t);
        fheToken.setOperator(address(router), type(uint48).max);
        vm.prank(t);
        router.submitOpenPositionCheckPlain(ethToken, COLLATERAL, _enc64(LEVERAGE), _encBool(isLong));
        vm.prank(t);
        lastPosId = router.finalizeOpenPositionPlain(ethToken, true, "");
    }

    /// Request close + finalize. After this call the trader already holds their plain ERC-20.
    function _closePlain(address t, bytes32 posId, uint64 finalAmt) internal {
        vm.prank(t);
        router.requestClosePlainPayout(posId);
        router.finalizeClosePlainPayout(
            posId, uint256(finalAmt), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    /// Close via standard encrypted path (no plain payout).
    function _closeEncrypted(address t, bytes32 posId, uint64 finalAmt) internal {
        vm.prank(t);
        router.requestClosePosition(posId);
        pm.finalizeClosePosition(
            posId, uint256(finalAmt), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    // ======================================================================
    // SECTION 1 — requestClosePlainPayout
    // ======================================================================

    function test_PlainClose_RequestSetsFlag() public {
        _openEncrypted(encTrader, true);
        assertFalse(router.plainPayoutRequested(lastPosId));

        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        assertTrue(router.plainPayoutRequested(lastPosId));
    }

    function test_PlainClose_RequestEmitsCloseEvent() public {
        _openEncrypted(encTrader, true);

        vm.prank(encTrader);
        vm.expectEmit(true, true, false, false);
        emit FHERouter.ClosePosition(lastPosId, encTrader);
        router.requestClosePlainPayout(lastPosId);
    }

    function test_PlainClose_RequestEmitsPlainPayoutRequestedEvent() public {
        _openEncrypted(encTrader, true);

        vm.prank(encTrader);
        vm.expectEmit(true, true, false, false);
        emit FHERouter.PlainPayoutRequested(lastPosId, encTrader);
        router.requestClosePlainPayout(lastPosId);
    }

    // ======================================================================
    // SECTION 2 — finalizeClosePlainPayout guards
    // ======================================================================

    function test_PlainClose_FinalizeClosePlainPayout_NonOwner_Reverts() public {
        _openEncrypted(encTrader, true);
        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        vm.prank(encTrader);
        vm.expectRevert("Not owner");
        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    function test_PlainClose_FinalizeClosePlainPayout_WithoutFlag_Reverts() public {
        _openEncrypted(encTrader, true);

        vm.expectRevert("not a plain payout position");
        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    function test_PlainClose_FinalizeClosePlainPayout_ClearsFlag() public {
        _openEncrypted(encTrader, true);
        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        // Fund vault so the payout can complete.
        underlying.mint(address(vault), COLLATERAL);

        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );

        assertFalse(router.plainPayoutRequested(lastPosId));
    }

    function test_PlainClose_FinalizeClosePlainPayout_TraderReceivesUnderlying() public {
        _openEncrypted(encTrader, true);
        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        underlying.mint(address(vault), COLLATERAL);

        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );

        assertEq(underlying.balanceOf(encTrader), COLLATERAL);
    }

    function test_PlainClose_InsufficientReserve_Reverts() public {
        // Vault has no underlying — finalizeClosePlainPayout must revert before any state change.
        _openEncrypted(encTrader, true);
        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        vm.expectRevert("insufficient underlying reserve");
        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );

        // Position must still exist — no limbo state.
        assertTrue(pm.positionExists(lastPosId));
    }

    // ======================================================================
    // SECTION 3 — Encrypted open → plain close (mixed path)
    // ======================================================================

    function test_PlainClose_EncOpen_BreakEven_TraderReceivesPlain() public {
        _openEncrypted(encTrader, true);
        underlying.mint(address(vault), COLLATERAL);
        _closePlain(encTrader, lastPosId, COLLATERAL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL);
    }

    function test_PlainClose_EncOpen_BreakEven_VaultUnderlyingDepleted() public {
        _openEncrypted(encTrader, true);
        underlying.mint(address(vault), COLLATERAL);
        _closePlain(encTrader, lastPosId, COLLATERAL);

        assertEq(underlying.balanceOf(address(vault)), 0);
    }

    function test_PlainClose_EncOpen_BreakEven_EncryptedBalanceDecreasedByCollateral() public {
        (uint64 balBefore, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(encTrader));

        _openEncrypted(encTrader, true);
        underlying.mint(address(vault), COLLATERAL);
        _closePlain(encTrader, lastPosId, COLLATERAL);

        (uint64 balAfter, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(encTrader));
        // Open transferred COLLATERAL encrypted → vault.  payTraderPlain burned it from vault
        // (not from trader).  Net change on trader's encrypted balance = −COLLATERAL (open only).
        assertEq(balBefore - balAfter, COLLATERAL);
    }

    function test_PlainClose_EncOpen_Profit_TraderReceivesPlain() public {
        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_UP);
        underlying.mint(address(vault), COLLATERAL + PNL);
        _closePlain(encTrader, lastPosId, COLLATERAL + PNL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL + PNL);
    }

    function test_PlainClose_EncOpen_Loss_TraderReceivesReducedPlain() public {
        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_DOWN);
        underlying.mint(address(vault), COLLATERAL - PNL);
        _closePlain(encTrader, lastPosId, COLLATERAL - PNL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL - PNL);
    }

    function test_PlainClose_EncOpen_PositionDeletedAfterClose() public {
        _openEncrypted(encTrader, true);
        underlying.mint(address(vault), COLLATERAL);
        _closePlain(encTrader, lastPosId, COLLATERAL);

        assertFalse(pm.positionExists(lastPosId));
    }

    function test_PlainClose_EncOpen_EmitsPlainPayoutSettled() public {
        _openEncrypted(encTrader, true);
        underlying.mint(address(vault), COLLATERAL);

        vm.prank(encTrader);
        router.requestClosePlainPayout(lastPosId);

        vm.expectEmit(true, true, false, true);
        emit FHERouter.PlainPayoutSettled(lastPosId, encTrader, COLLATERAL);
        router.finalizeClosePlainPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    // ======================================================================
    // SECTION 4 — Plain open → plain close (full plain lifecycle)
    // ======================================================================

    function test_PlainClose_PlainOpen_BreakEven_TraderReceivesOriginalPlain() public {
        // Plain open deposits COLLATERAL underlying to vault; close returns it.
        _openPlain(plainTrader, true);
        _closePlain(plainTrader, lastPosId, COLLATERAL);

        // Started with COLLATERAL*10, spent COLLATERAL on open, got it back.
        assertEq(underlying.balanceOf(plainTrader), COLLATERAL * 10);
    }

    function test_PlainClose_PlainOpen_Profit_TraderReceivesMorePlain() public {
        _openPlain(plainTrader, true);
        oracle.setPrice(ethToken, PRICE_UP);
        // LP vault funds the extra profit.
        underlying.mint(address(vault), PNL);
        _closePlain(plainTrader, lastPosId, COLLATERAL + PNL);

        uint256 net = underlying.balanceOf(plainTrader) - (COLLATERAL * 10 - COLLATERAL);
        assertEq(net, COLLATERAL + PNL);
    }

    function test_PlainClose_PlainOpen_Loss_TraderReceivesLessPlain() public {
        _openPlain(plainTrader, true);
        oracle.setPrice(ethToken, PRICE_DOWN);
        _closePlain(plainTrader, lastPosId, COLLATERAL - PNL);

        uint256 net = underlying.balanceOf(plainTrader) - (COLLATERAL * 10 - COLLATERAL);
        assertEq(net, COLLATERAL - PNL);
    }

    function test_PlainClose_PlainOpen_PositionDeletedAfterClose() public {
        _openPlain(plainTrader, true);
        _closePlain(plainTrader, lastPosId, COLLATERAL);
        assertFalse(pm.positionExists(lastPosId));
    }

    function test_PlainClose_PlainOpen_VaultUnderlyingDepletedAfterClose() public {
        // Underlying from plain-open goes to vault; plain-close sends it to trader.
        _openPlain(plainTrader, true);
        _closePlain(plainTrader, lastPosId, COLLATERAL);

        assertEq(underlying.balanceOf(address(vault)), 0);
    }

    function test_PlainClose_PlainOpen_EncryptedBalanceZeroAfterClose() public {
        // plainTrader never holds encrypted tokens outside of the brief Phase 1→2 window.
        _openPlain(plainTrader, true);
        _closePlain(plainTrader, lastPosId, COLLATERAL);

        (uint64 encBal, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(plainTrader));
        assertEq(encBal, 0);
    }

    // ======================================================================
    // SECTION 5 — Standard encrypted close still works (independent path)
    // ======================================================================

    function test_PlainClose_StandardClose_StillPaysEncrypted() public {
        (uint64 balBefore, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(encTrader));

        _openEncrypted(encTrader, true);
        oracle.setPrice(ethToken, PRICE_UP);
        _closeEncrypted(encTrader, lastPosId, COLLATERAL + PNL);

        (uint64 balAfter, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(encTrader));
        assertEq(balAfter - balBefore, PNL);
    }

    function test_PlainClose_PlainOpen_EncryptedClose_TraderReceivesEncrypted() public {
        // Plain open → encrypted close: trader gets encrypted payout (not underlying).
        _openPlain(plainTrader, true);
        oracle.setPrice(ethToken, PRICE_UP);

        vm.prank(plainTrader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(
            lastPosId,
            uint256(COLLATERAL + PNL), "",
            uint256(SIZE),             "",
            uint256(COLLATERAL),       "",
            true
        );

        (uint64 encBal, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(plainTrader));
        assertEq(encBal, COLLATERAL + PNL);
    }

    // ======================================================================
    // SECTION 6 — Plain open → encrypted-close (dedicated wrapped path)
    //
    // requestCloseEncryptedPayout → finalizeCloseEncryptedPayout
    //   vault.payTraderWrapped: burns vault encrypted + wraps fresh encrypted to trader
    //   Underlying stays in vault as reserve; encrypted supply stays balanced.
    // ======================================================================

    /// Helper: request + finalize encrypted payout in one call.
    function _closeEncryptedPayout(address t, bytes32 posId, uint64 finalAmt) internal {
        vm.prank(t);
        router.requestCloseEncryptedPayout(posId);
        router.finalizeCloseEncryptedPayout(
            posId, uint256(finalAmt), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    function test_EncPayout_RequestSetsFlag() public {
        _openPlain(plainTrader, true);
        assertFalse(router.encryptedPayoutRequested(lastPosId));

        vm.prank(plainTrader);
        router.requestCloseEncryptedPayout(lastPosId);

        assertTrue(router.encryptedPayoutRequested(lastPosId));
    }

    function test_EncPayout_RequestEmitsEvent() public {
        _openPlain(plainTrader, true);

        vm.prank(plainTrader);
        vm.expectEmit(true, true, false, false);
        emit FHERouter.EncryptedPayoutRequested(lastPosId, plainTrader);
        router.requestCloseEncryptedPayout(lastPosId);
    }

    function test_EncPayout_NonOwnerFinalize_Reverts() public {
        _openPlain(plainTrader, true);
        vm.prank(plainTrader);
        router.requestCloseEncryptedPayout(lastPosId);

        vm.prank(plainTrader);
        vm.expectRevert("Not owner");
        router.finalizeCloseEncryptedPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    function test_EncPayout_WithoutFlag_Reverts() public {
        _openPlain(plainTrader, true);

        vm.expectRevert("not an encrypted payout position");
        router.finalizeCloseEncryptedPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    function test_EncPayout_PlainOpen_BreakEven_TraderReceivesEncrypted() public {
        _openPlain(plainTrader, true);
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL);

        (uint64 encBal, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(plainTrader));
        assertEq(encBal, COLLATERAL);
    }

    function test_EncPayout_PlainOpen_Profit_TraderReceivesMoreEncrypted() public {
        _openPlain(plainTrader, true);
        oracle.setPrice(ethToken, PRICE_UP);
        // LP side funds the extra encrypted (vault mints more than collateral).
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL + PNL);

        (uint64 encBal, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(plainTrader));
        assertEq(encBal, COLLATERAL + PNL);
    }

    function test_EncPayout_PlainOpen_Loss_TraderReceivesLessEncrypted() public {
        _openPlain(plainTrader, true);
        oracle.setPrice(ethToken, PRICE_DOWN);
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL - PNL);

        (uint64 encBal, ) = FHE.getDecryptResultSafe(fheToken.confidentialBalanceOf(plainTrader));
        assertEq(encBal, COLLATERAL - PNL);
    }

    function test_EncPayout_PlainOpen_PositionDeleted() public {
        _openPlain(plainTrader, true);
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL);
        assertFalse(pm.positionExists(lastPosId));
    }

    function test_EncPayout_PlainOpen_VaultUnderlyingPreservedAsReserve() public {
        // Underlying from plain-open stays in vault — available for future plain payouts.
        _openPlain(plainTrader, true);
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL);

        assertEq(underlying.balanceOf(address(vault)), COLLATERAL);
    }

    function test_EncPayout_PlainOpen_FlagClearedAfterFinalize() public {
        _openPlain(plainTrader, true);
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL);
        assertFalse(router.encryptedPayoutRequested(lastPosId));
    }

    function test_EncPayout_PlainOpen_EmitsEncryptedPayoutSettled() public {
        _openPlain(plainTrader, true);

        vm.prank(plainTrader);
        router.requestCloseEncryptedPayout(lastPosId);

        vm.expectEmit(true, true, false, true);
        emit FHERouter.EncryptedPayoutSettled(lastPosId, plainTrader, COLLATERAL);
        router.finalizeCloseEncryptedPayout(
            lastPosId, uint256(COLLATERAL), "", uint256(SIZE), "", uint256(COLLATERAL), "", true
        );
    }

    function test_EncPayout_VaultUnderlyingFundsSubsequentPlainPayout() public {
        // Plain-open trader closes via encrypted-payout → underlying stays in vault.
        // A second encrypted-open trader can then do a plain-close using that reserve.
        _openPlain(plainTrader, true);
        _closeEncryptedPayout(plainTrader, lastPosId, COLLATERAL);
        // Vault now holds COLLATERAL underlying as reserve.

        // Second trader opens encrypted and closes for plain.
        _openEncrypted(encTrader, true);
        _closePlain(encTrader, lastPosId, COLLATERAL);

        assertEq(underlying.balanceOf(encTrader), COLLATERAL);
        assertEq(underlying.balanceOf(address(vault)), 0);
    }
}
