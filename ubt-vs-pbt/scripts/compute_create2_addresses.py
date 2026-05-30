#!/usr/bin/env python3
"""Compute the CREATE2 addresses factorydeploytx deploys, and write contracts.json.

factorydeploytx deploys `count` copies of `init_code` via a CREATE2 factory using
salts start_salt..start_salt+count-1. Each address is the standard CREATE2:
    keccak(0xff || factory || salt(32) || keccak(init_code))[12:]

Run via uv so eth-hash is available:
    uv run --with "eth-hash[pycryptodome]" python compute_create2_addresses.py \
        <factory> <init_code_hex> <count> <out_json> [start_salt]
"""
import json
import sys

from eth_hash.auto import keccak


def main() -> None:
    factory_hex, init_code_hex, count, out_json = sys.argv[1:5]
    start_salt = int(sys.argv[5]) if len(sys.argv) > 5 else 0

    factory = bytes.fromhex(factory_hex.removeprefix("0x"))
    if len(factory) != 20:
        sys.exit(f"factory must be 20 bytes, got {len(factory)}")
    init_code = bytes.fromhex(init_code_hex.removeprefix("0x"))
    init_code_hash = keccak(init_code)

    addrs = []
    for i in range(int(count)):
        salt = (start_salt + i).to_bytes(32, "big")
        addr = keccak(b"\xff" + factory + salt + init_code_hash)[12:]
        addrs.append("0x" + addr.hex())

    with open(out_json, "w") as f:
        json.dump(addrs, f, indent=2)
    print(f"wrote {len(addrs)} CREATE2 addresses to {out_json} "
          f"(factory={factory_hex}, init_code_hash=0x{init_code_hash.hex()})")


if __name__ == "__main__":
    main()
