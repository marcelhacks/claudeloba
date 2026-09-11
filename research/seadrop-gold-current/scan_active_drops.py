#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import time
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

SEAPORT = "0x0000000000000068f116a894984e2db1123eb395"
EVENT_SIGNATURE = "SeaDropTokenDeployed(uint8)"


def cast(*args: str) -> str:
    return subprocess.check_output(["cast", *args], text=True).strip()


def rpc(url: str, method: str, params: list[Any], timeout: int = 60) -> Any:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    ).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "seadrop-research"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        decoded = json.load(response)
    if "error" in decoded:
        raise RuntimeError(decoded["error"])
    return decoded["result"]


def selector(signature: str) -> str:
    return cast("sig", signature)


def words(raw: str) -> list[int]:
    if not raw or raw == "0x":
        return []
    data = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
    if len(data) % 32:
        return []
    return [int.from_bytes(data[i : i + 32], "big") for i in range(0, len(data), 32)]


def decode_dynamic_words(raw: str) -> list[int]:
    values = words(raw)
    if len(values) < 2:
        return []
    offset_words = values[0] // 32
    if offset_words >= len(values):
        return []
    length = values[offset_words]
    start = offset_words + 1
    end = start + length
    if end > len(values):
        return []
    return values[start:end]


def eth_call(url: str, to: str, data: str, block: str = "latest") -> str:
    return rpc(url, "eth_call", [{"to": to, "data": data}, block])


@dataclass
class ActiveDrop:
    network: str
    chain_id: int
    block_number: int
    timestamp: int
    token: str
    owner: str
    allowed_seaports: list[str]
    drop_index: int
    start_price: int
    end_price: int
    start_time: int
    end_time: int
    payment_token: str
    from_token_id: int
    to_token_id: int
    max_total_mintable_by_wallet: int
    max_total_mintable_by_wallet_per_token: int
    fee_bps: int
    sample_token_id: int | None
    sample_max_supply: int | None
    sample_total_minted: int | None
    sample_has_capacity: bool | None


def call_address_array(url: str, token: str, sig: str) -> list[str]:
    raw = eth_call(url, token, selector(sig))
    return ["0x" + value.to_bytes(32, "big")[-20:].hex() for value in decode_dynamic_words(raw)]


def call_uint_array(url: str, token: str, sig: str) -> list[int]:
    return decode_dynamic_words(eth_call(url, token, selector(sig)))


def call_address(url: str, token: str, sig: str) -> str:
    values = words(eth_call(url, token, selector(sig)))
    if not values:
        return "0x0000000000000000000000000000000000000000"
    return "0x" + values[0].to_bytes(32, "big")[-20:].hex()


def call_uint(url: str, token: str, sig: str, value: int) -> int | None:
    data = selector(sig) + value.to_bytes(32, "big").hex()
    values = words(eth_call(url, token, data))
    return values[0] if values else None


def inspect_candidate(
    network: str,
    chain_id: int,
    block_number: int,
    timestamp: int,
    url: str,
    token: str,
) -> list[ActiveDrop]:
    code = rpc(url, "eth_getCode", [token, "latest"])
    if code in (None, "0x"):
        return []

    try:
        allowed = call_address_array(url, token, "getAllowedSeaport()")
    except Exception:
        return []
    if SEAPORT not in [item.lower() for item in allowed]:
        return []

    try:
        indexes = call_uint_array(url, token, "getPublicDropIndexes()")
    except Exception:
        indexes = [0]

    try:
        owner = call_address(url, token, "owner()")
    except Exception:
        owner = "0x0000000000000000000000000000000000000000"

    active: list[ActiveDrop] = []
    get_drop_selector = selector("getPublicDrop(uint256)")
    for index in indexes[:256]:
        try:
            data = get_drop_selector + index.to_bytes(32, "big").hex()
            values = words(eth_call(url, token, data))
        except Exception:
            continue
        if len(values) < 11:
            continue

        start_price, end_price = values[0], values[1]
        start_time, end_time = values[2], values[3]
        payment_token = "0x" + values[5].to_bytes(32, "big")[-20:].hex()
        from_id, to_id = values[6], values[7]
        max_wallet, max_wallet_token = values[8], values[9]
        fee_bps = values[10]

        if not (start_time <= timestamp < end_time):
            continue
        if from_id > to_id:
            continue

        sample_id = from_id
        sample_max = None
        sample_minted = None
        capacity = None
        try:
            sample_max = call_uint(url, token, "maxSupply(uint256)", sample_id)
            sample_minted = call_uint(url, token, "totalMinted(uint256)", sample_id)
            if sample_max is not None and sample_minted is not None:
                capacity = sample_minted < sample_max
        except Exception:
            pass

        active.append(
            ActiveDrop(
                network=network,
                chain_id=chain_id,
                block_number=block_number,
                timestamp=timestamp,
                token=token,
                owner=owner,
                allowed_seaports=allowed,
                drop_index=index,
                start_price=start_price,
                end_price=end_price,
                start_time=start_time,
                end_time=end_time,
                payment_token=payment_token,
                from_token_id=from_id,
                to_token_id=to_id,
                max_total_mintable_by_wallet=max_wallet,
                max_total_mintable_by_wallet_per_token=max_wallet_token,
                fee_bps=fee_bps,
                sample_token_id=sample_id,
                sample_max_supply=sample_max,
                sample_total_minted=sample_minted,
                sample_has_capacity=capacity,
            )
        )
    return active


def get_logs_chunk(url: str, topic: str, start: int, end: int) -> list[dict[str, Any]]:
    return rpc(
        url,
        "eth_getLogs",
        [
            {
                "fromBlock": hex(start),
                "toBlock": hex(end),
                "topics": [topic],
            }
        ],
        timeout=90,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", required=True)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--lookback", type=int, default=12_000_000)
    parser.add_argument("--chunk", type=int, default=20_000)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    chain_id = int(rpc(args.rpc, "eth_chainId", []), 16)
    latest = int(rpc(args.rpc, "eth_blockNumber", []), 16)
    block = rpc(args.rpc, "eth_getBlockByNumber", [hex(latest), False])
    timestamp = int(block["timestamp"], 16)
    topic = cast("keccak", EVENT_SIGNATURE)

    start = max(0, latest - args.lookback)
    ranges = [
        (cursor, min(cursor + args.chunk - 1, latest))
        for cursor in range(start, latest + 1, args.chunk)
    ]

    addresses: set[str] = set()
    failures: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        future_map = {
            executor.submit(get_logs_chunk, args.rpc, topic, first, last): (first, last)
            for first, last in ranges
        }
        for future in concurrent.futures.as_completed(future_map):
            first, last = future_map[future]
            try:
                for log in future.result():
                    addresses.add(log["address"].lower())
            except Exception as exc:
                failures.append({"from": first, "to": last, "error": repr(exc)})

    active: list[ActiveDrop] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        future_map = {
            executor.submit(
                inspect_candidate,
                args.network,
                chain_id,
                latest,
                timestamp,
                args.rpc,
                address,
            ): address
            for address in sorted(addresses)
        }
        for future in concurrent.futures.as_completed(future_map):
            address = future_map[future]
            try:
                active.extend(future.result())
            except Exception as exc:
                failures.append({"token": address, "error": repr(exc)})

    result = {
        "network": args.network,
        "chain_id": chain_id,
        "latest_block": latest,
        "timestamp": timestamp,
        "event_topic": topic,
        "scan_start": start,
        "scan_end": latest,
        "candidate_contracts": len(addresses),
        "active_seaport_1_6_drops": [asdict(item) for item in active],
        "failures": failures,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
