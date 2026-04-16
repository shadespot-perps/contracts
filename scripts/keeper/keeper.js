/**
 * ShadeSpot CoFHE Keeper Script (Dual Pool Monitor)
 *
 * Watches for CloseRequested / LiquidationRequested events on BOTH pools,
 * decrypts the FHE handles via CoFHE Threshold Network using @cofhe/sdk,
 * then submits finalizeClosePosition / finalizeLiquidation on-chain.
 */
import "dotenv/config";
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";
import { createCofheClientBase, createCofheConfigBase } from "@cofhe/sdk";
import { arbSepolia } from "@cofhe/sdk/chains";

// ── Config ──────────────────────────────────────────────────────────────────
const PM_1 = process.env.POSITION_MANAGER_1 ? process.env.POSITION_MANAGER_1.toLowerCase() : undefined;
const LM_1 = process.env.LIQ_MANAGER_1;
const PM_2 = process.env.POSITION_MANAGER_2 ? process.env.POSITION_MANAGER_2.toLowerCase() : undefined;
const LM_2 = process.env.LIQ_MANAGER_2;

const RPC = process.env.ARBITRUM_SEPOLIA_RPC_URL;
const PK = process.env.PRIVATE_KEY;

if (!PM_1 || !LM_1 || !PM_2 || !LM_2 || !RPC || !PK) {
    console.error("Missing required env vars: POSITION_MANAGER_1, LIQ_MANAGER_1, POSITION_MANAGER_2, LIQ_MANAGER_2");
    process.exit(1);
}

const LM_MAP = {
    [PM_1]: LM_1,
    [PM_2]: LM_2
};

// ── Clients ───────────────────────────────────────────────────────────────
const account = privateKeyToAccount(PK);
const publicClient = createPublicClient({ chain: arbitrumSepolia, transport: http(RPC) });
const walletClient = createWalletClient({ chain: arbitrumSepolia, transport: http(RPC), account });

const config = createCofheConfigBase({
    supportedChains: [arbSepolia],
});
const cofheClient = createCofheClientBase({ config });
cofheClient.connect(publicClient, walletClient).catch(console.error);

// ── ABIs ──────────────────────────────────────────────────────────────────
// Note: PositionManager emits both CloseRequested AND LiquidationRequested
const PM_ABI = parseAbi([
    "event CloseRequested(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, bytes32 finalAmountHandle)",
    "event LiquidationRequested(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, bytes32 canLiquidateHandle)",
    "function finalizeClosePosition(address trader, address token, bool isLong, uint256 finalAmount, bytes calldata finalAmountSig, uint256 sizePlain, bytes calldata sizeSig) external",
    "function pendingFinalAmount(bytes32 positionKey) view returns (bytes32)",
    "function getPosition(bytes32 key) view returns (address owner, address indexToken, bytes32 size, bytes32 collateral, bytes32 entryPrice, int256 entryFundingRate, bytes32 isLong, bool exists)",
]);

const LM_ABI = parseAbi([
    "function finalizeLiquidation(address trader, address token, bool isLong, bool canLiquidate, bytes calldata canLiqSig, uint256 collateralPlain, bytes calldata collateralSig, uint256 sizePlain, bytes calldata sizeSig) external",
]);

// ── Helpers ────────────────────────────────────────────────────────────────
async function decryptHandle(handle) {
    console.log(`  Decrypting handle: ${handle}`);
    const result = await cofheClient.decryptForTx(handle).withoutPermit().execute();
    // SDK returns { ctHash, decryptedValue: string, signature: `0x${string}` }
    const value = BigInt(result.decryptedValue);
    const signature = result.signature;
    console.log(`  Decrypted value: ${value}`);
    return { value, signature };
}

// ── CloseRequested handler ─────────────────────────────────────────────────
async function handleCloseRequested(log) {
    const { positionKey, trader, token, isLong, finalAmountHandle } = log.args;
    const pmAddress = log.address.toLowerCase();
    
    console.log(`\n[CloseRequested on ${pmAddress === PM_1 ? 'Pool 1' : 'Pool 2'}] trader=${trader} token=${token} isLong=${isLong}`);

    try {
        const finalAmountResult = await decryptHandle(finalAmountHandle);
        const pos = await publicClient.readContract({
            address: pmAddress, abi: PM_ABI, functionName: "getPosition", args: [positionKey],
        });
        // viem returns tuple as positional array: [owner, indexToken, size, collateral, entryPrice, entryFundingRate, isLong, exists]
        const sizeHandle = pos[2];
        console.log(`  size handle: ${sizeHandle}`);
        const sizeResult = await decryptHandle(sizeHandle);

        console.log(`  Sending finalizeClosePosition to ${pmAddress}...`);
        const tx = await walletClient.writeContract({
            address: pmAddress,
            abi: PM_ABI,
            functionName: "finalizeClosePosition",
            args: [
                trader, token, isLong,
                finalAmountResult.value,
                finalAmountResult.signature,
                sizeResult.value,
                sizeResult.signature,
            ],
        });
        console.log(`  ✅ finalizeClosePosition tx: ${tx}`);
    } catch (err) {
        console.error(`  ❌ Failed to finalize close:`, err.message);
    }
}

// ── LiquidationRequested handler ───────────────────────────────────────────
async function handleLiquidationRequested(log) {
    const { positionKey, trader, token, isLong, canLiquidateHandle } = log.args;
    const pmAddress = log.address.toLowerCase();
    const lmAddress = LM_MAP[pmAddress];

    console.log(`\n[LiquidationRequested on ${pmAddress === PM_1 ? 'Pool 1' : 'Pool 2'}] trader=${trader} token=${token} isLong=${isLong}`);

    try {
        const canLiqResult = await decryptHandle(canLiquidateHandle);

        const pos = await publicClient.readContract({
            address: pmAddress, abi: PM_ABI, functionName: "getPosition", args: [positionKey],
        });
        // viem returns tuple as positional array: [owner, indexToken, size, collateral, entryPrice, entryFundingRate, isLong, exists]
        const collateralResult = await decryptHandle(pos[3]);
        const sizeResult = await decryptHandle(pos[2]);

        console.log(`  Sending finalizeLiquidation (canLiquidate=${canLiqResult.value}) to ${lmAddress}...`);
        const tx = await walletClient.writeContract({
            address: lmAddress,
            abi: LM_ABI,
            functionName: "finalizeLiquidation",
            args: [
                trader, token, isLong,
                Boolean(canLiqResult.value),
                canLiqResult.signature,
                collateralResult.value,
                collateralResult.signature,
                sizeResult.value,
                sizeResult.signature,
            ],
        });
        console.log(`  ✅ finalizeLiquidation tx: ${tx}`);
    } catch (err) {
        console.error(`  ❌ Failed to finalize liquidation:`, err.message);
    }
}

// ── Watch ──────────────────────────────────────────────────────────────────
console.log("🔭 ShadeSpot Dual-Pool Keeper watching for events...");
console.log(`   Pool 1 | PositionManager: ${PM_1} | LiquidationManager: ${LM_1}`);
console.log(`   Pool 2 | PositionManager: ${PM_2} | LiquidationManager: ${LM_2}\n`);

publicClient.watchContractEvent({
    address: [PM_1, PM_2], abi: PM_ABI, eventName: "CloseRequested",
    onLogs: (logs) => logs.forEach(handleCloseRequested),
});

publicClient.watchContractEvent({
    address: [PM_1, PM_2], abi: PM_ABI, eventName: "LiquidationRequested",
    onLogs: (logs) => logs.forEach(handleLiquidationRequested),
});
