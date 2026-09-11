#!/usr/bin/env bash
set -euo pipefail
mkdir -p artifact

factories=(
  0x00b19A5200A100e5fc4c9800772f4d002f218400
  0x000000F20032b9e171844B00EA507E11960BD94a
)
chains=(ethereum base polygon optimism arbitrum)
rpcs=(
  https://ethereum-rpc.publicnode.com
  https://base-rpc.publicnode.com
  https://polygon-bor-rpc.publicnode.com
  https://optimism-rpc.publicnode.com
  https://arbitrum-one-rpc.publicnode.com
)

printf '{"scans":[' > artifact/factory-state.json
first=1
for i in "${!chains[@]}"; do
  chain=${chains[$i]}
  rpc=${rpcs[$i]}
  block=$(cast block-number --rpc-url "$rpc")
  chain_id=$(cast chain-id --rpc-url "$rpc")
  for factory in "${factories[@]}"; do
    code=$(cast code "$factory" --rpc-url "$rpc")
    bytes=$(( (${#code} - 2) / 2 ))
    codehash=$(cast codehash "$factory" --rpc-url "$rpc" 2>/dev/null || printf '0x0')
    if [[ "$bytes" -gt 0 ]]; then
      seaport=$(cast call "$factory" 'seaport()(address)' --rpc-url "$rpc" 2>/dev/null || printf '<unavailable>')
      impl=$(cast call "$factory" 'cloneableImplementation()(address)' --rpc-url "$rpc" 2>/dev/null || printf '<unavailable>')
      configurer=$(cast call "$factory" 'configurer()(address)' --rpc-url "$rpc" 2>/dev/null || printf '<unavailable>')
      preview=$(cast call "$factory" 'createClone(string,string,bytes32)(address)' 'research-preview' 'RPREV' 0x18da23674c82cd7963a9f51854914712f7d38c62fe862000e341937d75fc5311 --from 0x000000000000000000000000000000000000beef --rpc-url "$rpc" 2>/dev/null || printf '<unavailable>')
      impl_code=$(cast code "$impl" --rpc-url "$rpc" 2>/dev/null || printf '0x')
      configurer_code=$(cast code "$configurer" --rpc-url "$rpc" 2>/dev/null || printf '0x')
      impl_hash=$(cast keccak "$impl_code" 2>/dev/null || printf '0x0')
      configurer_hash=$(cast keccak "$configurer_code" 2>/dev/null || printf '0x0')
    else
      seaport='<absent>'; impl='<absent>'; configurer='<absent>'; preview='<absent>'; impl_hash='0x0'; configurer_hash='0x0'
    fi
    [[ $first -eq 1 ]] || printf ',' >> artifact/factory-state.json
    first=0
    jq -cn \
      --arg chain "$chain" --argjson chain_id "$chain_id" --argjson block "$block" \
      --arg factory "$factory" --argjson bytes "$bytes" --arg codehash "$codehash" \
      --arg seaport "$seaport" --arg implementation "$impl" --arg configurer "$configurer" \
      --arg preview_clone "$preview" --arg implementation_hash "$impl_hash" --arg configurer_hash "$configurer_hash" \
      '{chain:$chain,chain_id:$chain_id,block:$block,factory:$factory,factory_code_bytes:$bytes,factory_codehash:$codehash,seaport:$seaport,implementation:$implementation,configurer:$configurer,preview_clone:$preview_clone,implementation_codehash:$implementation_hash,configurer_codehash:$configurer_hash}' \
      >> artifact/factory-state.json
  done
done
printf ']}' >> artifact/factory-state.json
jq . artifact/factory-state.json > artifact/factory-state.pretty.json
mv artifact/factory-state.pretty.json artifact/factory-state.json
sha256sum artifact/factory-state.json > artifact/SHA256SUMS.txt
