#!/usr/bin/env bash
#
# Verifies every deployed contract on Blockscout and Sourcify, so a reader can see the
# source rather than take the bytecode on trust. Idempotent: verified contracts are skipped.
#
#   bash tools/verify-contracts.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

FORGE=${FORGE_BIN:-$(command -v forge || true)}
CAST=${CAST_BIN:-$(command -v cast || true)}
FORGE=${FORGE:-/home/ubuntu/.foundry/versions/foundry-rs/foundry/v1.8.1/forge}
CAST=${CAST:-/home/ubuntu/.foundry/versions/foundry-rs/foundry/v1.8.1/cast}
if [ ! -x "$FORGE" ] || [ ! -x "$CAST" ]; then
  echo "forge/cast not found; set FORGE_BIN and CAST_BIN or install Foundry"
  exit 2
fi

PROBE_MAINNET=${LENS_PROBE_1:-$(node -p "JSON.parse(require('fs').readFileSync('deployments.json')).sources['1']?.probe || ''")}
PROBE_MAINNET=${PROBE_MAINNET:-$LENS_PROBE}
PROBE_SEPOLIA=${LENS_PROBE_11155111:-$(node -p "JSON.parse(require('fs').readFileSync('deployments.json')).sources['11155111']?.probe || ''")}
PROBE_SEPOLIA=${PROBE_SEPOLIA:-$LENS_PROBE}
RATIO_ADDRESS=$(node -p "JSON.parse(require('fs').readFileSync('docs/evidence/deployments.json'))['ratio.backingOverIssued'] || ''")
FEED_BACKING=$(node -p "JSON.parse(require('fs').readFileSync('docs/evidence/deployments.json'))['feed.aaveBacking'] || ''")
FEED_ISSUED=$(node -p "JSON.parse(require('fs').readFileSync('docs/evidence/deployments.json'))['feed.awethIssued'] || ''")

BS=https://creditcoin-testnet.blockscout.com
V=(--verifier blockscout --verifier-url "$BS/api/" --compiler-version 0.8.30)
FAILURES=0

verified() {
  curl -s -m 15 "$BS/api/v2/smart-contracts/$1" 2>/dev/null | grep -q '"is_verified":true'
}

verify() {
  local addr=$1 path=$2 args=${3:-}
  if [ -z "$addr" ]; then echo "  skip     $path (no address)"; return; fi
  if verified "$addr"; then echo "  already  ${path##*:}  $addr"; return; fi
  echo "  submitting ${path##*:}  $addr"
  if [ -n "$args" ]; then
    if output=$("$FORGE" verify-contract "$addr" "$path" "${V[@]}" --constructor-args "$args" 2>&1); then
      echo "  submitted ${path##*:} to Blockscout"
    else
      echo "  FAILED   ${path##*:} Blockscout submission"
      echo "$output" | tail -n 4
      FAILURES=$((FAILURES + 1))
    fi
  elif output=$("$FORGE" verify-contract "$addr" "$path" "${V[@]}" 2>&1); then
    echo "  submitted ${path##*:} to Blockscout"
  else
    echo "  FAILED   ${path##*:} Blockscout submission"
    echo "$output" | tail -n 4
    FAILURES=$((FAILURES + 1))
  fi
}

ENC() { "$CAST" abi-encode "$@"; }

sourcify_verified() {
  curl -fsS -m 15 "https://repo.sourcify.dev/contracts/full_match/$2/$1/metadata.json" >/dev/null 2>&1
}

verify_sourcify() {
  local addr=$1 path=$2 tx=${3:-} chain=${4:-102031}
  if [ -z "$addr" ]; then echo "  skip     ${path##*:} (no address)"; return; fi
  if sourcify_verified "$addr" "$chain"; then
    echo "  already  ${path##*:}  $addr  Sourcify full match"
    return
  fi
  echo "  submitting ${path##*:}  $addr  to Sourcify"
  local -a cmd=("$FORGE" verify-contract "$addr" "$path" --verifier sourcify --chain "$chain" --watch)
  if [ -n "$tx" ]; then cmd+=(--creation-transaction-hash "$tx"); fi
  if output=$("${cmd[@]}" 2>&1) && sourcify_verified "$addr" "$chain"; then
    echo "  verified  ${path##*:}  $addr  Sourcify full match"
  else
    echo "  pending  ${path##*:}  $addr  Sourcify"
    echo "$output" | tail -n 4
    FAILURES=$((FAILURES + 1))
  fi
}

