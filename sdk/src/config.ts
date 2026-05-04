import * as dotenv from "dotenv";
import * as path from "path";

// Load from contracts/.env (sdk/ lives inside contracts/)
dotenv.config({ path: path.resolve(__dirname, "../../.env") });

export const RPC_URL     = process.env.ARBITRUM_SEPOLIA_RPC_URL!;
export const PRIVATE_KEY = process.env.PRIVATE_KEY!;
export const INDEX_TOKEN = process.env.INDEX_TOKEN!;

if (!RPC_URL || !PRIVATE_KEY || !INDEX_TOKEN) {
  throw new Error("Missing env vars. Check contracts/.env for ARBITRUM_SEPOLIA_RPC_URL, PRIVATE_KEY, INDEX_TOKEN");
}

// ── Deployed addresses (Arbitrum Sepolia) ────────────────────────────────────

// Pool 1 (USDC / ETH)
export const POOL1 = {
  USDC:             "0x5925bDEAd1a5A08203E0dC333dd10832daf20248",
  ORACLE:           "0x072b0ca5A419D8293A81Cd9f0167CB29aD9E813A",
  FUNDING_MANAGER:  "0x34a7DC8015f5705deEf2f5641e4894b41b9E9Cb9",
  VAULT:            "0x1ee156AefDFE6D29af80eFAEAA0715909253cBC0",
  POSITION_MANAGER: "0xa3A13968D9157b46F78eff4CCcC53add47E6B68c",
  ORDER_MANAGER:    "0xc4e195De483A0E43446D9907e3De2445b99C4e2E",
  LIQUIDATION_MGR:  "0xab833e4258dB2F994795339412c86Df42144c531",
  ROUTER:           "0xaaD5cd9ab30117cef2001B19b4fcA9F0C0D76e02",
};

// Pool 2 (FHE Token / ETH)
export const POOL2 = {
  // Fresh deployment (Apr 28, 2026)
  FHE_TOKEN:        "0xe3843689B78709463a77Faa30d7A2Df72f56163b",
  ORACLE:           "0x372cCb135c97e106eD44701e6170Ac4C06Dc3F72",
  FUNDING_MANAGER:  "0x53903cBAAdd1F5B6bAEa95F654B7A9De17F69D75",
  FHE_VAULT:        "0xF522f386046644b359472E05340BB692751C5A37",
  POSITION_MANAGER: "0xD61852B3E1f0E8c49A8EB5dCD039926744b853f0",
  ORDER_MANAGER:    "0xDEBA979720dF2454a1e34f9304F66dD0003BBf78",
  LIQUIDATION_MGR:  "0x09AB5a52d7f4f1c58D966634F2aBdAEa6cA0265f",
  FHE_ROUTER:       "0x3F476E2D46eA857aD82DA28c41a15d336F3bA83D",
};

// CoFHE TaskManager on Arbitrum Sepolia
export const TASK_MANAGER = "0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9";

// Encryption type constants (matches ICofhe.sol)
export const ENC_TYPE = {
  EBOOL:    0,
  EUINT8:   2,
  EUINT16:  3,
  EUINT32:  4,
  EUINT64:  5,
  EUINT128: 6,
  EADDRESS: 7,
} as const;
