#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

SEAPORT = "0x0000000000000068f116a894984e2db1123eb395"
DEPLOY_TOPIC_SIGNATURE = "SeaDropTokenDeployed(uint8)"
ZERO = "0x0000000000000000000000000000000000000000"


def cast(*args: str) -> str:
    return subprocess.check_output(["cast", *args], text=True).strip()


def rpc(url: str, method: str, params: list[Any], timeout: int = 90) -> Any:
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    ).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "seadrop-scope-research"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(payload["error"])
    return payload["result"]


def selector(signature: str) -> str:
    return cast("sig", signature)


def split_words(raw: str) -> list[int]:
    if not raw or raw == "0x":
        return []
    data = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
    if len(data) % 32:
        return []
    return [int.from_bytes(data[i : i + 32], "big") for i in range(0, len(data), 32)]


def dynamic_words(raw: str) -> list[int]:
    values = split_words(raw)
    if len(values) < 2:
        return []
    offset = values[0] // 32
    if offset >= len(values):
        return []
    length = values[offset]
    start = offset + 1
    end = start + length
    if end > len(values):
        return []
    return values[start:end]


def eth_call(url: str, to: str, data: str, block: str = "latest") -> str:
    return rpc(url, "eth_call", [{"to": to, "data": data}, block])


def encode_u256(value: int) -> str:
    return value.to_bytes(32, "big").hex()


def call_array(url: str, token: str, signature: str) -> list[int]:
    return dynamic_words(eth_call(url, token, selector(signature)))


def call_u256(url: str, token: str, signature: str, arg: int) -> int | None:
    result = split_words(
        eth_call(url, token, selector(signature) + encode_u256(arg))
    )
    return result[0] if result else None


def call_address(url: str, token: str, signature: str) -> str:
    result = split_words(eth_call(url, token, selector(signature)))
    if not result:
        return ZERO
    return "0x" + result[0].to_bytes(32, "big")[-20:].hex()


def to_addresses(values: list[int]) -> list[str]:
    return ["0x" + value.to_bytes(32, "big")[-20:].hex() for value in values]


