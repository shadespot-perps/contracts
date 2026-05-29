"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ENC_TYPE = exports.TASK_MANAGER = exports.POOL2 = exports.POOL1 = exports.INDEX_TOKEN = exports.PRIVATE_KEY = exports.RPC_URL = void 0;
var dotenv = require("dotenv");
var path = require("path");
// Load from contracts/.env (sdk/ lives inside contracts/)
dotenv.config({ path: path.resolve(__dirname, "../../.env") });
exports.RPC_URL = process.env.ARBITRUM_SEPOLIA_RPC_URL;
exports.PRIVATE_KEY = process.env.PRIVATE_KEY;
exports.INDEX_TOKEN = process.env.INDEX_TOKEN;
if (!exports.RPC_URL || !exports.PRIVATE_KEY || !exports.INDEX_TOKEN) {
    throw new Error("Missing env vars. Check contracts/.env for ARBITRUM_SEPOLIA_RPC_URL, PRIVATE_KEY, INDEX_TOKEN");
}
// ── Deployed addresses (Arbitrum Sepolia) ────────────────────────────────────
// Pool 1 (USDC / ETH)
exports.POOL1 = {
    USDC: "0x5925bDEAd1a5A08203E0dC333dd10832daf20248",
    ORACLE: "0x072b0ca5A419D8293A81Cd9f0167CB29aD9E813A",
    FUNDING_MANAGER: "0x34a7DC8015f5705deEf2f5641e4894b41b9E9Cb9",
    VAULT: "0x1ee156AefDFE6D29af80eFAEAA0715909253cBC0",
    POSITION_MANAGER: "0xa3A13968D9157b46F78eff4CCcC53add47E6B68c",
    ORDER_MANAGER: "0xc4e195De483A0E43446D9907e3De2445b99C4e2E",
    LIQUIDATION_MGR: "0xab833e4258dB2F994795339412c86Df42144c531",
    ROUTER: "0xaaD5cd9ab30117cef2001B19b4fcA9F0C0D76e02",
};
// Pool 2 (FHE Token / ETH)
exports.POOL2 = {
    // Fresh deployment (May 07, 2026)
    FHE_TOKEN: "0x4373eE62078436EDD97f033C822F5226008e9304",
    PLAIN_UNDERLYING: "0x1A0fbC2aE66ed9eA20DdBe07C265e67B37580D20",
    ORACLE: "0x4e86e204E0778794b560E16b7D1b9FA94De14d7d",
    FUNDING_MANAGER: "0xF1Ae77F6138a6e4b2C57893d7b8160732157EAFD",
    FHE_VAULT: "0x013c8A7A5f6acd10EC31d6Cb71e783D7a0E999F5",
    POSITION_MANAGER: "0xcb9bafd7aCB7d4ad6BD9585241522Ceb868E5c02",
    ORDER_MANAGER: "0x479cb0588d2f0cdfEd3f249cA32dA6392D6ED336",
    LIQUIDATION_MGR: "0x887aA9C71dD22a1dcf7aD3DE7e93Ff56C729273c",
    FHE_ROUTER: "0x0F1313c9317B1917E2797A4fB5c2580F344d5a94",
    FINALIZER: "0x2b284c179a65709fC823711e6D76134E55a63798",
};
// CoFHE TaskManager on Arbitrum Sepolia
exports.TASK_MANAGER = "0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9";
// Encryption type constants (matches ICofhe.sol)
exports.ENC_TYPE = {
    EBOOL: 0,
    EUINT8: 2,
    EUINT16: 3,
    EUINT32: 4,
    EUINT64: 5,
    EUINT128: 6,
    EADDRESS: 7,
};
