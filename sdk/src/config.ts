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
  USDC:             "0x3b450aA23141DB0F9d2fb5eF9d1763d0FE72f655",
  ORACLE:           "0x63403Ab53f1808f92a267D274A311d5d49803c42",
  FUNDING_MANAGER:  "0x5e1C2Ee18B317326D2dD2612A7b8820F053B7080",
  VAULT:            "0xE4B3b5bff7CdA60c4472eA9FC59Ba512675e3BbC",
  POSITION_MANAGER: "0xb13fb9aD1Bb84C5943f2885e5fBd89218BE2f378",
  ORDER_MANAGER:    "0x82f0f5B3dC827511986D4852074C70668Be4fbB2",
  LIQUIDATION_MGR:  "0x17C597cFa193b46f820D3B7576F983222694d1c0",
  ROUTER:           "0xd2AC4Ce57e5286839644e69dC68701be90e90D8f",
};

// Pool 2 (FHE Token / ETH)
export const POOL2 = {
  FHE_TOKEN:        "0x2Efc2A6E950b711e18d387C6F9fd8091754b5eA0",
  ORACLE:           "0xe5cac732fe771dc7332092d2e596e2409c3c40d9",
  FUNDING_MANAGER:  "0x0ac5120866b6d69b59b76378274349af9fb7135f",
  FHE_VAULT:        "0xf85f2926b7afb36de4a293288bf0fecf2afa2cbd",
  POSITION_MANAGER: "0x6f4992da8139575acdefcb39a5b1ca094a95cf9c",
  ORDER_MANAGER:    "0xe9ffc02981294d051a9e4f2d172846c6bf017909",
  LIQUIDATION_MGR:  "0x02ba429eaf4b6309a7430534c9f9a18cfa6ff271",
  FHE_ROUTER:       "0x4fa2ffe7145dcf97815079ef1eefc9ffb1ef3f46",
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
