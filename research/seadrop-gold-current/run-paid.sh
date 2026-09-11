#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="${RUNNER_TEMP:-/tmp}/official-seadrop-paid-lab"
OUT="$ROOT/results/paid"
SEAPORT="0x0000000000000068F116a894984e2DB1123eB395"
CONDUIT="0x1e0049783f008a0085193e00003d00cd54003c71"
CONTROLLER="0x00000000F9490004C11Cef243f5400493c00Ad63"
EXPECTED_HASH="0x74499ac0cce14428e4b41541d5e44f28f5a6882a1051d0118867c2a93cd5aec0"

rm -rf "$LAB" "$OUT"
mkdir -p "$LAB/test" "$LAB/src" "$LAB/lib" "$OUT/attempts"
cp "$ROOT/OfficialFactoryFork.t.sol" "$LAB/test/OfficialFactoryFork.t.sol"
cp "$ROOT/OfficialPaidDropForkV2.t.sol" "$LAB/test/OfficialPaidDropForkV2.t.sol"
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
for spec in "${NETWORKS[@]}"; do
  IFS='|' read -r network rpc <<< "$spec"
  chain_id="$(timeout 30 cast chain-id --rpc-url "$rpc" 2>/dev/null || true)"
  latest="$(timeout 30 cast block-number --rpc-url "$rpc" 2>/dev/null || true)"
  [[ -n "$chain_id" && -n "$latest" ]] || continue
  fork_block=$((latest > 32 ? latest - 32 : latest))
  seaport_hash="$(timeout 30 cast codehash "$SEAPORT" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
  [[ "${seaport_hash,,}" == "${EXPECTED_HASH,,}" ]] || continue
  [[ "$(cast code "$CONDUIT" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)" != "0x" ]] || continue
  [[ "$(cast code "$CONTROLLER" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)" != "0x" ]] || continue

  for factory in "${FACTORIES[@]}"; do
    [[ "$(cast code "$factory" --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)" != "0x" ]] || continue
    factory_seaport="$(cast call "$factory" 'seaport()(address)' --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || true)"
    if [[ "${factory_seaport,,}" != "${SEAPORT,,}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "$factory" "$fork_block" "$factory_seaport" "$seaport_hash" "FACTORY_NOT_1_6" >> "$OUT/scan.tsv"
      continue
    fi

    log="$OUT/attempts/${network}-${factory}.log"
    set +e
    RPC_URL="$rpc" FORK_BLOCK="$fork_block" SEADROP_FACTORY="$factory" \
      timeout 1200 forge test \
        --root "$LAB" \
        --match-contract OfficialPaidDropForkV2Test \
        -vvvv > "$log" 2>&1
    rc=$?
    set -e

    if [[ $rc -eq 0 ]] \
      && grep -q 'testPaidMintIsVictimFundedAndResidualGoesToOutsider' "$log" \
      && grep -q 'testBidEqualToMintPriceStillTransfersBuyerPaymentWithoutDelivery' "$log" \
      && grep -q 'testExplicitBuyerMinterIsSafePaidControl' "$log" \
      && ! grep -q '\[FAIL' "$log"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "$factory" "$fork_block" "$factory_seaport" "$seaport_hash" "PROVEN" >> "$OUT/scan.tsv"
      cp "$log" "$OUT/forge-test.log"
      export network chain_id factory fork_block factory_seaport seaport_hash
      python3 - <<'PY' > "$OUT/MACHINE_VERDICT.json"
import json, os
print(json.dumps({
  "result": "OFFICIAL_PAID_SEADROP_VICTIM_FUNDED_OUTSIDER_THEFT_PROVEN",
  "network": os.environ["network"],
  "chain_id": int(os.environ["chain_id"]),
  "fork_block": int(os.environ["fork_block"]),
  "factory": os.environ["factory"],
  "factory_seaport": os.environ["factory_seaport"],
  "seaport_runtime_hash": os.environ["seaport_hash"],
  "mint_price": "300 ether-equivalent WETH",
  "buyer_bid": "1000 WETH",
  "honest_creator_gain": "300 WETH",
  "attacker_residual_gain": "700 WETH",
  "attacker_nft_gain": 1,
  "buyer_nft_gain": 0,
  "signed_zone_called": False,
  "buyer_authorization": "standard EIP-712 FULL_OPEN signature",
  "payment_route": "canonical OpenSea Conduit",
  "controls": [
    "bid equals mint price still loses NFT",
    "explicit buyer minter delivers correctly"
  ]
}, indent=2))
PY
      echo OFFICIAL_PAID_SEADROP_VICTIM_FUNDED_OUTSIDER_THEFT_PROVEN > "$OUT/RESULT.txt"
      PROVEN=1
      break 2
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$network" "$chain_id" "$factory" "$fork_block" "$factory_seaport" "$seaport_hash" "TEST_FAILED_RC_${rc}" >> "$OUT/scan.tsv"
  done
done

if [[ $PROVEN -eq 0 ]]; then
  echo NOT_PROVEN_IN_PAID_FACTORY_SCAN > "$OUT/RESULT.txt"
  printf '{"result":"NOT_PROVEN_IN_PAID_FACTORY_SCAN"}\n' > "$OUT/MACHINE_VERDICT.json"
  exit 1
fi
