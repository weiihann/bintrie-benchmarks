"""Unit tests for build_initcode."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from build_initcode import (
    GETTER_RUNTIME,
    build_empty_account_initcode,
    build_getter_initcode,
)


def test_getter_runtime_matches_prior_campaign():
    """The runtime is the verified bytecode from prior factorydeploytx campaigns.

    Verified by decoding the prior campaign's initcode
    `0x600160005561001c60008160108239f3604035600d5801576000355450600b5801565b602035600035555b00`:
    constructor `60 01 60 00 55` SSTOREs slot 0, then `61 00 1c 60 00 81 60 10 82 39 f3`
    CODECOPYs 0x1c=28 bytes from offset 0x10 and RETURNs them — that's this runtime.
    """
    expected = bytes.fromhex(
        "604035600d5801576000355450600b5801565b602035600035555b00"
    )
    assert GETTER_RUNTIME == expected, GETTER_RUNTIME.hex()
    assert len(GETTER_RUNTIME) == 28


def test_getter_initcode_zero_stems_minimal():
    """num_stems=0 → constructor just returns the runtime."""
    code = build_getter_initcode(0)
    # Prelude (~12B) + runtime (28B) = ~40B; allow slack.
    assert 30 < len(code) < 60, len(code)
    assert GETTER_RUNTIME in code
    # Runtime is at the tail.
    assert code.endswith(GETTER_RUNTIME)


def test_getter_initcode_one_stem_adds_sstore():
    """num_stems=1 → exactly one SSTORE(0,1) (5B) before the prelude."""
    base = build_getter_initcode(0)
    one = build_getter_initcode(1)
    assert len(one) == len(base) + 5
    # First 5 bytes should be SSTORE(0,1): PUSH1 1 ; PUSH1 0 ; SSTORE
    assert one[:5] == bytes.fromhex("6001600055")


def test_getter_initcode_256_stems_size_in_range():
    """num_stems=256 → ~1.5KB; well under EIP-3860 cap (49152B)."""
    code = build_getter_initcode(256)
    # slot 0: 5B; slots 256..65280 (255 of them): 6B each
    # → 5 + 255*6 = 1535B of SSTOREs
    # + prelude (13B with PUSH2 for runtime_off) + runtime (28B) = 1576B total
    assert 1500 < len(code) < 1700, len(code)


def test_getter_initcode_256_pre_populates_at_byte_level():
    """Spot-check: first 5 bytes are SSTORE(0,1); next 6 bytes are SSTORE(256,1)."""
    code = build_getter_initcode(256)
    # SSTORE(0,1) = PUSH1 1 ; PUSH1 0 ; SSTORE = 0x60 0x01 0x60 0x00 0x55
    assert code[:5] == bytes.fromhex("6001600055")
    # SSTORE(256,1) = PUSH1 1 ; PUSH2 0x0100 ; SSTORE = 0x60 0x01 0x61 0x01 0x00 0x55
    assert code[5:11] == bytes.fromhex("600161010055")


def test_empty_account_initcode_is_tiny_stop_runtime():
    """Empty-account: deploys a 1-byte STOP runtime so the execute-specs
    address-stubs validator (which rejects 0-byte code) accepts the target."""
    code = build_empty_account_initcode()
    # Prelude (12B) + runtime STOP (1B) = 13 bytes total.
    expected = bytes.fromhex("6001600c600039600160006000f3").replace(
        bytes.fromhex("6000f3"), bytes.fromhex("00f3")
    )
    # Simpler explicit form:
    expected = bytes.fromhex("6001600c60003960016000f3" "00")
    assert code == expected, code.hex()
    assert len(code) == 13
    # Runtime byte (offset 12) is STOP.
    assert code[12] == 0x00