verify "$LENS_REGISTRY"        contracts/src/LensRegistry.sol:LensRegistry   "$(ENC 'constructor(uint64[],uint64[],address[])' "[3,1]" "[1,11155111]" "[$PROBE_MAINNET,$PROBE_SEPOLIA]")"

verify "$LENS_AGGREGATOR_ETHUSD" contracts/src/LensAggregatorV3.sol:LensAggregatorV3   "$(ENC 'constructor(address,uint64,bytes32,uint8,uint256,string)' "$LENS_REGISTRY" 1       0x2c73f71f50a0b9d99ad60eec631f085b9c725adcf52e7e02011d2d197411b610 8 300 "sepolia.chainlink.ethUsd")"

verify "$LENS_MARKET"          contracts/src/consumers/LensMarket.sol:LensMarket   "$(ENC 'constructor(address,uint256,uint256,uint256)' "$LENS_AGGREGATOR_ETHUSD" 15000 1000 3600)"

verify "$LENS_BREAKER"         contracts/src/CircuitBreaker.sol:CircuitBreaker   "$(ENC 'constructor(address,uint64,bytes32,uint256,uint256)' "$LENS_REGISTRY" 1       0x2c73f71f50a0b9d99ad60eec631f085b9c725adcf52e7e02011d2d197411b610 500 600)"

verify "$LENS_ESCROW"          contracts/src/FeedEscrow.sol:FeedEscrow   "$(ENC 'constructor(address)' "$LENS_REGISTRY")"

verify "$LENS_VOTEPORT"        contracts/src/consumers/VotePort.sol:VotePort   "$(ENC 'constructor(address,uint64,address,bytes4,uint256)' "$LENS_REGISTRY" 1 "$LENS_VOTE_TOKEN"       0x3a46b1a8 5000)"

verify "$LENS_SNAPSHOT"        contracts/src/consumers/SnapshotProver.sol:SnapshotProver   "$(ENC 'constructor(address,uint64,uint256)' "$LENS_REGISTRY" 1 5000)"

verify "$LENS_RESERVE_MONITOR" contracts/src/consumers/ReserveMonitor.sol:ReserveMonitor   "$(ENC 'constructor(address,uint256,string)' "$RATIO_ADDRESS" 1000000000000000000 "Aave Sepolia aWETH backing")"

verify "$FEED_BACKING" contracts/src/RegistryFeed.sol:RegistryFeed   "$(ENC 'constructor(address,uint64,bytes32,uint256,string)' "$LENS_REGISTRY" 1 0xd774755ae7182cbd58c5f38c90a6d219b8511641e9c6c886a3f0075bc0735d7e 900 "WETH backing aWETH")"
verify "$FEED_ISSUED" contracts/src/RegistryFeed.sol:RegistryFeed   "$(ENC 'constructor(address,uint64,bytes32,uint256,string)' "$LENS_REGISTRY" 1 0x27d6df587bf9a5092339c4bf36dab8ca9c0e77b147a71a0bf5b2364f2f85cdd7 900 "aWETH issued")"
verify "$RATIO_ADDRESS" contracts/src/LensComposer.sol:RatioFeed   "$(ENC 'constructor(address,address,uint256,string)' "$FEED_BACKING" "$FEED_ISSUED" 1000000000000000000 "aWETH backing ratio")"

