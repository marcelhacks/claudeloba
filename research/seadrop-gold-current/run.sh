#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="${RUNNER_TEMP:-/tmp}/official-seadrop-gold-lab"
OUT="$ROOT/results/latest"
SEAPORT="0x0000000000000068F116a894984e2DB1123eB395"
CONDUIT="0x1e0049783f008a0085193e00003d00cd54003c71"
CONTROLLER="0x00000000F9490004C11Cef243f5400493c00Ad63"
EXPECTED_HASH="0x74499ac0cce14428e4b41541d5e44f28f5a6882a1051d0118867c2a93cd5aec0"

rm -rf "$LAB" "$OUT"
mkdir -p "$LAB/test" "$LAB/src" "$LAB/lib" "$OUT/attempts"
cp "$ROOT/OfficialFactoryFork.t.sol" "$LAB/test/OfficialFactoryFork.t.sol"
git clone --quiet --depth 1 https://github.com/foundry-rs/forge-std.git "$LAB/lib/forge-std"
cat > "$LAB/foundry.toml" <<'TOML'
[profile.default]
src = "src"
test = "test"
out = "out"
cache_path = "cache"
solc_version = "0.8.24"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
ffi = false
TOML

cat > "$OUT/scan.tsv" <<'TSV'
network	chain_id	factory	fork_block	factory_seaport	seaport_hash	result
TSV

FACTORIES=(
  "0x00b19A5200A100e5fc4c9800772f4d002f218400"
  "0x000000F20032b9e171844B00EA507E11960BD94a"
)

NETWORKS=(
  "ethereum|https://ethereum-rpc.publicnode.com"
  "base|https://base-rpc.publicnode.com"
  "arbitrum|https://arbitrum-one-rpc.publicnode.com"
  "optimism|https://optimism-rpc.publicnode.com"
  "polygon|https://polygon-bor-rpc.publicnode.com"
  "avalanche|https://avalanche-c-chain-rpc.publicnode.com"
  "bsc|https://bsc-rpc.publicnode.com"
)

PROVEN=0
SELECTED_NETWORK=""
SELECTED_CHAIN=""
SELECTED_RPC=""
SELECTED_FACTORY=""
SELECTED_BLOCK=""
SELECTED_LOG=""

