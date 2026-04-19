// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { FHEFundingRateManager } from "../src/core/FHEFundingRateManager.sol";

// One-shot script: call initializeToken on the already-deployed FHEFundingRateManager.
// Run once; safe to skip if lastFundingTime is already set.
//
// Usage:
//   PRIVATE_KEY=<owner_key> forge script script/InitializeFundingToken.s.sol \
//     --rpc-url arbitrum_sepolia --broadcast
contract InitializeFundingToken is Script {
    address constant FUNDING_MANAGER = 0xF7DC4ef11C0AC6a1Ad03D40Fb5667C9536e3d8D5;
    address constant INDEX_TOKEN     = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        FHEFundingRateManager(FUNDING_MANAGER).initializeToken(INDEX_TOKEN);
        vm.stopBroadcast();
    }
}