echo
echo "waiting for the Blockscout queue to drain, then reporting what stuck"
sleep 20
for pair in "LensRegistry:$LENS_REGISTRY" "LensAggregatorV3:$LENS_AGGREGATOR_ETHUSD" "LensMarket:$LENS_MARKET"             "CircuitBreaker:$LENS_BREAKER" "FeedEscrow:$LENS_ESCROW" "VotePort:$LENS_VOTEPORT"             "SnapshotProver:$LENS_SNAPSHOT" "ReserveMonitor:$LENS_RESERVE_MONITOR"             "RegistryFeed-backup:$FEED_BACKING" "RegistryFeed-issued:$FEED_ISSUED" "RatioFeed:$RATIO_ADDRESS"; do
  name=${pair%%:*}; addr=${pair#*:}
  if verified "$addr"; then echo "  verified  $name  $addr"; else echo "  NOT YET   $name  $addr"; FAILURES=$((FAILURES + 1)); fi
done

echo
echo "Sourcify full-match verification"
verify_sourcify "$LENS_REGISTRY" contracts/src/LensRegistry.sol:LensRegistry   0x235b8baec382ef0d7e7e0d6a9d3ea9a984ad1fe33b6a59b757b09a7caeaad036
verify_sourcify "$LENS_AGGREGATOR_ETHUSD" contracts/src/LensAggregatorV3.sol:LensAggregatorV3   0x09ecabf2fd8dc3858f1f4e0354b1f55dce17f07bfd1169f9339390212ebf1964
verify_sourcify "$LENS_MARKET" contracts/src/consumers/LensMarket.sol:LensMarket   0x6a6eec66de368572ab756e576b86105cefea3c032fb90f9779e6810d3db7418e
verify_sourcify "$LENS_BREAKER" contracts/src/CircuitBreaker.sol:CircuitBreaker   0xf9cf8461e1990cefa85c2b90b34fd77892eaa7f098a36c1f48a3019969d2f884
verify_sourcify "$LENS_ESCROW" contracts/src/FeedEscrow.sol:FeedEscrow   0xc7c0def5fdf2ea014669b9255d16adf5aa306e1f7a77b83ea575176433337050
verify_sourcify "$LENS_VOTEPORT" contracts/src/consumers/VotePort.sol:VotePort   0xcd9d1ee636531ca7a6fe0e5e6ca6bc25fde7ce32fbb2136903430153cf2f560a
verify_sourcify "$LENS_SNAPSHOT" contracts/src/consumers/SnapshotProver.sol:SnapshotProver   0xc91f3684d4119acc6717af3dab4c7d543ae49eec6da8904d8a04d97920f0824a
verify_sourcify "$LENS_RESERVE_MONITOR" contracts/src/consumers/ReserveMonitor.sol:ReserveMonitor   0x44478b5e14f27a0728ca1ec03f1ef064a72e14e191974f52472057de20c0fe31
verify_sourcify "$FEED_BACKING" contracts/src/RegistryFeed.sol:RegistryFeed   0xdc58aeb56b5e1b18b0570860e358f92f9578c84ad8a9bb774a053213f996c352
verify_sourcify "$FEED_ISSUED" contracts/src/RegistryFeed.sol:RegistryFeed   0x66bcab99f7c540a71325cfe089a256b6a7cc9829c2b86470f02df366d09e66c4
verify_sourcify "$RATIO_ADDRESS" contracts/src/LensComposer.sol:RatioFeed   0x483b817a82514e25b3eed6d2c5e5ead2abcdc97c1886862ee8e5b161cb4e0ed2
verify_sourcify "$PROBE_MAINNET" contracts/src/source/StateProbe.sol:StateProbe   0xfbc6952c018ac1155797efc638433308de874f96902c4bd51cc47dc6453aebf 1
verify_sourcify "$PROBE_SEPOLIA" contracts/src/source/StateProbe.sol:StateProbe   0xf0a89d2f6694406d98510f400b2136a05f206d35863ff9a81e2e71d9c6b549ae 11155111

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all verification requests completed and every checked Sourcify result is full match"
else
  echo "$FAILURES verification request(s) still need attention"
fi
exit "$FAILURES"
