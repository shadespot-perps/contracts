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
  FHE_TOKEN:        "0x4aFbe967B14a49d5ed01e04331C906F28cebEd0D",
  ORACLE:           "0x6704341EF4C3804c0266e21482aA12B0752031d5",
  FUNDING_MANAGER:  "0xB10F5FAF196a2fB2Be5C379446989BBB583fB1bf",
  FHE_VAULT:        "0xd954990C6f73fD525A19660EbBcFa42B404ceb5d",
  POSITION_MANAGER: "0x2389448CdB6d6d8CA97a358Be7d193308D1F9A51",
  ORDER_MANAGER:    "0x9c21B9deFfD397CE21c6E76E72ad8042e91AA8c3",
  LIQUIDATION_MGR:  "0xa2938DC2EC5171c3690237A0222a4bAf57F5D84f",
  FHE_ROUTER:       "0x5FdD2a53FA8Ba86Ed934CDAC40295781863098bE",
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
