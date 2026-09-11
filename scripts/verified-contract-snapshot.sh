#!/usr/bin/env bash
set -euo pipefail
mkdir -p verified-snapshot
RPC=https://ethereum-rpc.publicnode.com
addresses=(
  0x00b19A5200A100e5fc4c9800772f4d002f218400
  0x9f36ee33fd56c7d9A78facD3249c580b1Ca464a2
  0x864BaA13E01d8f9E26549dc91B458CD15E34EB7c
  0x0000000000000068F116a894984e2DB1123eB395
  0x00000000F9490004C11Cef243f5400493c00Ad63
  0x1e0049783f008a0085193e00003d00cd54003c71
)
for address in "${addresses[@]}"; do
  lower=$(printf '%s' "$address" | tr '[:upper:]' '[:lower:]')
  cast code "$address" --rpc-url "$RPC" > "verified-snapshot/${lower}.runtime.hex"
  curl --fail --location --retry 4 --retry-delay 2 \
    "https://eth.blockscout.com/api/v2/smart-contracts/${address}" \
    -o "verified-snapshot/${lower}.blockscout.json" || true
  curl --fail --location --retry 4 --retry-delay 2 \
    "https://repo.sourcify.dev/contracts/full_match/1/${address}/metadata.json" \
    -o "verified-snapshot/${lower}.sourcify-metadata.json" || true
  curl --fail --location --retry 4 --retry-delay 2 \
    "https://repo.sourcify.dev/contracts/partial_match/1/${address}/metadata.json" \
    -o "verified-snapshot/${lower}.sourcify-partial-metadata.json" || true
done
find verified-snapshot -type f -size 0 -delete
sha256sum verified-snapshot/* | sort > verified-snapshot/SHA256SUMS.txt
