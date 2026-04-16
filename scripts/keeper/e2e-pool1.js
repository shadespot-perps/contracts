import "dotenv/config";
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";

const RPC = process.env.ARBITRUM_SEPOLIA_RPC_URL;
// Use public node if Infura gets rate limited
const FALLBACK_RPC = "https://sepolia-rollup.arbitrum.io/rpc";
const PK = process.env.PRIVATE_KEY;
const INDEX_TOKEN = process.env.INDEX_TOKEN || "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73";

// Hardcoded Pool 1 addresses from latest deployment
const USDC = "0x3C5ADd985DB40a028DFC3035002B3d12483aC43F";
const ROUTER = "0x605F195534fC076ed4E02660e78a8072D6d4a44C";
const POSITION_MANAGER = "0x62a4cE432c45Fde2c0018da522bcB8738C9181DA";
const PRICE_ORACLE = "0x30fdBd9E1716CB71011b179Ebf82095Ce4dEcF96";

const account = privateKeyToAccount(PK);

// Using pollingInterval: 4000 to prevent 429 Too Many Requests from Infura
const publicClient = createPublicClient({ 
    chain: arbitrumSepolia, 
    transport: http(RPC),
    pollingInterval: 4000 
});
const walletClient = createWalletClient({ chain: arbitrumSepolia, transport: http(RPC), account });

const USDC_ABI = parseAbi([
    "function mint(address to, uint256 amount) external",
    "function approve(address spender, uint256 amount) external",
    "function balanceOf(address account) external view returns (uint256)",
]);

const ROUTER_ABI = parseAbi([
    "function addLiquidity(uint256 amount) external",
    "function openPosition(address token, uint256 collateral, uint256 leverage, bool isLong) external",
    "function closePosition(address token, bool isLong) external",
]);

const PM_ABI = parseAbi([
    "function getPosition(bytes32 key) view returns (address owner, address indexToken, bytes32 size, bytes32 collateral, bytes32 entryPrice, int256 entryFundingRate, bytes32 isLong, bool exists)",
    "function getPositionKey(address trader, address token, bool isLong) pure returns (bytes32)"
]);

const ORACLE_ABI = parseAbi([
    "function setPrice(address token, uint256 price) external"
]);

async function waitTx(hash, desc) {
    console.log(`⏳ Waiting for ${desc} (Tx: ${hash})...`);
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`✅ ${desc} Confirmed!`);
}

async function main() {
    console.log("🚀 Starting Pool 1 (USDC/ETH) E2E Workflow...");
    console.log(`Using account: ${account.address}`);

    // 1. Mint USDC
    const mintAmount = 2000n * 1000000n; // 2000 USDC (6 decimals)
    console.log("\n[1] Minting MockUSDC...");
    let tx = await walletClient.writeContract({
        address: USDC, abi: USDC_ABI, functionName: "mint", args: [account.address, mintAmount]
    });
    await waitTx(tx, "USDC Mint");

    // 2. Approve Router
    console.log("\n[2] Approving Router to spend USDC...");
    tx = await walletClient.writeContract({
        address: USDC, abi: USDC_ABI, functionName: "approve", args: [ROUTER, mintAmount]
    });
    await waitTx(tx, "USDC Approve");

    // 3. Add Liquidity (Vault needs depth to payout traders)
    const liqAmount = 1000n * 1000000n; // 1000 USDC
    console.log(`\n[3] Adding ${liqAmount / 1000000n} USDC Liquidity to Vault...`);
    tx = await walletClient.writeContract({
        address: ROUTER, abi: ROUTER_ABI, functionName: "addLiquidity", args: [liqAmount]
    });
    await waitTx(tx, "Add Liquidity");

    // 3.5 Set Oracle Price (Required before trading)
    console.log(`\n[3.5] Setting ETH Oracle Price to $3000...`);
    tx = await walletClient.writeContract({
        address: PRICE_ORACLE, abi: ORACLE_ABI, functionName: "setPrice", args: [INDEX_TOKEN, 3000n * 1000000n] // 3000 USDC per ETH
    });
    await waitTx(tx, "Set Price");

    // 4. Open Position (Long ETH)
    const collateral = 100n * 1000000n; // 100 USDC
    const leverage = 2n; // 2x Leveraged
    const isLong = true;
    console.log(`\n[4] Opening $${collateral / 1000000n} USDC ${leverage}x Long Position on ETH...`);
    tx = await walletClient.writeContract({
        address: ROUTER, abi: ROUTER_ABI, functionName: "openPosition", args: [INDEX_TOKEN, collateral, leverage, isLong]
    });
    await waitTx(tx, "Open Position");

    // Check Position via PositionManager
    const positionKey = await publicClient.readContract({
         address: POSITION_MANAGER, abi: PM_ABI, functionName: "getPositionKey", args: [account.address, INDEX_TOKEN, isLong]
    });
    
    // We intentionally delay slightly to ensure RPC indexed the state
    await new Promise(r => setTimeout(r, 2000));
    
    const pos = await publicClient.readContract({
         address: POSITION_MANAGER, abi: PM_ABI, functionName: "getPosition", args: [positionKey]
    });
    console.log(`   -> Position state on-chain: exists=${pos[7]}`);

    // 5. Close Position (Triggers keeper)
    console.log("\n[5] Closing Position (this will trigger our Keeper!)...");
    tx = await walletClient.writeContract({
        address: ROUTER, abi: ROUTER_ABI, functionName: "closePosition", args: [INDEX_TOKEN, isLong]
    });
    await waitTx(tx, "Close Position Request");

    console.log("\n🎉 E2E script finished execution!");
    console.log("👉 Watch your other terminal running `tail -f keeper.log` to see the Keeper catch the event, decrypt it from CoFHE, and finalize the settlement on-chain!");
}

main().catch(console.error);
