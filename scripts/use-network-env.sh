#!/usr/bin/env bash
# Select deploy env for a CoFHE testnet. Usage (from shadespot/):
#   source scripts/use-network-env.sh eth_sepolia
#   source scripts/use-network-env.sh arbitrum_sepolia
#   source scripts/use-network-env.sh base_sepolia

set -euo pipefail

NETWORK="${1:-}"
if [[ -z "$NETWORK" ]]; then
  echo "Usage: source scripts/use-network-env.sh <eth_sepolia|arbitrum_sepolia|base_sepolia>" >&2
  return 1 2>/dev/null || exit 1
fi

case "$NETWORK" in
  eth_sepolia|sepolia|ethereum_sepolia)
    export INDEX_TOKEN="${ETH_SEPOLIA_INDEX_TOKEN:?set ETH_SEPOLIA_INDEX_TOKEN in .env}"
    export DEPLOY_CHAIN_ID=11155111
    export DEPLOY_RPC_ALIAS=sepolia
    ;;
  arbitrum_sepolia|arb_sepolia)
    export INDEX_TOKEN="${ARBITRUM_SEPOLIA_INDEX_TOKEN:-${INDEX_TOKEN:?set INDEX_TOKEN or ARBITRUM_SEPOLIA_INDEX_TOKEN}}"
    export DEPLOY_CHAIN_ID=421614
    export DEPLOY_RPC_ALIAS=arbitrum_sepolia
    ;;
  base_sepolia)
    export INDEX_TOKEN="${BASE_SEPOLIA_INDEX_TOKEN:?set BASE_SEPOLIA_INDEX_TOKEN in .env}"
    export DEPLOY_CHAIN_ID=84532
    export DEPLOY_RPC_ALIAS=base_sepolia
    ;;
  *)
    echo "Unknown network: $NETWORK" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

echo "INDEX_TOKEN=$INDEX_TOKEN  chainId=$DEPLOY_CHAIN_ID  rpc=$DEPLOY_RPC_ALIAS"
