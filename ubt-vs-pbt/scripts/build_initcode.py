"""Generate initcode bytes for the locality-sweep campaign's two contract types.

Outputs:
    build_getter_initcode(num_stems)  →  getter with `num_stems` pre-populated stems
                                          for cold-SLOAD targets in storage benchmarks.
    build_empty_account_initcode()    →  0-byte-runtime contract for account benchmarks
                                          (CALL touches only basic-data, no code/storage).

Getter runtime (verified by decoding prior campaign initcode):
    if calldataload(64): sstore(calldataload(0), calldataload(32))
    else:                 sload(calldataload(0)); pop
    stop

Constructor (this module's role):
    for i in [0, num_stems):
        sstore(i * 256, 1)             # populate slot 0 of each stem
    codecopy(0, runtime_offset, runtime_len)
    return(0, runtime_len)
"""

from __future__ import annotations

# Verified runtime bytecode from the prior campaign's deployed getter
# (decoded from `0x600160005561001c60008160108239f3<runtime>`).
GETTER_RUNTIME = bytes.fromhex("604035600d5801576000355450600b5801565b602035600035555b00")


def _push_int(value: int) -> bytes:
    """Smallest PUSH for an unsigned int. Caller ensures value < 2**24."""
    if value < 0:
        raise ValueError(f"negative: {value}")
    if value < 256:
        return bytes([0x60, value])  # PUSH1
    if value < 65536:
        return bytes([0x61, (value >> 8) & 0xFF, value & 0xFF])  # PUSH2
    if value < 16777216:
        return bytes([0x62, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF])  # PUSH3
    raise ValueError(f"too large for PUSH3: {value}")


def _sstore_op(slot: int, value: int = 1) -> bytes:
    """SSTORE value to slot. Stack push order: value first, then slot, then SSTORE."""
    return _push_int(value) + _push_int(slot) + bytes([0x55])


def _return_runtime_prelude(pre_population_len: int, runtime_len: int) -> bytes:
    """Constructor tail: CODECOPY(0, runtime_off, runtime_len) ; RETURN(0, runtime_len).

    Layout: [pre_population][prelude][runtime]; runtime_off = pre_population_len + len(prelude).
    The prelude width depends on the PUSH width needed for runtime_off, which itself
    depends on the prelude width — iterate until stable (max 2 iterations in practice).
    """
    prelude_len_guess = 12  # assume PUSH1 for runtime_off
    while True:
        runtime_off = pre_population_len + prelude_len_guess
        prelude = (
            _push_int(runtime_len)
            + _push_int(runtime_off)
            + bytes([0x60, 0x00])  # PUSH1 0 (dest)
            + bytes([0x39])  # CODECOPY
            + _push_int(runtime_len)
            + bytes([0x60, 0x00])  # PUSH1 0 (offset)
            + bytes([0xF3])  # RETURN
        )
        if len(prelude) == prelude_len_guess:
            return prelude
        prelude_len_guess = len(prelude)


def build_getter_initcode(num_stems: int) -> bytes:
    """Constructor pre-populates `num_stems` stems (slots 0, 256, ..., 256*(num_stems-1))."""
    if num_stems < 0:
        raise ValueError(num_stems)
    pre_pop = b"".join(_sstore_op(i * 256, 1) for i in range(num_stems))
    prelude = _return_runtime_prelude(len(pre_pop), len(GETTER_RUNTIME))
    return pre_pop + prelude + GETTER_RUNTIME


def build_empty_account_initcode() -> bytes:
    """Constructor: returns a 1-byte STOP runtime.

    A truly 0-byte runtime would trip execution-specs' address-stubs validator
    (it queries eth_getCode and refuses stubs without code unless they're EOAs).
    1 byte of STOP keeps the account "minimal" — BALANCE never invokes code, and
    a CALL with value=1 only adds one code-chunk read per recipient, which both
    UBT and PBT pay equally.
    """
    # Layout: [prelude 12B][runtime 1B]
    # prelude: PUSH1 1 (size) ; PUSH1 12 (runtime offset) ; PUSH1 0 (dest) ;
    #          CODECOPY ; PUSH1 1 ; PUSH1 0 ; RETURN
    # runtime: STOP (0x00)
    return bytes([
        0x60, 0x01,  # PUSH1 1 (runtime size)
        0x60, 0x0C,  # PUSH1 12 (runtime offset)
        0x60, 0x00,  # PUSH1 0 (dest)
        0x39,        # CODECOPY
        0x60, 0x01,  # PUSH1 1 (return size)
        0x60, 0x00,  # PUSH1 0 (return offset)
        0xF3,        # RETURN
        0x00,        # runtime: STOP
    ])


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2 or sys.argv[1] not in ("getter", "empty"):
        print("Usage: build_initcode.py {getter NUM_STEMS | empty}", file=sys.stderr)
        sys.exit(1)
    if sys.argv[1] == "getter":
        n = int(sys.argv[2])
        code = build_getter_initcode(n)
    else:
        code = build_empty_account_initcode()
    print("0x" + code.hex())
