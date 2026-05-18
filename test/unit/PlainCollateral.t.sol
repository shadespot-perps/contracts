// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { FHE, euint64, InEuint64, ebool, InEbool } from "cofhe-contracts/FHE.sol";
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

/**
 * @title MockPlainERC20
 * @notice Minimal plain ERC-20 used as the underlying collateral token.
 *         Represents what the user holds before wrapping into the encrypted token.
 */
contract MockPlainERC20 is ERC20 {
    constructor() ERC20("Plain USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title PlainCollateralTest
 * @notice Tests for the plain-collateral open-position path introduced in FHERouter.
 *
 * Plain path flow:
 *   1. User approves router on the underlying ERC-20.
 *   2. User sets router as operator on the encrypted token (for Phase 2 transferFrom).
 *   3. submitOpenPositionCheckPlain  — router pulls underlying, wraps to encrypted,
 *                                      stores handles, submits vault liquidity check.
 *   4. [Threshold Network decrypts hasLiq off-chain — mocked as (true, "")]
 *   5. finalizeOpenPositionPlain     — router retrieves stored handles, transfers
 *                                      encrypted collateral to vault, opens position.
 *
 * Amount conventions (6-decimal token, oracle prices in 1e18):
 *   COLLATERAL = 1_000e6, LEVERAGE = 5, SIZE = 5_000e6
 *   PRICE_ENTRY = 2_000e18, PRICE_UP = 2_200e18, PRICE_DOWN = 1_800e18
 *   PNL = (200e18 * 5_000e6) / 2_000e18 = 500e6
 */
contract PlainCollateralTest is Test {
    address constant TASK_MANAGER_ADDR = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    // ── contracts ─────────────────────────────────────────────────────────
    MockPlainERC20     underlying;
    MockFHEToken       fheToken;
    FHEVault           vault;
    PositionManager    pm;
    LiquidationManager lm;
    FHEFundingRateManager fheFRM;
    FHEOrderManager    om;
    FHERouter          router;
    PriceOracle        oracle;

    bytes32 lastPosId;

    // ── accounts ──────────────────────────────────────────────────────────
    address owner       = address(this);
    address lp          = address(0x10);
    address plainTrader = address(0x40); // holds only plain ERC-20, no pre-minted encrypted tokens

    // ── tokens / markets ──────────────────────────────────────────────────
    address ethToken;

    // ── amount constants ──────────────────────────────────────────────────
    uint64 constant LP_SEED    = 100_000e6;
    uint64 constant COLLATERAL = 1_000e6;
    uint64 constant LEVERAGE   = 5;
    uint64 constant SIZE       = COLLATERAL * LEVERAGE; // 5_000e6

    uint64 constant PNL = 500e6; // (200e18 * SIZE) / 2_000e18

    uint256 constant PRICE_ENTRY = 2_000e18;
    uint256 constant PRICE_UP    = 2_200e18; // +10 %
    uint256 constant PRICE_DOWN  = 1_800e18; // -10 %

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
            address(pm),
            address(vault),
            address(om),
            address(fheFRM),
            address(fheToken),
            ethToken,
            address(underlying)
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

        // Seed vault liquidity via LP (encrypted path)
        fheToken.mint(lp, LP_SEED);
        vm.prank(lp);
        fheToken.setOperator(address(router), type(uint48).max);
        vm.prank(lp);
        router.addLiquidity(_enc64(LP_SEED));

        // Fund plain trader with underlying ERC-20 only (no encrypted tokens pre-minted)
        underlying.mint(plainTrader, COLLATERAL * 10);
    }

    // ── mock helpers ──────────────────────────────────────────────────────

    function _enc64(uint256 val) internal pure returns (InEuint64 memory) {
        return InEuint64({ ctHash: val, securityZone: 0, utype: 5, signature: "" });
    }

    function _encBool(bool val) internal pure returns (InEbool memory) {
        return InEbool({ ctHash: val ? 1 : 0, securityZone: 0, utype: 0, signature: "" });
    }

    // ── core helpers ──────────────────────────────────────────────────────

    /// Full two-phase plain open. Caller must have approved + set operator first.
    function _openPlain(address trader_, uint64 col, uint64 lev, bool isLong) internal {
        vm.prank(trader_);
        router.submitOpenPositionCheckPlain(ethToken, col, _enc64(lev), _encBool(isLong));
        vm.prank(trader_);
        lastPosId = router.finalizeOpenPositionPlain(ethToken, true, "");
    }

    /// Approve + setOperator + open in one call for the happy-path tests.
    function _setupAndOpen(bool isLong) internal {
        vm.prank(plainTrader);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(plainTrader);
        fheToken.setOperator(address(router), type(uint48).max);
        _openPlain(plainTrader, COLLATERAL, LEVERAGE, isLong);
    }

    // ======================================================================
    // SECTION 1 — Prerequisite guards
    // ======================================================================

    function test_PlainPath_MissingApproval_Reverts() public {
        // plainTrader holds underlying but has NOT called approve
        vm.prank(plainTrader);
        vm.expectRevert(); // ERC20InsufficientAllowance
        router.submitOpenPositionCheckPlain(
            ethToken, COLLATERAL, _enc64(LEVERAGE), _encBool(true)
        );
    }

    function test_PlainPath_WrongToken_Reverts() public {
        vm.prank(plainTrader);
        underlying.approve(address(router), COLLATERAL);

        vm.prank(plainTrader);
        vm.expectRevert("unsupported index token");
        router.submitOpenPositionCheckPlain(
            address(0xBAD), COLLATERAL, _enc64(LEVERAGE), _encBool(true)
        );
    }

    function test_PlainPath_DoublePhase1_Reverts() public {
        vm.prank(plainTrader);
        underlying.approve(address(router), COLLATERAL * 2);
        vm.prank(plainTrader);
        fheToken.setOperator(address(router), type(uint48).max);

        // First Phase 1 — succeeds
        vm.prank(plainTrader);
        router.submitOpenPositionCheckPlain(
            ethToken, COLLATERAL, _enc64(LEVERAGE), _encBool(true)
        );

        // Second Phase 1 before Phase 2 — reverts
        vm.prank(plainTrader);
        vm.expectRevert("pending request exists");
        router.submitOpenPositionCheckPlain(
            ethToken, COLLATERAL, _enc64(LEVERAGE), _encBool(true)
        );
    }

    function test_PlainPath_Phase2WithoutPhase1_Reverts() public {
        vm.prank(plainTrader);
        vm.expectRevert("open check not submitted");
        router.finalizeOpenPositionPlain(ethToken, true, "");
    }

    function test_PlainPath_MissingOperator_Phase2Reverts() public {
        // Phase 1 OK (underlying approved, operator NOT set)
        vm.prank(plainTrader);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(plainTrader);
        router.submitOpenPositionCheckPlain(
            ethToken, COLLATERAL, _enc64(LEVERAGE), _encBool(true)
        );

        // Phase 2 fails: router can't confidentialTransferFrom without operator
        vm.prank(plainTrader);
        vm.expectRevert(); // FHERC20UnauthorizedSpender
        router.finalizeOpenPositionPlain(ethToken, true, "");
    }

    function test_PlainPath_InsufficientLiquidity_Phase2Reverts() public {
        // Request SIZE = LP_SEED + 1 > available liquidity (LP_SEED)
        uint64 bigCol = LP_SEED + 1;
        underlying.mint(plainTrader, bigCol);

        vm.prank(plainTrader);
        underlying.approve(address(router), bigCol);
        vm.prank(plainTrader);
        fheToken.setOperator(address(router), type(uint48).max);

        // Phase 1 with leverage = 1, so SIZE = bigCol = LP_SEED + 1 > LP_SEED
        vm.prank(plainTrader);
        router.submitOpenPositionCheckPlain(ethToken, bigCol, _enc64(1), _encBool(true));

        // Pass hasLiqPlain = false (Threshold Network says insufficient liquidity)
        vm.prank(plainTrader);
        vm.expectRevert("Insufficient vault liquidity");
        router.finalizeOpenPositionPlain(ethToken, false, "");
    }

    // ======================================================================
    // SECTION 2 — Position creation
    // ======================================================================

    function test_PlainPath_OpenLong_PositionExists() public {
        _setupAndOpen(true);
        assertTrue(pm.positionExists(lastPosId));
    }

    function test_PlainPath_OpenLong_PositionFields_Correct() public {
        _setupAndOpen(true);

        vm.prank(plainTrader);
        PositionManager.Position memory pos = pm.getMyPosition(lastPosId);

        assertTrue(pos.exists);
        assertEq(pos.owner, plainTrader);

        (uint128 decSize, bool ok1) = FHE.getDecryptResultSafe(pos.size);
        (uint128 decCol,  bool ok2) = FHE.getDecryptResultSafe(pos.collateral);
        (bool    decLong, bool ok3) = FHE.getDecryptResultSafe(pos.isLong);
        assertTrue(ok1 && ok2 && ok3);
        assertEq(uint64(decSize), SIZE);
        assertEq(uint64(decCol),  COLLATERAL);
        assertTrue(decLong);
    }

    function test_PlainPath_OpenShort_DirectionCorrect() public {
        _setupAndOpen(false);

        vm.prank(plainTrader);
        PositionManager.Position memory pos = pm.getMyPosition(lastPosId);
        (bool decLong, ) = FHE.getDecryptResultSafe(pos.isLong);
        assertFalse(decLong);
    }

    // ======================================================================
    // SECTION 3 — Token flow accounting
    // ======================================================================

    function test_PlainPath_UnderlyingPulledFromTrader() public {
        uint256 before_ = underlying.balanceOf(plainTrader);
        _setupAndOpen(true);
        uint256 after_  = underlying.balanceOf(plainTrader);
        assertEq(before_ - after_, COLLATERAL);
    }

    function test_PlainPath_VaultHoldsUnderlying() public {
        _setupAndOpen(true);
        // Vault holds the plain collateral as the underlying reserve (not the router).
        assertEq(underlying.balanceOf(address(vault)), COLLATERAL);
    }

    function test_PlainPath_EncryptedCollateralTransferredToVault() public {
        _setupAndOpen(true);
        // Vault holds LP_SEED (from LP) + COLLATERAL (wrapped and transferred in)
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED + COLLATERAL);
    }

    function test_PlainPath_TraderEncryptedBalanceZeroAfterOpen() public {
        _setupAndOpen(true);
        // wrap() minted COLLATERAL to trader in Phase 1;
        // Phase 2 transferred it all to vault — net encrypted balance = 0
        (uint64 traderBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(plainTrader)
        );
        assertEq(traderBal, 0);
    }

    function test_PlainPath_VaultLiquidityReserved() public {
        _setupAndOpen(true);
        (uint64 reserved, ) = FHE.getDecryptResultSafe(vault.totalReserved());
        assertEq(reserved, SIZE);
    }

    function test_PlainPath_VaultTotalLiquidityUnchanged() public {
        // Trader collateral goes directly into vault token balance (not into totalLiquidity).
        // totalLiquidity only changes via deposit() (LP) and receiveLoss().
        _setupAndOpen(true);
        (uint64 liq, ) = FHE.getDecryptResultSafe(vault.totalLiquidity());
        assertEq(liq, LP_SEED);
    }

    // ======================================================================
    // SECTION 4 — Full lifecycle: close position
    // ======================================================================

    function test_PlainPath_ClosePosition_Profit_TraderReceivesPayout() public {
        _setupAndOpen(true);

        oracle.setPrice(ethToken, PRICE_UP); // +10 % → profit

        vm.prank(plainTrader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(
            lastPosId,
            uint256(COLLATERAL + PNL), "",
            uint256(SIZE),             "",
            uint256(COLLATERAL),       "",
            true
        );

        (uint64 payout, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(plainTrader)
        );
        assertEq(payout, COLLATERAL + PNL);
    }

    function test_PlainPath_ClosePosition_Loss_TraderReceivesReducedPayout() public {
        _setupAndOpen(true);

        oracle.setPrice(ethToken, PRICE_DOWN); // -10 % → loss

        vm.prank(plainTrader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(
            lastPosId,
            uint256(COLLATERAL - PNL), "",
            uint256(SIZE),             "",
            uint256(COLLATERAL),       "",
            true
        );

        (uint64 payout, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(plainTrader)
        );
        assertEq(payout, COLLATERAL - PNL);
    }

    function test_PlainPath_ClosePosition_PositionDeleted() public {
        _setupAndOpen(true);

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

        assertFalse(pm.positionExists(lastPosId));
    }

    function test_PlainPath_ClosePosition_ReservesReleased() public {
        _setupAndOpen(true);

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

        (uint64 reserved, ) = FHE.getDecryptResultSafe(vault.totalReserved());
        assertEq(reserved, 0);
    }

    function test_PlainPath_ClosePosition_Profit_VaultBalanceDecreases() public {
        _setupAndOpen(true);

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

        // Vault paid out COLLATERAL + PNL from its balance.
        // Initial vault balance = LP_SEED + COLLATERAL.
        // Remaining = LP_SEED + COLLATERAL - (COLLATERAL + PNL) = LP_SEED - PNL.
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED - PNL);
    }

    function test_PlainPath_ClosePosition_Loss_VaultBalanceIncreases() public {
        _setupAndOpen(true);

        oracle.setPrice(ethToken, PRICE_DOWN);
        vm.prank(plainTrader);
        router.closePosition(lastPosId);
        pm.finalizeClosePosition(
            lastPosId,
            uint256(COLLATERAL - PNL), "",
            uint256(SIZE),             "",
            uint256(COLLATERAL),       "",
            true
        );

        // Vault paid out COLLATERAL - PNL; net gain = PNL.
        // Vault balance = LP_SEED + COLLATERAL - (COLLATERAL - PNL) = LP_SEED + PNL.
        (uint64 vaultBal, ) = FHE.getDecryptResultSafe(
            fheToken.confidentialBalanceOf(address(vault))
        );
        assertEq(vaultBal, LP_SEED + PNL);
    }

    // ======================================================================
    // SECTION 5 — Multiple plain-collateral opens
    // ======================================================================

    function test_PlainPath_TwoSequentialOpens_BothPositionsExist() public {
        address trader2 = address(0x50);
        underlying.mint(trader2, COLLATERAL);

        // First trader
        vm.prank(plainTrader);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(plainTrader);
        fheToken.setOperator(address(router), type(uint48).max);
        _openPlain(plainTrader, COLLATERAL, LEVERAGE, true);
        bytes32 pos1 = lastPosId;

        // Second trader
        vm.prank(trader2);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(trader2);
        fheToken.setOperator(address(router), type(uint48).max);
        _openPlain(trader2, COLLATERAL, LEVERAGE, false);
        bytes32 pos2 = lastPosId;

        assertTrue(pm.positionExists(pos1));
        assertTrue(pm.positionExists(pos2));
        assertTrue(pos1 != pos2);
    }

    function test_PlainPath_TwoSequentialOpens_LiquidityReservedCorrectly() public {
        address trader2 = address(0x50);
        underlying.mint(trader2, COLLATERAL);

        vm.prank(plainTrader);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(plainTrader);
        fheToken.setOperator(address(router), type(uint48).max);
        _openPlain(plainTrader, COLLATERAL, LEVERAGE, true);

        vm.prank(trader2);
        underlying.approve(address(router), COLLATERAL);
        vm.prank(trader2);
        fheToken.setOperator(address(router), type(uint48).max);
        _openPlain(trader2, COLLATERAL, LEVERAGE, false);

        (uint64 reserved, ) = FHE.getDecryptResultSafe(vault.totalReserved());
        assertEq(reserved, SIZE * 2);
    }
}
