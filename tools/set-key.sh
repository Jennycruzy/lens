#!/usr/bin/env bash
#
# Puts a funded private key into .env without it appearing on screen, in shell
# history, or in this session's transcript. Reads it from a silent prompt, checks it
# is a well-formed key, and reports only the address it derives.
#
#   bash tools/set-key.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=".env"
[ -f "$ENV_FILE" ] || { echo "no .env here; copy .env.example first" >&2; exit 1; }

read -rsp "Private key (input hidden): " KEY
echo

KEY="${KEY#0x}"
if ! [[ "$KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "That is not a 32-byte hex key. Nothing was written." >&2
  exit 1
fi
KEY="0x$KEY"

if ! command -v cast >/dev/null 2>&1; then
  export PATH="$HOME/.foundry/bin:$PATH"
fi
ADDRESS="$(cast wallet address --private-key "$KEY")"

# Write via a temp file so a failure cannot leave .env half-updated.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
sed -e "s|^PROBER_PRIVATE_KEY=.*|PROBER_PRIVATE_KEY=$KEY|" \
    -e "s|^CC3_PRIVATE_KEY=.*|CC3_PRIVATE_KEY=$KEY|" \
    -e "s|^LENS_ADDRESS=.*|LENS_ADDRESS=$ADDRESS|" "$ENV_FILE" > "$TMP"
mv "$TMP" "$ENV_FILE"
chmod 600 "$ENV_FILE"
trap - EXIT
unset KEY

echo "Stored. Address is now $ADDRESS"
echo "Check what it holds with: node tools/balances.mjs"
