"use strict";
/**
 * keeper-finalize.ts — CoFHE Settlement Keeper
 *
 * Completes the two-phase close-position flow for Pool 1 (USDC) and Pool 2 (FHE Token).
 *
 * Flow:
 *   1. Watches PositionManager for CloseRequested events (or targets a specific trader)
 *   2. For each pending close, calls @cofhe/sdk decryptForTx on both handles:
 *        - finalAmountHandle  (euint128 — net payout to trader)
 *        - sizeHandle         (euint128 — position size for OI accounting)
 *      The SDK contacts the Threshold Network directly and returns
 *      { decryptedValue: bigint, signature: string } — no on-chain event scanning needed.
 *   3. Calls PositionManager.finalizeClosePosition with the proven plaintexts + TN signatures.
 *
 * Uses .withoutPermit() because FHE.allowPublic() in requestClosePosition marks both
 * handles as globally accessible in the ACL (any address can decrypt them).
 *
 * Usage:
 *   POOL=1 npm run keeper                       # watch Pool 1 (default)
 *   POOL=2 npm run keeper:pool2                 # watch Pool 2
 *   POOL=1 TRADER=0xABC npm run keeper          # one-shot for a specific trader
 *   FROM_BLOCK=12345678 POOL=1 npm run keeper   # replay + watch from a specific block
 */
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g = Object.create((typeof Iterator === "function" ? Iterator : Object).prototype);
    return g.next = verb(0), g["throw"] = verb(1), g["return"] = verb(2), typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (g && (g = 0, op[0] && (_ = 0)), _) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
