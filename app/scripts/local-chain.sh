#!/usr/bin/env bash
# Local rehearsal of the testnet deployment: anvil, DeployTestnet (faucet, tokens, staking, seed, first deposit), then
# ConfirmDeployment, which checks the contracts on the chain and writes app/src/config/deployments/31337.json.
# Start the app with VITE_CHAIN_ID=31337.
# Requires Foundry. Run from anywhere: ./app/scripts/local-chain.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="${RPC:-http://127.0.0.1:8545}"
# anvil's first default account, public test key
KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
# The faucet's feeder: anvil's account 5 unless given, so scripts/parity.test.ts can fund through it
export FEEDER_ADDRESS="${FEEDER_ADDRESS:-0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc}"

cd "$ROOT"

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Starting anvil on $RPC"
  anvil --silent --chain-id 31337 &
  for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

forge script script/testnet/DeployTestnet.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast -q
forge script script/testnet/ConfirmDeployment.s.sol --rpc-url "$RPC" -q
echo "Wrote app/src/config/deployments/31337.json"
