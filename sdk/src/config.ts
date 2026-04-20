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
  FHE_TOKEN:        "0x2967828Af530E9ed6c70185b888884104CC3E23a",
  ORACLE:           "0x82830d17Da5397882a6c328D50351DBf69b2b847",
  FUNDING_MANAGER:  "0x2F66b7266167B53F2c9494F9484C949F232f6614",
  FHE_VAULT:        "0x006a880Ea04690efEd3895b4117c5d983eb43d51",
  POSITION_MANAGER: "0x34c8676b516e7e85B43159FD52Cf47C836461e52",
  ORDER_MANAGER:    "0xAa7FEb37b0688F48489EDce81343372B99B76758",
  LIQUIDATION_MGR:  "0xbfA0D25Cf08d250b1cbE6756406fEA0d4C759163",
  FHE_ROUTER:       "0x5d0e0169a98009148ca93f82A89C037701B00d2B",
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
