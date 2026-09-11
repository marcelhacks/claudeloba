#!/usr/bin/env bash
set -euo pipefail
OUT=${1:-artifacts-optimism}
mkdir -p "$OUT"
RPCS=(https://mainnet.optimism.io https://optimism.drpc.org https://optimism-rpc.publicnode.com https://1rpc.io/op)
RPC=""
for r in "${RPCS[@]}"; do
  id="$(timeout 20s cast chain-id --rpc-url "$r" 2>/dev/null || true)"
  code="$(timeout 20s cast code 0x0000000000000068F116a894984e2DB1123eB395 --rpc-url "$r" 2>/dev/null || true)"
  if [[ "$id" == 10 && ${#code} -gt 40000 ]]; then RPC="$r"; break; fi
done
[[ -n "$RPC" ]] || { echo no-rpc >&2; exit 1; }
BLOCK=$(cast block-number --rpc-url "$RPC")
FACTORIES=(0x00b19A5200A100e5fc4c9800772f4d002f218400 0x000000F20032b9e171844B00EA507E11960BD94a)
SEAPORT=0x0000000000000068F116a894984e2DB1123eB395
CONTROLLER=0x00000000F9490004C11Cef243f5400493c00Ad63
CONDUIT=0x1e0049783f008a0085193e00003d00cd54003c71
jq -n --arg rpc "$RPC" --argjson block "$BLOCK" '{rpc:$rpc,block:$block,factories:[],targets:[]}' > "$OUT/state.json"
for a in "$SEAPORT" "$CONTROLLER" "$CONDUIT"; do
  code=$(cast code "$a" --rpc-url "$RPC")
  hash=$(cast keccak "$code")
  size=$(((${#code}-2)/2))
  jq --arg a "$a" --arg h "$hash" --argjson s "$size" '.targets += [{address:$a,codehash:$h,size:$s}]' "$OUT/state.json" > "$OUT/t" && mv "$OUT/t" "$OUT/state.json"
done
for f in "${FACTORIES[@]}"; do
  code=$(cast code "$f" --rpc-url "$RPC" 2>/dev/null || echo 0x)
  [[ "$code" != 0x ]] || continue
  hash=$(cast keccak "$code")
  sea=$(cast call "$f" 'seaport()(address)' --rpc-url "$RPC" 2>/dev/null || echo unavailable)
  cfg=$(cast call "$f" 'configurer()(address)' --rpc-url "$RPC" 2>/dev/null || echo unavailable)
  impl=$(cast call "$f" 'cloneableImplementation()(address)' --rpc-url "$RPC" 2>/dev/null || echo unavailable)
  jq --arg a "$f" --arg h "$hash" --arg sea "$sea" --arg cfg "$cfg" --arg impl "$impl" '.factories += [{address:$a,codehash:$h,seaport:$sea,configurer:$cfg,implementation:$impl}]' "$OUT/state.json" > "$OUT/t" && mv "$OUT/t" "$OUT/state.json"
done
cat "$OUT/state.json"
