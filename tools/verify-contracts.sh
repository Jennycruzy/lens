#!/usr/bin/env bash
#
# Verifies every deployed contract on Blockscout, so a reader can see the source rather
# than take the bytecode on trust. Idempotent: a contract already verified is skipped.
#
#   bash tools/verify-contracts.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export PATH="$HOME/.foundry/bin:$PATH"

PROBE_MAINNET=${LENS_PROBE_1:-$(node -p "JSON.parse(require('fs').readFileSync('deployments.json')).sources['1']?.probe || ''")}
PROBE_MAINNET=${PROBE_MAINNET:-$LENS_PROBE}
PROBE_SEPOLIA=${LENS_PROBE_11155111:-$(node -p "JSON.parse(require('fs').readFileSync('deployments.json')).sources['11155111']?.probe || ''")}
PROBE_SEPOLIA=${PROBE_SEPOLIA:-$LENS_PROBE}

BS=https://creditcoin-testnet.blockscout.com
V=(--verifier blockscout --verifier-url "$BS/api/" --compiler-version 0.8.30)

verified() {
  curl -s -m 15 "$BS/api/v2/smart-contracts/$1" 2>/dev/null | grep -q '"is_verified":true'
}

verify() {
  local addr=$1 path=$2 args=${3:-}
  if [ -z "$addr" ]; then echo "  skip     $path (no address)"; return; fi
  if verified "$addr"; then echo "  already  ${path##*:}  $addr"; return; fi
  echo "  submitting ${path##*:}  $addr"
  if [ -n "$args" ]; then
    forge verify-contract "$addr" "$path" "${V[@]}" --constructor-args "$args" >/dev/null 2>&1
  else
    forge verify-contract "$addr" "$path" "${V[@]}" >/dev/null 2>&1
  fi
}

ENC() { cast abi-encode "$@"; }

verify "$LENS_REGISTRY"        contracts/src/LensRegistry.sol:LensRegistry \
  "$(ENC 'constructor(uint64[],uint64[],address[])' "[3,1]" "[1,11155111]" "[$PROBE_MAINNET,$PROBE_SEPOLIA]")"

verify "$LENS_AGGREGATOR_ETHUSD" contracts/src/LensAggregatorV3.sol:LensAggregatorV3 \
  "$(ENC 'constructor(address,uint64,bytes32,uint8,uint256,string)' "$LENS_REGISTRY" 1 \
      0x2c73f71f50a0b9d99ad60eec631f085b9c725adcf52e7e02011d2d197411b610 8 300 "sepolia.chainlink.ethUsd")"

verify "$LENS_MARKET"          contracts/src/consumers/LensMarket.sol:LensMarket \
  "$(ENC 'constructor(address,uint256,uint256,uint256)' "$LENS_AGGREGATOR_ETHUSD" 15000 1000 3600)"

verify "$LENS_BREAKER"         contracts/src/CircuitBreaker.sol:CircuitBreaker \
  "$(ENC 'constructor(address,uint64,bytes32,uint256,uint256)' "$LENS_REGISTRY" 1 \
      0x2c73f71f50a0b9d99ad60eec631f085b9c725adcf52e7e02011d2d197411b610 500 600)"

verify "$LENS_ESCROW"          contracts/src/FeedEscrow.sol:FeedEscrow \
  "$(ENC 'constructor(address)' "$LENS_REGISTRY")"

verify "$LENS_VOTEPORT"        contracts/src/consumers/VotePort.sol:VotePort \
  "$(ENC 'constructor(address,uint64,address,bytes4,uint256)' "$LENS_REGISTRY" 1 "$LENS_VOTE_TOKEN" \
      0x3a46b1a8 5000)"

verify "$LENS_SNAPSHOT"        contracts/src/consumers/SnapshotProver.sol:SnapshotProver \
  "$(ENC 'constructor(address,uint64,uint256)' "$LENS_REGISTRY" 1 5000)"

verify "$LENS_RESERVE_MONITOR" contracts/src/consumers/ReserveMonitor.sol:ReserveMonitor \
  "$(ENC 'constructor(address,uint256,string)' 0x1afe1E0EC021460CA189650B5c7bBB823C308bE4 1000000000000000000 "Aave Sepolia aWETH backing")"

echo
echo "waiting for the queue to drain, then reporting what stuck"
sleep 45
for pair in "LensRegistry:$LENS_REGISTRY" "LensAggregatorV3:$LENS_AGGREGATOR_ETHUSD" "LensMarket:$LENS_MARKET" \
            "CircuitBreaker:$LENS_BREAKER" "FeedEscrow:$LENS_ESCROW" "VotePort:$LENS_VOTEPORT" \
            "SnapshotProver:$LENS_SNAPSHOT" "ReserveMonitor:$LENS_RESERVE_MONITOR"; do
  name=${pair%%:*}; addr=${pair#*:}
  if verified "$addr"; then echo "  verified  $name  $addr"; else echo "  NOT YET   $name  $addr"; fi
done