var __spreadArray = (this && this.__spreadArray) || function (to, from, pack) {
    if (pack || arguments.length === 2) for (var i = 0, l = from.length, ar; i < l; i++) {
        if (ar || !(i in from)) {
            if (!ar) ar = Array.prototype.slice.call(from, 0, i);
            ar[i] = from[i];
        }
    }
    return to.concat(ar || Array.prototype.slice.call(from));
};
var _a, _b, _c;
Object.defineProperty(exports, "__esModule", { value: true });
var ethers_1 = require("ethers");
var node_1 = require("@cofhe/sdk/node");
var adapters_1 = require("@cofhe/sdk/adapters");
var chains_1 = require("@cofhe/sdk/chains");
var config_1 = require("./config");
// ── ABIs ─────────────────────────────────────────────────────────────────────
var POSITION_MANAGER_ABI = [
    "function finalizeClosePosition(bytes32 positionKey,uint256 finalAmount,bytes finalAmountSignature,uint256 sizePlain,bytes sizeSignature,uint256 collateralPlain,bytes collateralSignature,bool isLongPlain) external",
    "event CloseRequested(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle, bytes32 sizeHandle)",
    "event CloseFinalized(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle)",
    "event PositionOpened(bytes32 indexed positionKey, address indexed trader, bytes32 sizeHandle, bytes32 collateralHandle, bytes32 isLongHandle)",
];
// ── Config ────────────────────────────────────────────────────────────────────
var POOL = parseInt((_a = process.env.POOL) !== null && _a !== void 0 ? _a : "1");
var SPECIFIC_TRADER = (_b = process.env.TRADER) === null || _b === void 0 ? void 0 : _b.toLowerCase();
var FROM_BLOCK = parseInt((_c = process.env.FROM_BLOCK) !== null && _c !== void 0 ? _c : "0");
// Retry decryptForTx — TN may need a moment after new CloseRequested
var DECRYPT_RETRIES = 10;
var DECRYPT_RETRY_MS = 15000; // 15s between retries
// ── decryptForTx with retry ───────────────────────────────────────────────────
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function decryptHandle(cofheClient, ctHash, label) {
    return __awaiter(this, void 0, void 0, function () {
        var ctHashHex, permit, attempt, result, err_1, msg;
        var _a, _b;
        return __generator(this, function (_c) {
            switch (_c.label) {
                case 0:
                    ctHashHex = "0x" + ctHash.toString(16).padStart(64, "0");
                    return [4 /*yield*/, cofheClient.permits.getOrCreateSelfPermit()];
                case 1:
                    permit = _c.sent();
                    attempt = 1;
                    _c.label = 2;
                case 2:
                    if (!(attempt <= DECRYPT_RETRIES)) return [3 /*break*/, 8];
                    _c.label = 3;
                case 3:
                    _c.trys.push([3, 5, , 7]);
                    console.log("  [".concat(label, "] decryptForTx attempt ").concat(attempt, "/").concat(DECRYPT_RETRIES, "..."));
                    return [4 /*yield*/, cofheClient
                            .decryptForTx(ctHashHex)
                            .withPermit(permit)
                            .execute()];
                case 4:
                    result = _c.sent();
                    console.log("  [".concat(label, "] decrypted: ").concat(result.decryptedValue));
                    return [2 /*return*/, { value: result.decryptedValue, sig: result.signature }];
                case 5:
                    err_1 = _c.sent();
                    msg = (_b = (_a = err_1 === null || err_1 === void 0 ? void 0 : err_1.message) !== null && _a !== void 0 ? _a : err_1 === null || err_1 === void 0 ? void 0 : err_1.code) !== null && _b !== void 0 ? _b : String(err_1);
                    console.warn("  [".concat(label, "] attempt ").concat(attempt, " failed: ").concat(msg));
                    if (attempt === DECRYPT_RETRIES) {
                        throw new Error("decryptForTx [".concat(label, "] failed after ").concat(DECRYPT_RETRIES, " attempts: ").concat(msg));
                    }
                    console.log("  [".concat(label, "] retrying in ").concat(DECRYPT_RETRY_MS / 1000, "s..."));
                    return [4 /*yield*/, new Promise(function (r) { return setTimeout(r, DECRYPT_RETRY_MS); })];
                case 6:
                    _c.sent();
                    return [3 /*break*/, 7];
                case 7:
                    attempt++;
                    return [3 /*break*/, 2];
                case 8: 
                // unreachable
                throw new Error("decryptHandle unreachable");
            }
        });
    });
}
// ── Finalize ──────────────────────────────────────────────────────────────────
// Serializes finalizeClosePosition sends so concurrent decryptions don't race on nonce.
var txQueue = Promise.resolve();
function enqueueFinalize(fn) {
    txQueue = txQueue.then(fn).catch(function () { });
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function finalize(pending, pm, cofheClient) {
    return __awaiter(this, void 0, void 0, function () {
        var trader, positionKey, finalAmountHandle, sizeHandle, collateralHandle, _a, finalAmountRes, sizeRes, collateralRes;
        var _this = this;
        return __generator(this, function (_b) {
            switch (_b.label) {
                case 0:
                    trader = pending.trader, positionKey = pending.positionKey, finalAmountHandle = pending.finalAmountHandle, sizeHandle = pending.sizeHandle, collateralHandle = pending.collateralHandle;
                    console.log("\n[Finalize] trader=".concat(trader));
                    console.log("  positionKey:        ".concat(positionKey));
                    console.log("  finalAmountHandle:  0x".concat(finalAmountHandle.toString(16).padStart(64, "0")));
                    console.log("  sizeHandle:         0x".concat(sizeHandle.toString(16).padStart(64, "0")));
                    console.log("  collateralHandle:   0x".concat(collateralHandle.toString(16).padStart(64, "0")));
                    console.log("  Requesting decryption from Threshold Network...");
                    return [4 /*yield*/, Promise.all([
                            decryptHandle(cofheClient, finalAmountHandle, "finalAmount"),
                            decryptHandle(cofheClient, sizeHandle, "size"),
                            decryptHandle(cofheClient, collateralHandle, "collateral"),
                        ])];
                case 1:
                    _a = _b.sent(), finalAmountRes = _a[0], sizeRes = _a[1], collateralRes = _a[2];
                    console.log("\n  finalAmount : ".concat(finalAmountRes.value, "  (").concat((Number(finalAmountRes.value) / 1e6).toFixed(6), " units)"));
                    console.log("  sizePlain   : ".concat(sizeRes.value));
                    console.log("  collateral  : ".concat(collateralRes.value));
                    // Enqueue the send so concurrent decryptions don't race on the wallet nonce.
                    return [4 /*yield*/, new Promise(function (resolve, reject) {
                            enqueueFinalize(function () { return __awaiter(_this, void 0, void 0, function () {
                                var tx, receipt, iface, _i, _a, log, parsed, err_2;
                                var _b;
                                return __generator(this, function (_c) {
                                    switch (_c.label) {
                                        case 0:
                                            _c.trys.push([0, 3, , 4]);
                                            console.log("\n  Calling finalizeClosePosition for ".concat(trader, "..."));
                                            return [4 /*yield*/, pm.finalizeClosePosition(positionKey, finalAmountRes.value, finalAmountRes.sig, sizeRes.value, sizeRes.sig, collateralRes.value, collateralRes.sig, false)];
                                        case 1:
                                            tx = _c.sent();
                                            return [4 /*yield*/, tx.wait()];
                                        case 2:
                                            receipt = _c.sent();
                                            console.log("  tx:       ".concat(tx.hash));
                                            console.log("  block:    ".concat(receipt === null || receipt === void 0 ? void 0 : receipt.blockNumber, "  gas: ").concat(receipt === null || receipt === void 0 ? void 0 : receipt.gasUsed));
                                            iface = new ethers_1.ethers.Interface(POSITION_MANAGER_ABI);
                                            for (_i = 0, _a = (_b = receipt === null || receipt === void 0 ? void 0 : receipt.logs) !== null && _b !== void 0 ? _b : []; _i < _a.length; _i++) {
                                                log = _a[_i];
                                                try {
                                                    parsed = iface.parseLog({ topics: __spreadArray([], log.topics, true), data: log.data });
                                                    if ((parsed === null || parsed === void 0 ? void 0 : parsed.name) === "CloseFinalized") {
                                                        console.log("\n  CloseFinalized:");
                                                        console.log("    positionKey : ".concat(parsed.args.positionKey));
                                                        console.log("    trader      : ".concat(parsed.args.trader));
                                                        console.log("    handle      : ".concat(parsed.args.finalAmountHandle));
                                                    }
                                                }
                                                catch (_d) { }
                                            }
                                            resolve();
                                            return [3 /*break*/, 4];
                                        case 3:
                                            err_2 = _c.sent();
                                            reject(err_2);
                                            return [3 /*break*/, 4];
                                        case 4: return [2 /*return*/];
                                    }
                                });
                            }); });
                        })];
                case 2:
                    // Enqueue the send so concurrent decryptions don't race on the wallet nonce.
                    _b.sent();
                    return [2 /*return*/];
            }
        });
    });
}
// ── Helper ────────────────────────────────────────────────────────────────────
function resolveCollateralHandle(pm, positionKey, fromBlock) {
    return __awaiter(this, void 0, void 0, function () {
        var openedLogs, opened, collateralHandle;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0: return [4 /*yield*/, pm.queryFilter(pm.filters.PositionOpened(positionKey, null), fromBlock, "latest")];
                case 1:
                    openedLogs = _a.sent();
                    if (openedLogs.length === 0)
                        return [2 /*return*/, null];
                    opened = openedLogs[openedLogs.length - 1];
                    collateralHandle = opened.args[3];
                    return [2 /*return*/, BigInt(collateralHandle)];
            }
        });
    });
}
function buildPendingFromEvent(pm, e, fromBlock) {
    return __awaiter(this, void 0, void 0, function () {
        var positionKey, trader, finalAmountHandle, sizeHandle, collateralHandle;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    positionKey = e.args[0];
                    trader = e.args[1];
                    finalAmountHandle = BigInt(e.args[2]);
                    sizeHandle = BigInt(e.args[3]);
                    if (finalAmountHandle === 0n || sizeHandle === 0n)
                        return [2 /*return*/, null];
                    return [4 /*yield*/, resolveCollateralHandle(pm, positionKey, fromBlock)];
                case 1:
                    collateralHandle = _a.sent();
                    if (!collateralHandle || collateralHandle === 0n) {
                        console.warn("  [Skip] collateral handle not found for position ".concat(positionKey));
                        return [2 /*return*/, null];
                    }
                    return [2 /*return*/, {
                            trader: trader,
                            positionKey: positionKey,
                            finalAmountHandle: finalAmountHandle,
                            sizeHandle: sizeHandle,
                            collateralHandle: collateralHandle,
                        }];
            }
        });
    });
}
// ── Main ─────────────────────────────────────────────────────────────────────
function main() {
    return __awaiter(this, void 0, void 0, function () {
        function tryFinalize(pending) {
            if (inFlight.has(pending.finalAmountHandle))
                return;
            inFlight.add(pending.finalAmountHandle);
            finalize(pending, pm, cofheClient)
                .catch(function (err) { var _a; return console.error("  Error finalizing:", (_a = err.message) !== null && _a !== void 0 ? _a : err); })
                .finally(function () { return inFlight.delete(pending.finalAmountHandle); });
        }
        var provider, wallet, poolConfig, PM_ADDR, config, cofheClient, _a, publicClient, walletClient, pm, inFlight, startBlock_1, reqLogs, found, _i, reqLogs_1, evt, pending, startBlock, past, uniquePending, _b, past_1, evt, pending, replayed, _c, _d, pending;
        var _this = this;
        return __generator(this, function (_e) {
            switch (_e.label) {
                case 0:
                    provider = new ethers_1.JsonRpcProvider(config_1.RPC_URL);
                    wallet = new ethers_1.Wallet(config_1.PRIVATE_KEY, provider);
                    poolConfig = POOL === 2 ? config_1.POOL2 : config_1.POOL1;
                    PM_ADDR = poolConfig.POSITION_MANAGER;
                    console.log("ShadeSpot Settlement Keeper \u2014 Pool ".concat(POOL));
                    console.log("Wallet:          ".concat(wallet.address));
                    console.log("PositionManager: ".concat(PM_ADDR));
                    console.log("FROM_BLOCK:      ".concat(FROM_BLOCK || "earliest"));
                    // ── CoFHE client setup ────────────────────────────────────────────────────
                    console.log("\nConnecting @cofhe/sdk...");
                    config = (0, node_1.createCofheConfig)({ supportedChains: [chains_1.arbSepolia] });
                    cofheClient = (0, node_1.createCofheClient)(config);
                    return [4 /*yield*/, (0, adapters_1.Ethers6Adapter)(provider, wallet)];
                case 1:
                    _a = _e.sent(), publicClient = _a.publicClient, walletClient = _a.walletClient;
                    return [4 /*yield*/, cofheClient.connect(publicClient, walletClient)];
                case 2:
                    _e.sent();
                    console.log("CoFHE client connected  chainId=".concat(cofheClient.chainId, "  account=").concat(cofheClient.account));
                    pm = new ethers_1.Contract(PM_ADDR, POSITION_MANAGER_ABI, wallet);
                    inFlight = new Set();
                    if (!SPECIFIC_TRADER) return [3 /*break*/, 9];
                    console.log("\nOne-shot mode \u2014 trader: ".concat(SPECIFIC_TRADER));
                    startBlock_1 = FROM_BLOCK || 0;
                    return [4 /*yield*/, pm.queryFilter(pm.filters.CloseRequested(null, SPECIFIC_TRADER), startBlock_1, "latest")];
                case 3:
                    reqLogs = _e.sent();
                    found = 0;
                    _i = 0, reqLogs_1 = reqLogs;
                    _e.label = 4;
                case 4:
                    if (!(_i < reqLogs_1.length)) return [3 /*break*/, 8];
                    evt = reqLogs_1[_i];
                    return [4 /*yield*/, buildPendingFromEvent(pm, evt, startBlock_1)];
                case 5:
                    pending = _e.sent();
                    if (!pending)
                        return [3 /*break*/, 7];
                    found++;
                    return [4 /*yield*/, finalize(pending, pm, cofheClient)];
                case 6:
                    _e.sent();
                    _e.label = 7;
                case 7:
                    _i++;
                    return [3 /*break*/, 4];
                case 8:
                    if (found === 0) {
                        console.log("No pending close for ".concat(SPECIFIC_TRADER, " on Pool ").concat(POOL, "."));
                        console.log("Call closePosition first (emits CloseRequested).");
                    }
                    return [2 /*return*/];
                case 9:
                    // ── Watch mode ────────────────────────────────────────────────────────────
                    console.log("\nWatch mode \u2014 listening for CloseRequested events... (Ctrl+C to stop)");
                    startBlock = FROM_BLOCK || 0;
                    console.log("\nReplaying CloseRequested events since block ".concat(startBlock || "earliest", "..."));
                    return [4 /*yield*/, pm.queryFilter(pm.filters.CloseRequested(), startBlock, "latest")];
                case 10:
                    past = _e.sent();
                    uniquePending = new Map();
                    _b = 0, past_1 = past;
                    _e.label = 11;
                case 11:
                    if (!(_b < past_1.length)) return [3 /*break*/, 14];
                    evt = past_1[_b];
                    return [4 /*yield*/, buildPendingFromEvent(pm, evt, startBlock)];
                case 12:
                    pending = _e.sent();
                    if (!pending)
                        return [3 /*break*/, 13];
                    uniquePending.set(pending.positionKey, pending);
                    _e.label = 13;
                case 13:
                    _b++;
                    return [3 /*break*/, 11];
                case 14:
                    replayed = 0;
                    for (_c = 0, _d = uniquePending.values(); _c < _d.length; _c++) {
                        pending = _d[_c];
                        replayed++;
                        console.log("  [Replay] trader=".concat(pending.trader, "  positionKey=").concat(pending.positionKey));
                        tryFinalize(pending);
                    }
                    console.log("  Replayed ".concat(replayed, " unique pending close(s).\n"));
                    // Live listener
                    pm.on("CloseRequested", function (positionKey, trader, finalAmountHandle, sizeHandle, event) { return __awaiter(_this, void 0, void 0, function () {
                        var collateralHandle;
                        return __generator(this, function (_a) {
                            switch (_a.label) {
                                case 0:
                                    console.log("\n[Event] CloseRequested  block=".concat(event.blockNumber, "  trader=").concat(trader, "  positionKey=").concat(positionKey));
                                    return [4 /*yield*/, resolveCollateralHandle(pm, positionKey, Number(event.blockNumber))];
                                case 1:
                                    collateralHandle = _a.sent();
                                    if (!collateralHandle || collateralHandle === 0n) {
                                        console.warn("  [Skip] collateral handle not found for live event position ".concat(positionKey));
                                        return [2 /*return*/];
                                    }
                                    tryFinalize({
                                        trader: trader,
                                        positionKey: positionKey,
                                        finalAmountHandle: BigInt(finalAmountHandle),
                                        sizeHandle: BigInt(sizeHandle),
                                        collateralHandle: collateralHandle,
                                    });
                                    return [2 /*return*/];
                            }
                        });
                    }); });
                    process.stdin.resume();
                    return [2 /*return*/];
            }
        });
    });
}
main().catch(console.error);
