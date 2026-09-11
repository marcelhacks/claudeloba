#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-artifacts}"
mkdir -p "$OUT_DIR"

RPCS=(
  "https://polygon-bor-rpc.publicnode.com"
  "https://polygon-rpc.com"
  "https://1rpc.io/matic"
  "https://polygon.drpc.org"
  "https://rpc.ankr.com/polygon"
)
RPC=""
for candidate in "${RPCS[@]}"; do
  id="$(timeout 20s cast chain-id --rpc-url "$candidate" 2>/dev/null || true)"
  if [[ "$id" == "137" ]]; then RPC="$candidate"; break; fi
done
[[ -n "$RPC" ]] || { echo "no Polygon RPC" >&2; exit 1; }

BLOCK="$(cast block-number --rpc-url "$RPC")"
printf '%s\n' "$RPC" > "$OUT_DIR/rpc.txt"
printf '%s\n' "$BLOCK" > "$OUT_DIR/block.txt"

SEAPORT=0x0000000000000068F116a894984e2DB1123eB395
CONTROLLER=0x00000000F9490004C11Cef243f5400493c00Ad63
CONDUIT=0x1e0049783f008a0085193e00003d00cd54003c71
IMPLEMENTATION=0x0D223D05e1cC4aC20De7fce86bC9bb8EFB56F4D4
CONFIGURER=0x5F8D647Ff69bE85fe2f005867Fbb552C623928c5
TOKENS=(
  0x257f5C0BBC504200f3DC486C1e941E4A0ae1b6EB
  0xbcf7b02adadcb1dbe15cd8097b09e7390d0d2897
  0x3f0e7ace609ac0b67eb1f715eec47fd55ab7aacc
  0x3aa5659f9fe28e9305457bf19d864871f8ae2a35
  0xcE60Bd7be92769F7553DB766cb4C970374bA1551
  0xCDed3b1A277D5467dfFbffb85EA97c134F6B2dD5
)

jq -n --arg rpc "$RPC" --argjson block "$BLOCK" '{rpc:$rpc,block:$block,contracts:[],tokens:[]}' > "$OUT_DIR/state.json"

for address in "$SEAPORT" "$CONTROLLER" "$CONDUIT" "$IMPLEMENTATION" "$CONFIGURER"; do
  code="$(cast code "$address" --block "$BLOCK" --rpc-url "$RPC")"
  codehash="$(cast codehash "$address" --block "$BLOCK" --rpc-url "$RPC")"
  bytes=$(( (${#code} - 2) / 2 ))
  jq --arg address "$address" --arg codehash "$codehash" --argjson bytes "$bytes" \
    '.contracts += [{address:$address,codehash:$codehash,bytes:$bytes}]' "$OUT_DIR/state.json" > "$OUT_DIR/state.tmp"
  mv "$OUT_DIR/state.tmp" "$OUT_DIR/state.json"
done

for token in "${TOKENS[@]}"; do
  code="$(cast code "$token" --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo 0x)"
  [[ "$code" != 0x ]] || continue
  codehash="$(cast codehash "$token" --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo null)"
  name="$(cast call "$token" 'name()(string)' --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo '<unavailable>')"
  owner="$(cast call "$token" 'owner()(address)' --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo '<unavailable>')"
  configurer="$(cast call "$token" 'configurer()(address)' --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo '<unavailable>')"
  allowed="$(cast call "$token" 'getAllowedSeaport()(address[])' --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo '<unavailable>')"
  indexes="$(cast call "$token" 'getPublicDropIndexes()(uint256[])' --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo '<unavailable>')"

  token_json="$(jq -n --arg address "$token" --arg codehash "$codehash" --arg name "$name" --arg owner "$owner" --arg configurer "$configurer" --arg allowed "$allowed" --arg indexes "$indexes" '{address:$address,codehash:$codehash,name:$name,owner:$owner,configurer:$configurer,allowedSeaport:$allowed,publicDropIndexes:$indexes,drops:[]}')"

  if [[ "$indexes" != '<unavailable>' ]]; then
    for idx in $(tr -d '[],' <<<"$indexes"); do
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      raw="$(cast call "$token" 'getPublicDrop(uint256)((uint80,uint80,uint40,uint40,bool,address,uint24,uint24,uint16,uint16,uint16))' "$idx" --block "$BLOCK" --rpc-url "$RPC" 2>/dev/null || echo '<unavailable>')"
      token_json="$(jq --arg idx "$idx" --arg raw "$raw" '.drops += [{index:$idx,raw:$raw}]' <<<"$token_json")"
    done
  fi

  jq --argjson item "$token_json" '.tokens += [$item]' "$OUT_DIR/state.json" > "$OUT_DIR/state.tmp"
  mv "$OUT_DIR/state.tmp" "$OUT_DIR/state.json"
done

cat "$OUT_DIR/state.json"