for spec in "${NETWORKS[@]}"; do
  IFS='|' read -r network rpc <<< "$spec"
  if ! chain_id="$(timeout 30 cast chain-id --rpc-url "$rpc" 2>/dev/null)"; then
    continue
  fi
  if ! latest="$(timeout 30 cast block-number --rpc-url "$rpc" 2>/dev/null)"; then
    continue
  fi
  if (( latest > 32 )); then
    fork_block=$((latest - 32))
  else
    fork_block=$latest
  fi

  seaport_hash="$(timeout 30 cast codehash "$SEAPORT" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
  if [[ "${seaport_hash,,}" != "${EXPECTED_HASH,,}" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "-" "$fork_block" "-" "$seaport_hash" "SEAPORT_HASH_MISMATCH" >> "$OUT/scan.tsv"
    continue
  fi

  conduit_code="$(timeout 30 cast code "$CONDUIT" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
  controller_code="$(timeout 30 cast code "$CONTROLLER" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
  if [[ "$conduit_code" == "0x" || "$controller_code" == "0x" || -z "$conduit_code" || -z "$controller_code" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "-" "$fork_block" "-" "$seaport_hash" "CONDUIT_OR_CONTROLLER_MISSING" >> "$OUT/scan.tsv"
    continue
  fi

  for factory in "${FACTORIES[@]}"; do
    code="$(timeout 30 cast code "$factory" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
    if [[ "$code" == "0x" || -z "$code" ]]; then
      continue
    fi
    factory_seaport="$(timeout 30 cast call "$factory" 'seaport()(address)' --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
    if [[ "${factory_seaport,,}" != "${SEAPORT,,}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "$factory" "$fork_block" "$factory_seaport" "$seaport_hash" "FACTORY_NOT_1_6" >> "$OUT/scan.tsv"
      continue
    fi

    attempt="$OUT/attempts/${network}-${factory}.log"
    set +e
    RPC_URL="$rpc" FORK_BLOCK="$fork_block" SEADROP_FACTORY="$factory" \
      timeout 900 forge test \
        --root "$LAB" \
        --match-contract OfficialFactoryForkTest \
        -vvvv > "$attempt" 2>&1
    rc=$?
    set -e

    if [[ $rc -eq 0 ]] \
      && grep -q 'testArbitraryOutsiderSettlesExactBidWithoutNftDelivery' "$attempt" \
      && grep -q 'testCollectionWidePartialBidIsRepeatablyDrainedAcrossIds' "$attempt" \
      && grep -q 'testOneContractOrderFansOutAcrossThreeIndependentBuyers' "$attempt" \
      && grep -q 'testExplicitBuyerMinterIsSafeControl' "$attempt" \
      && grep -q 'testWithoutBuyerValidationEverythingRollsBack' "$attempt" \
      && ! grep -q '\[FAIL' "$attempt"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "$factory" "$fork_block" "$factory_seaport" "$seaport_hash" "PROVEN" >> "$OUT/scan.tsv"
      PROVEN=1
      SELECTED_NETWORK="$network"
      SELECTED_CHAIN="$chain_id"
      SELECTED_RPC="$rpc"
      SELECTED_FACTORY="$factory"
      SELECTED_BLOCK="$fork_block"
      SELECTED_LOG="$attempt"
      break 2
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "$factory" "$fork_block" "$factory_seaport" "$seaport_hash" "TEST_FAILED_RC_${rc}" >> "$OUT/scan.tsv"
    fi
  done
done

if [[ $PROVEN -eq 1 ]]; then
  cp "$SELECTED_LOG" "$OUT/forge-test.log"
  FACTORY_IMPL="$(cast call "$SELECTED_FACTORY" 'cloneableImplementation()(address)' --rpc-url "$SELECTED_RPC" --block "$SELECTED_BLOCK")"
  CONFIGURER="$(cast call "$SELECTED_FACTORY" 'configurer()(address)' --rpc-url "$SELECTED_RPC" --block "$SELECTED_BLOCK")"
  FACTORY_HASH="$(cast codehash "$SELECTED_FACTORY" --rpc-url "$SELECTED_RPC" --block "$SELECTED_BLOCK")"
  IMPL_HASH="$(cast codehash "$FACTORY_IMPL" --rpc-url "$SELECTED_RPC" --block "$SELECTED_BLOCK")"
  CONDUIT_HASH="$(cast codehash "$CONDUIT" --rpc-url "$SELECTED_RPC" --block "$SELECTED_BLOCK")"
  CONTROLLER_HASH="$(cast codehash "$CONTROLLER" --rpc-url "$SELECTED_RPC" --block "$SELECTED_BLOCK")"
  export SELECTED_NETWORK SELECTED_CHAIN SELECTED_FACTORY SELECTED_BLOCK FACTORY_IMPL CONFIGURER FACTORY_HASH IMPL_HASH CONDUIT_HASH CONTROLLER_HASH EXPECTED_HASH
  python3 - <<'PY' > "$OUT/MACHINE_VERDICT.json"
import json, os
print(json.dumps({
  "result": "OFFICIAL_SEADROP_SEAPORT_1_6_OUTSIDER_THEFT_PROVEN",
  "network": os.environ["SELECTED_NETWORK"],
  "chain_id": int(os.environ["SELECTED_CHAIN"]),
  "fork_block": int(os.environ["SELECTED_BLOCK"]),
  "seaport": "0x0000000000000068F116a894984e2DB1123eB395",
  "seaport_runtime_hash": os.environ["EXPECTED_HASH"],
  "conduit_controller": "0x00000000F9490004C11Cef243f5400493c00Ad63",
  "open_sea_conduit": "0x1e0049783f008a0085193e00003d00cd54003c71",
  "factory": os.environ["SELECTED_FACTORY"],
  "factory_runtime_hash": os.environ["FACTORY_HASH"],
  "cloneable_implementation": os.environ["FACTORY_IMPL"],
  "implementation_runtime_hash": os.environ["IMPL_HASH"],
  "configurer": os.environ["CONFIGURER"],
  "conduit_runtime_hash": os.environ["CONDUIT_HASH"],
  "controller_runtime_hash": os.environ["CONTROLLER_HASH"],
  "validated_tests": [
    "arbitrary outsider exact-id payment without delivery",
    "repeatable collection-wide criteria drain across identifiers",
    "three independent buyers drained by one contract order",
    "explicit buyer minter safe control",
    "missing buyer validation atomic rollback"
  ],
  "signed_zone_called": False,
  "buyer_order_type": "FULL_OPEN or PARTIAL_OPEN",
  "buyer_authorization": "direct Seaport self-validation",
  "payment_route": "canonical OpenSea Conduit",
}, indent=2))
PY
  echo 'OFFICIAL_SEADROP_SEAPORT_1_6_OUTSIDER_THEFT_PROVEN' > "$OUT/RESULT.txt"
  exit 0
fi

python3 - <<'PY' > "$OUT/MACHINE_VERDICT.json"
import json
print(json.dumps({
  "result": "NOT_PROVEN_IN_CURRENT_FACTORY_SCAN",
  "reason": "No scanned official factory and chain completed every exact-fork control.",
}, indent=2))
PY
echo 'NOT_PROVEN_IN_CURRENT_FACTORY_SCAN' > "$OUT/RESULT.txt"
exit 1