def logs_adaptive(
    url: str,
    topic: str,
    start: int,
    end: int,
    minimum_span: int = 64,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    try:
        result = rpc(
            url,
            "eth_getLogs",
            [{"fromBlock": hex(start), "toBlock": hex(end), "topics": [topic]}],
            timeout=120,
        )
        return result, []
    except Exception as exc:
        if end - start + 1 <= minimum_span:
            return [], [{"from": start, "to": end, "error": repr(exc)}]
        middle = (start + end) // 2
        left, left_errors = logs_adaptive(url, topic, start, middle, minimum_span)
        right, right_errors = logs_adaptive(
            url, topic, middle + 1, end, minimum_span
        )
        return left + right, left_errors + right_errors


@dataclass
class ActiveDrop:
    network: str
    chain_id: int
    block_number: int
    timestamp: int
    token: str
    token_code_hash: str
    owner: str
    allowed_seaports: list[str]
    drop_index: int
    start_price: int
    end_price: int
    start_time: int
    end_time: int
    restrict_fee_recipients: bool
    payment_token: str
    from_token_id: int
    to_token_id: int
    max_total_mintable_by_wallet: int
    max_total_mintable_by_wallet_per_token: int
    fee_bps: int
    allowed_fee_recipients: list[str]
    sample_token_id: int | None
    sample_max_supply: int | None
    sample_total_minted: int | None
    sample_has_capacity: bool | None


def inspect_token(
    network: str,
    chain_id: int,
    latest: int,
    timestamp: int,
    url: str,
    token: str,
) -> list[ActiveDrop]:
    code = rpc(url, "eth_getCode", [token, "latest"])
    if not code or code == "0x":
        return []
    code_hash = cast("keccak", code)

    try:
        allowed_seaports = to_addresses(
            call_array(url, token, "getAllowedSeaport()")
        )
    except Exception:
        return []
    if SEAPORT not in [value.lower() for value in allowed_seaports]:
        return []

    try:
        indexes = call_array(url, token, "getPublicDropIndexes()")
    except Exception:
        indexes = [0]
    if not indexes:
        return []

    try:
        owner = call_address(url, token, "owner()")
    except Exception:
        owner = ZERO

    try:
        allowed_fee_recipients = to_addresses(
            call_array(url, token, "getAllowedFeeRecipients()")
        )
    except Exception:
        allowed_fee_recipients = []

    active: list[ActiveDrop] = []
    get_drop = selector("getPublicDrop(uint256)")
    for index in indexes[:512]:
        try:
            values = split_words(
                eth_call(url, token, get_drop + encode_u256(index))
            )
        except Exception:
            continue
        if len(values) < 11:
            continue

        start_price, end_price = values[0], values[1]
        start_time, end_time = values[2], values[3]
        restrict_fee_recipients = values[4] != 0
        payment_token = "0x" + values[5].to_bytes(32, "big")[-20:].hex()
        from_id, to_id = values[6], values[7]
        max_wallet, max_wallet_id, fee_bps = values[8], values[9], values[10]

        if not (start_time <= timestamp < end_time):
            continue
        if from_id > to_id:
            continue
        if max_wallet == 0 or max_wallet_id == 0:
            continue
        if restrict_fee_recipients and not allowed_fee_recipients:
            continue

        sample_id = None
        sample_max = None
        sample_minted = None
        capacity = None
        last = min(to_id, from_id + 63)
        for token_id in range(from_id, last + 1):
            try:
                maximum = call_u256(url, token, "maxSupply(uint256)", token_id)
                minted = call_u256(url, token, "totalMinted(uint256)", token_id)
            except Exception:
                continue
            if maximum is None or minted is None:
                continue
            if minted < maximum:
                sample_id = token_id
                sample_max = maximum
                sample_minted = minted
                capacity = True
                break
        if sample_id is None:
            capacity = False

        active.append(
            ActiveDrop(
                network=network,
                chain_id=chain_id,
                block_number=latest,
                timestamp=timestamp,
                token=token,
                token_code_hash=code_hash,
                owner=owner,
                allowed_seaports=allowed_seaports,
                drop_index=index,
                start_price=start_price,
                end_price=end_price,
                start_time=start_time,
                end_time=end_time,
                restrict_fee_recipients=restrict_fee_recipients,
                payment_token=payment_token,
                from_token_id=from_id,
                to_token_id=to_id,
                max_total_mintable_by_wallet=max_wallet,
                max_total_mintable_by_wallet_per_token=max_wallet_id,
                fee_bps=fee_bps,
                allowed_fee_recipients=allowed_fee_recipients,
                sample_token_id=sample_id,
                sample_max_supply=sample_max,
                sample_total_minted=sample_minted,
                sample_has_capacity=capacity,
            )
        )
    return active


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", required=True)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--lookback", type=int, required=True)
    parser.add_argument("--chunk", type=int, default=10_000)
    parser.add_argument("--workers", type=int, default=10)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    chain_id = int(rpc(args.rpc, "eth_chainId", []), 16)
    latest = int(rpc(args.rpc, "eth_blockNumber", []), 16)
    latest_block = rpc(args.rpc, "eth_getBlockByNumber", [hex(latest), False])
    timestamp = int(latest_block["timestamp"], 16)
    topic = cast("keccak", DEPLOY_TOPIC_SIGNATURE)
    start = max(0, latest - args.lookback)

    ranges = [
        (cursor, min(cursor + args.chunk - 1, latest))
        for cursor in range(start, latest + 1, args.chunk)
    ]
    addresses: set[str] = set()
    failures: list[dict[str, Any]] = []

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.workers
    ) as executor:
        futures = {
            executor.submit(logs_adaptive, args.rpc, topic, first, last): (
                first,
                last,
            )
            for first, last in ranges
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                logs, errors = future.result()
                failures.extend(errors)
                for log in logs:
                    addresses.add(log["address"].lower())
            except Exception as exc:
                first, last = futures[future]
                failures.append(
                    {"from": first, "to": last, "error": repr(exc)}
                )

    active: list[ActiveDrop] = []
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.workers
    ) as executor:
        futures = {
            executor.submit(
                inspect_token,
                args.network,
                chain_id,
                latest,
                timestamp,
                args.rpc,
                token,
            ): token
            for token in sorted(addresses)
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                active.extend(future.result())
            except Exception as exc:
                failures.append(
                    {"token": futures[future], "error": repr(exc)}
                )

    result = {
        "network": args.network,
        "chain_id": chain_id,
        "latest_block": latest,
        "timestamp": timestamp,
        "scan_start": start,
        "scan_end": latest,
        "event_topic": topic,
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
