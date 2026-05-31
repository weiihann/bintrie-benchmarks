# UBT vs PBT Locality Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the 16-cell K-sweep campaign (storage_{sload,sstore,mixed} × K∈{1,10,100,256} plus account_{balance_read,transfer} × K∈{10,256}) and produce a `ratio_vs_K` headline report comparing UBT and PBT.

**Architecture:** Parametrize the existing run_campaign / run_benchmarks scripts on `K`; emit one cell-tagged geth log per (benchmark, K, run). Reuse spamoor `factorydeploytx` for two deploy sets (256 getter contracts with pre-populated stems + 256 empty-code contracts for account-zone probing). Replace the single `test_scattered_storage.py` with `test_locality_sweep.py` + `test_account_locality.py`. Add a `ratio_vs_K` graph generator. Everything else (DB-gen, cache drop, sudo rule, extract_csv, analyze_data, same-state gate) reused as-is.

**Tech Stack:** bash, Python (uv-managed), pytest via execution-specs `execute remote`, geth flat-state branches, state-actor, spamoor factorydeploytx.

**Spec:** `/home/weiihann/.claude/plans/there-should-be-instructions-cryptic-axolotl.md` (also committed to repo at `ubt-vs-pbt/SPEC-locality-sweep.md` in Task A2).

---

## File Structure

**execution-specs** (`/mnt/state_expiry_vol_data/execution-specs/tests/benchmark/stateful/bloatnet/`):
- NEW `test_locality_sweep.py` — 3 storage benchmarks parametrized by K via `LOCALITY_K` env. Replaces `test_scattered_storage.py`.
- NEW `test_account_locality.py` — 2 account benchmarks (balance_read, transfer) parametrized by K via `LOCALITY_K`.
- DELETE `test_scattered_storage.py`, `test_getter_proto.py`, `test_storage_sweep_proto.py` (superseded / prototypes).

**bintrie-benchmarks** (`/mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/`):
- NEW `scripts/build_initcode.py` — generates getter + empty-account initcode given a stem count.
- NEW `scripts/tests/test_build_initcode.py` — unit tests for the above.
- MODIFY `scripts/generate_dbs.sh` — call `build_initcode.py` for both getter (256 stems) + empty-account (0 stems) initcodes; deploy both sets via spamoor; emit `contracts.json` (getters) and `accounts.json` (empties).
- MODIFY `scripts/run_benchmarks.sh` — iterate (benchmark, K) pairs; rename BENCH_NAMES to include `_k${K}`; pass `LOCALITY_K`; flip `--dev.period 10 → 1`; default `GAS_BENCHMARK_VALUE 16 → 6`; expose accounts.json stubs to account benchmarks.
- MODIFY `scripts/run_campaign.sh` — add `K_VALUES` and `K_VALUES_ACCOUNT` env vars; default benchmark list to the 6 new names (storage_sload, storage_sstore, storage_mixed, account_balance_read, account_transfer — script per-cell expands by K).
- MODIFY `scripts/generate_graphs.py` — add `plot_ratio_vs_k()` (the headline) + `plot_account_sidecar()`; existing per-benchmark bar charts can stay or be dropped — pick a subset that still tells the story.
- MODIFY `index.html` — rewrite scope as "locality sweep"; new ratio_vs_K + account_sidecar figures; cite K=1 and K=256 against prior concentrated/scattered numbers.
- MODIFY top-level `README.md` — update UBT-vs-PBT blurb with the ratio-vs-K finding.
- KEEP `scripts/compute_create2_addresses.py`, `scripts/analyze_data.py`, `scripts/extract_csv.py` reused as-is.

---

## Tasks

### Phase A: Repo prep + branch

#### Task A1: Sync repos, verify binaries

- [ ] **Step 1: Pull bintrie-benchmarks latest, confirm clean**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks
git status
git log --oneline -3
```
Expected: working tree clean except untracked logs / data-cal / generate_dbs.sh staged-modify (pre-existing, can be discarded after we re-edit).

- [ ] **Step 2: Discard the dangling generate_dbs.sh mod (we rewrite it anyway)**

```bash
git checkout -- ubt-vs-pbt/scripts/generate_dbs.sh
git status
```
Expected: only untracked logs remain.

- [ ] **Step 3: Verify the four flat-state binaries exist and version**

```bash
ls -la /tmp/bench-bins/geth-flat-state /tmp/bench-bins/geth-pbt-flat-state \
       /tmp/bench-bins/state-actor-flat-state /tmp/bench-bins/state-actor-pbt-flat-state
/tmp/bench-bins/geth-flat-state version 2>&1 | grep -E "(Version|Git Commit)" | head -4
/tmp/bench-bins/geth-pbt-flat-state version 2>&1 | grep -E "(Version|Git Commit)" | head -4
```
Expected: 4 files present, version blocks for both geths.

#### Task A2: Create campaign branch + commit spec

- [ ] **Step 1: Branch off `pbt`**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks
git checkout -b feat/locality-sweep pbt
```

- [ ] **Step 2: Copy spec into repo**

```bash
cp /home/weiihann/.claude/plans/there-should-be-instructions-cryptic-axolotl.md \
   ubt-vs-pbt/SPEC-locality-sweep.md
```

- [ ] **Step 3: Commit spec + this plan**

```bash
git add ubt-vs-pbt/SPEC-locality-sweep.md ubt-vs-pbt/PLAN-locality-sweep.md
git commit -m "ubt-vs-pbt: spec + plan — locality sweep campaign"
```
Expected: one commit on `feat/locality-sweep`.

---

### Phase B: Build initcode generator (Python, TDD)

Produces two initcodes used by `generate_dbs.sh`:
- **Getter** (256 pre-populated stems): runtime accepts `[slot, value, isWrite]`; constructor `SSTORE(256*i, 1)` for `i ∈ [0, 256)`.
- **Empty account** (0 stems): runtime is 0-byte (no code); constructor just `STOP` after returning empty runtime.

The same module emits both: `build_getter_initcode(num_stems)` and `build_empty_account_initcode()`.

#### Task B1: Tests for `build_initcode.py`

**Files:**
- Create: `ubt-vs-pbt/scripts/tests/__init__.py` (empty)
- Create: `ubt-vs-pbt/scripts/tests/test_build_initcode.py`

- [ ] **Step 1: Write failing tests**

```python
# ubt-vs-pbt/scripts/tests/test_build_initcode.py
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
    """The runtime is the verified bytecode from prior factorydeploytx campaigns."""
    # Runtime that does: if calldataload(64) SSTORE(cdl(0), cdl(32)) else POP(SLOAD(cdl(0))) ; STOP
    # Compiled from test_getter_proto.py in the prior session.
    expected = bytes.fromhex(
        "604035600d5801576000355450600b5801565b602035600035555b00"
    )
    assert GETTER_RUNTIME == expected, GETTER_RUNTIME.hex()


def test_getter_initcode_zero_stems_minimal():
    """num_stems=0 → constructor just returns the runtime."""
    code = build_getter_initcode(0)
    # Prelude (≤13B) + runtime (28B). Total well under 100B.
    assert 30 < len(code) < 60, len(code)
    # The returned initcode must contain the runtime as a suffix slice.
    assert GETTER_RUNTIME in code


def test_getter_initcode_one_stem_adds_sstore():
    """num_stems=1 → exactly one SSTORE(0,1) before the prelude."""
    code = build_getter_initcode(1)
    # One SSTORE(0,1): PUSH1 1 ; PUSH1 0 ; SSTORE = 5 bytes
    assert len(code) == len(build_getter_initcode(0)) + 5


def test_getter_initcode_256_stems_size_in_range():
    """num_stems=256 → ~1.5KB; well under EIP-3860 cap (49152B)."""
    code = build_getter_initcode(256)
    # slot 0: 5 bytes; slots 256..65280 (255 of them): 6 bytes each
    # → 5 + 255*6 = 1535 bytes of SSTOREs
    # + prelude (~13B) + runtime (28B) ≈ 1576B total
    assert 1500 < len(code) < 1700, len(code)


def test_getter_initcode_256_pre_populates_at_byte_level():
    """Spot-check: first 5 bytes are SSTORE(0,1); next 6 bytes are SSTORE(256,1)."""
    code = build_getter_initcode(256)
    # SSTORE(0,1) = PUSH1 1, PUSH1 0, SSTORE = 0x60 0x01 0x60 0x00 0x55
    assert code[:5] == bytes.fromhex("6001600055")
    # SSTORE(256,1) = PUSH1 1, PUSH2 0x0100, SSTORE = 0x60 0x01 0x61 0x01 0x00 0x55
    assert code[5:11] == bytes.fromhex("600161010055")


def test_empty_account_initcode_is_tiny():
    """Empty-account: deploys 0-byte runtime so target exists in basic-data with no code."""
    code = build_empty_account_initcode()
    # PUSH1 0 ; PUSH1 0 ; RETURN  →  3 bytes
    assert code == bytes.fromhex("60006000f3")
```

- [ ] **Step 2: Run tests, expect ImportError**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/scripts
python3 -m pytest tests/test_build_initcode.py -v
```
Expected: ImportError on `build_initcode` (module not yet written).

#### Task B2: Implement `build_initcode.py`

**Files:**
- Create: `ubt-vs-pbt/scripts/build_initcode.py`

- [ ] **Step 1: Write `build_initcode.py`**

```python
# ubt-vs-pbt/scripts/build_initcode.py
"""Generate initcode bytes for the locality-sweep campaign's two contract types.

Outputs:
    build_getter_initcode(num_stems)  →  getter with `num_stems` pre-populated stems
                                          for cold-SLOAD targets in storage benchmarks.
    build_empty_account_initcode()    →  0-byte-runtime contract for account benchmarks
                                          (CALL touches only basic-data, no code/storage).

Getter runtime (verified by prior test_getter_proto.py):
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

# Verified runtime bytecode from prior campaign (test_getter_proto.py, runtime portion).
# 28 bytes; see PLAN-locality-sweep.md Phase B for the source DSL.
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
    Iterate until prelude length stabilizes (depends on PUSH width for runtime_off).
    """
    # First-pass guess: assume PUSH1 for runtime_off (12-byte prelude). Re-emit if it overflows.
    prelude_len_guess = 12
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
    """Constructor: returns 0-byte runtime. RESULT: account exists in basic-data, no code."""
    # PUSH1 0 (size) ; PUSH1 0 (offset) ; RETURN
    return bytes([0x60, 0x00, 0x60, 0x00, 0xF3])


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
```

- [ ] **Step 2: Run tests, expect PASS**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/scripts
python3 -m pytest tests/test_build_initcode.py -v
```
Expected: 6 passed.

- [ ] **Step 3: Smoke from CLI**

```bash
python3 build_initcode.py empty
python3 build_initcode.py getter 0 | wc -c   # → 75 (\"0x\" + 36 hex chars + newline)
python3 build_initcode.py getter 256 | wc -c # → ~3160 hex chars + 3
```
Expected: empty prints `0x60006000f3`; sizes in the right range.

#### Task B3: EVM-execute the getter against a throwaway dev geth to validate gas + runtime

This proves the getter actually deploys and runs correctly before we burn 256 deploys into the campaign DB.

- [ ] **Step 1: Start a throwaway dev geth (any binary; reuse flat-state ubt)**

```bash
mkdir -p /tmp/getter-validate
/tmp/bench-bins/geth-flat-state --datadir /tmp/getter-validate \
  account import --password /dev/stdin <<< "" /dev/stdin <<EOF
ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
EOF
/tmp/bench-bins/geth-flat-state --datadir /tmp/getter-validate \
  --dev --dev.period 1 --dev.gaslimit 100000000 \
  --miner.etherbase 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --http --http.addr 127.0.0.1 --http.port 8545 \
  --override.ubt=0 --bintrie.groupdepth 5 \
  --verbosity 3 > /tmp/getter-validate/geth.log 2>&1 &
sleep 5
curl -s http://localhost:8545 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","id":1}'
```
Expected: `{"jsonrpc":"2.0","id":1,"result":"0x539"}` (chainId 1337).

- [ ] **Step 2: Deploy ONE 256-stem getter via factorydeploytx**

```bash
INITCODE=$(cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/scripts && python3 build_initcode.py getter 256)
/tmp/bench-bins/spamoor factorydeploytx \
  --rpchost=http://localhost:8545 \
  --privkey=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --count=1 --init-code="$INITCODE" --start-salt=0 -v 2>&1 | tail -30
```
Expected: line `tx confirmed: ... status=1` (deploy succeeded). Note the deployed address.

- [ ] **Step 3: Verify storage was pre-populated (read slot 0, 256, 65280)**

```bash
ADDR=<from previous step>
for SLOT in 0x0 0x100 0xff00; do
  curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getStorageAt\",\"params\":[\"$ADDR\",\"$SLOT\",\"latest\"],\"id\":1}"
  echo
done
```
Expected: all three return `"result":"0x0000000000000000000000000000000000000000000000000000000000000001"`.

- [ ] **Step 4: Verify SLOAD via direct CALL**

```bash
# CALL the getter with calldata [slot=0, value=0, isWrite=0]
# Calldata: 0x00...00 (32 zero bytes) repeated 3 times = 96 bytes
curl -s http://localhost:8545 -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$ADDR\",\"data\":\"0x$(printf '00%.0s' {1..96})\"},\"latest\"],\"id\":1}"
```
Expected: `"result":"0x"` (no return data — getter just SLOADs and STOPs).

- [ ] **Step 5: Tear down**

```bash
pkill -f "geth.*getter-validate" ; sleep 2
rm -rf /tmp/getter-validate
```

- [ ] **Step 6: Commit**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks
git add ubt-vs-pbt/scripts/build_initcode.py ubt-vs-pbt/scripts/tests/
git commit -m "ubt-vs-pbt: build_initcode.py — getter (N stems) + empty-account"
```

---

### Phase C: Locality-sweep EVM test (storage)

Replaces `test_scattered_storage.py`. Three benchmarks (sload / sstore / mixed); each reads `LOCALITY_K` env var to decide K.

**Mechanism:** Attack contract walks an address table of K targets in a (S+1, S+1, ..., S+1, S, S, ..., S) distribution where `S = T // K`; first `T mod K` contracts get `S+1` stems, the rest get `S`. Implemented compactly in EVM by iterating `i ∈ [0, T)` and computing `target_idx = i // (S+1) if i < (T mod K)*(S+1) else (T mod K) + (i - (T mod K)*(S+1)) // S` — but a simpler shortcut exists when computing on the harness side: precompute the per-i (target_idx, stem_idx) pairs in calldata.

**Simpler design:** ship the per-iteration (target_idx, stem_idx) sequence as part of calldata. Attack contract just walks two parallel calldata arrays. Calldata size: T = 256 → 256 × 4 bytes (target_idx + stem_idx packed) = 1KB. Well within block calldata budget (~16M gas / 16 gas-per-nonzero-byte = 1MB cap). Net: harness Python builds the sequence, EVM is dead-simple.

#### Task C1: Tests for the K-distribution helper

We need a Python helper to compute the (target_idx, stem_idx) sequence given (T, K), used by both the test (for the calldata table) and downstream verification.

**Files:**
- Create: `ubt-vs-pbt/scripts/tests/test_k_distribution.py`
- Create (later step): `ubt-vs-pbt/scripts/k_distribution.py`

- [ ] **Step 1: Write failing tests**

```python
# ubt-vs-pbt/scripts/tests/test_k_distribution.py
"""Unit tests for the (target_idx, stem_idx) sequence builder."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from k_distribution import build_sequence


def test_k_equals_1_all_same_target():
    seq = build_sequence(T=256, K=1)
    assert len(seq) == 256
    assert all(t == 0 for t, _ in seq)
    # Stem indices are 0..255 sequentially
    assert [s for _, s in seq] == list(range(256))


def test_k_equals_T_one_stem_per_target():
    seq = build_sequence(T=256, K=256)
    assert len(seq) == 256
    assert [t for t, _ in seq] == list(range(256))
    assert all(s == 0 for _, s in seq)


def test_k_10_distribution_is_balanced():
    """T=256, K=10: 256 mod 10 = 6 → first 6 contracts get ⌈256/10⌉=26 stems, rest get 25."""
    seq = build_sequence(T=256, K=10)
    assert len(seq) == 256
    # Count stems per target
    counts = [0] * 10
    for t, _ in seq:
        counts[t] += 1
    assert counts == [26, 26, 26, 26, 26, 26, 25, 25, 25, 25], counts


def test_k_100_distribution_is_balanced():
    """T=256, K=100: 256 // 100 = 2, 256 mod 100 = 56 → first 56 get 3, rest get 2."""
    seq = build_sequence(T=256, K=100)
    counts = [0] * 100
    for t, _ in seq:
        counts[t] += 1
    assert counts[:56] == [3] * 56
    assert counts[56:] == [2] * 44


def test_stem_indices_within_target_are_sequential_and_distinct():
    """For each target, the stem indices visited are 0, 1, 2, ... (no repeats)."""
    seq = build_sequence(T=256, K=10)
    by_target: dict[int, list[int]] = {}
    for t, s in seq:
        by_target.setdefault(t, []).append(s)
    for target, stems in by_target.items():
        assert stems == list(range(len(stems))), (target, stems)


def test_target_visits_are_consecutive_blocks():
    """All accesses to target i are consecutive in the sequence (clustered, not interleaved).

    PBT clustering only helps when the same contract's accesses are temporally adjacent
    in the access stream — otherwise Pebble's hot-block cache won't capture the locality.
    """
    seq = build_sequence(T=256, K=10)
    targets = [t for t, _ in seq]
    # The sequence of distinct targets (in order of first appearance) should be 0..9
    seen_order = []
    for t in targets:
        if not seen_order or seen_order[-1] != t:
            seen_order.append(t)
    assert seen_order == list(range(10)), seen_order
```

- [ ] **Step 2: Run tests, expect ImportError**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/scripts
python3 -m pytest tests/test_k_distribution.py -v
```
Expected: ImportError.

#### Task C2: Implement `k_distribution.py`

- [ ] **Step 1: Write implementation**

```python
# ubt-vs-pbt/scripts/k_distribution.py
"""Compute the per-iteration (target_idx, stem_idx) sequence for the K-sweep workload.

Given T touches per block and K distinct contracts, distribute touches as evenly as
possible across contracts (first `T mod K` contracts get ⌈T/K⌉ stems; the rest get
⌊T/K⌋). Within each contract, stems are visited 0, 1, 2, ... in order so each touch
hits a distinct stem (slot indices stride 256). Visits to a single contract are
contiguous in the sequence (not interleaved) so PBT's per-contract Pebble clustering
maps to consecutive cold reads.

Output: list of (target_idx, stem_idx) pairs of length T.
"""

from __future__ import annotations


def build_sequence(T: int, K: int) -> list[tuple[int, int]]:
    if T <= 0:
        raise ValueError(f"T must be positive: {T}")
    if K <= 0 or K > T:
        raise ValueError(f"K must be in [1, T={T}]: {K}")

    base = T // K
    extra = T % K  # first `extra` targets get base+1 stems

    seq: list[tuple[int, int]] = []
    for target in range(K):
        stems_for_target = base + (1 if target < extra else 0)
        for stem in range(stems_for_target):
            seq.append((target, stem))
    assert len(seq) == T
    return seq
```

- [ ] **Step 2: Run tests, expect PASS**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/scripts
python3 -m pytest tests/test_k_distribution.py -v
```
Expected: 6 passed.

#### Task C3: Write the new `test_locality_sweep.py`

**Files:**
- Create: `/mnt/state_expiry_vol_data/execution-specs/tests/benchmark/stateful/bloatnet/test_locality_sweep.py`

Note: this file uses the execution-specs `Op`/`While` DSL. We can't unit-test it
inside the bintrie-benchmarks repo; instead we smoke-run it against a tiny DB
in Task H.

- [ ] **Step 1: Write the test file**

```python
# execution-specs/tests/benchmark/stateful/bloatnet/test_locality_sweep.py
"""Locality-sweep storage benchmarks — K-parametrized read/write/mixed.

For T=256 stem touches per block, K ∈ {1, 10, 100, 256} contracts:
- K=1   → all 256 touches in one contract (max concentration)
- K=256 → 256 contracts × 1 touch each (max scatter)
- intermediate → ⌈T/K⌉ or ⌊T/K⌋ stems per contract; first `T mod K` get +1

Slot indices are stem-strided (slot = stem_idx * 256) so each touch is one cold
Pebble fetch (no in-stem reuse).

Replaces test_scattered_storage.py. The K=256 case is equivalent to the prior
scattered benchmarks.
"""

import os

import pytest
from execution_testing import (
    Alloc,
    BenchmarkTestFiller,
    Block,
    Bytecode,
    Fork,
    Op,
    Transaction,
    While,
)

REFERENCE_SPEC_GIT_PATH = "DUMMY/bloatnet.md"
REFERENCE_SPEC_VERSION = "1.0"

STUB_PREFIX = "scattered_target_"  # kept stable across campaigns; harness sets these labels
T_TOUCHES = 256

# Memory layout: address table at 0, then per-iter scratch and a sequence table.
TABLE = 0
SEQUENCE = 0x10000  # (target_idx, stem_idx) pairs, packed 16-byte each (2 × uint64)
SCRATCH = 0x20000
ARG_SLOT = SCRATCH          # getter calldata word 0: slot
ARG_VALUE = SCRATCH + 32    # getter calldata word 1: value
ARG_ISWRITE = SCRATCH + 64  # getter calldata word 2: isWrite
NMEM = SCRATCH + 96
CTR = SCRATCH + 128


GAS_THRESHOLD = 100_000


def _load_targets(pre: Alloc, address_stubs) -> list:
    if address_stubs is None:
        pytest.skip("locality-sweep requires --address-stubs (execute mode)")
    keys = address_stubs.extract_tokens(STUB_PREFIX)
    if not keys:
        pytest.skip(f"no stubs matched prefix '{STUB_PREFIX}'")
    keys = sorted(keys, key=lambda k: int(k[len(STUB_PREFIX):]))
    return [pre.deploy_contract(code=Bytecode(), stub=k) for k in keys]


def _locality_k() -> int:
    k = int(os.environ.get("LOCALITY_K", "256"))
    if k < 1 or k > T_TOUCHES:
        raise ValueError(f"LOCALITY_K out of range [1,{T_TOUCHES}]: {k}")
    return k


def _start_counter() -> int:
    """Per-run write offset so SSTOREs are cold inserts on never-used slots."""
    return int(os.environ.get("SCATTERED_WRITE_OFFSET", "0"))


def _build_sequence(K: int) -> list[tuple[int, int]]:
    """Inlined K-distribution (see ubt-vs-pbt/scripts/k_distribution.py)."""
    base = T_TOUCHES // K
    extra = T_TOUCHES % K
    seq = []
    for target in range(K):
        stems_for_target = base + (1 if target < extra else 0)
        for stem in range(stems_for_target):
            seq.append((target, stem))
    assert len(seq) == T_TOUCHES, (len(seq), T_TOUCHES, K)
    return seq


def _calldata(targets: list, K: int, start_counter: int) -> bytes:
    """Calldata layout:
        word 0:    start_counter (uint256)
        word 1:    K (uint256)
        words 2..K+1: K addresses (left-padded to 32 bytes each)
        words K+2.. : T pairs, each (target_idx uint128, stem_idx uint128) packed in 32B
    """
    assert len(targets) >= K
    sel = targets[:K]
    seq = _build_sequence(K)
    out = b""
    out += start_counter.to_bytes(32, "big")
    out += K.to_bytes(32, "big")
    for a in sel:
        out += bytes(a).rjust(32, b"\x00")
    for t, s in seq:
        out += t.to_bytes(16, "big") + s.to_bytes(16, "big")
    return out


def _setup(K: int) -> Bytecode:
    """Copy K addresses to TABLE, copy the (target,stem) sequence to SEQUENCE, init CTR."""
    # Calldata offsets (bytes):
    #   0..32:   start_counter
    #   32..64:  K
    #   64..64+32*K: K addresses
    #   64+32*K..: T pairs of 32B
    addr_table_off = 64
    addr_table_len = 32 * K
    seq_off = addr_table_off + addr_table_len
    seq_len = 32 * T_TOUCHES
    return (
        Op.CALLDATACOPY(TABLE, addr_table_off, addr_table_len)
        + Op.CALLDATACOPY(SEQUENCE, seq_off, seq_len)
        + Op.MSTORE(NMEM, K)
        + Op.MSTORE(CTR, Op.CALLDATALOAD(0))  # start_counter
        # Pre-fill ARG_VALUE and ARG_ISWRITE; per-iter we update ARG_SLOT (and ARG_ISWRITE for mixed)
        + Op.MSTORE(ARG_VALUE, 0)
        + Op.MSTORE(ARG_ISWRITE, 0)
    )


def _load_sequence_pair(i_mem: int) -> Bytecode:
    """Push (target_idx, stem_idx) on stack given i in memory at i_mem.

    pair_addr = SEQUENCE + i*32
    word = mload(pair_addr)
    target = word >> 128
    stem   = word & ((1<<128) - 1)
    """
    return (
        # Compute pair_addr = SEQUENCE + 32 * MLOAD(i_mem)
        Op.ADD(SEQUENCE, Op.MUL(32, Op.MLOAD(i_mem)))
        # MLOAD that
        # (stack: pair_addr)
    )
    # The full pair extraction is inlined inside the body Bytecode below using DUP/SWAP.


def _target_addr_op(target_idx_stack: Bytecode) -> Bytecode:
    """Given target_idx on stack: returns address from TABLE[target_idx*32]."""
    # Replace top-of-stack with MLOAD(TABLE + 32*top)
    return Op.MLOAD(Op.ADD(TABLE, Op.MUL(32, target_idx_stack)))


def _iter_body_sload() -> Bytecode:
    """One SLOAD iteration: target = table[seq[i].target]; slot = seq[i].stem * 256; CALL it."""
    i = CTR
    pair = Op.MLOAD(Op.ADD(SEQUENCE, Op.MUL(32, Op.MLOAD(i))))
    # We need both halves of pair. Cheaper to MLOAD twice than split.
    target_idx = Op.SHR(128, pair)
    stem_idx = Op.AND(pair, (1 << 128) - 1)
    # Build calldata: ARG_SLOT = stem_idx * 256
    # (ARG_VALUE, ARG_ISWRITE already 0 from setup)
    return (
        Op.MSTORE(ARG_SLOT, Op.MUL(256, stem_idx))
        + Op.POP(Op.CALL(address=_target_addr_op(target_idx), args_offset=ARG_SLOT, args_size=96))
        + Op.MSTORE(i, Op.ADD(Op.MLOAD(i), 1))
    )


def _iter_body_sstore() -> Bytecode:
    """SSTORE: slot = start_counter + i; isWrite = 1. start_counter already in CTR before loop."""
    # Approach: keep a separate counter for the write slot, distinct from CTR which is iter count.
    # Simpler: reuse CTR as iter; compute slot = CTR for fresh inserts (run offset added by harness in start_counter — actually start_counter is supplied as initial CTR, so slot = CTR exactly).
    # Wait — we want fresh slots PER RUN; the harness offsets by run*1e8. So CTR starts at start_counter
    # and increments by 1 each iter. slot = CTR exactly. We need a separate ITER counter for the seq lookup.
    # → Use a second counter ITER at CTR+32.
    ITER = CTR + 32
    pair = Op.MLOAD(Op.ADD(SEQUENCE, Op.MUL(32, Op.MLOAD(ITER))))
    target_idx = Op.SHR(128, pair)
    return (
        Op.MSTORE(ARG_SLOT, Op.MLOAD(CTR))
        + Op.MSTORE(ARG_VALUE, Op.MLOAD(CTR))  # any non-zero value; reuse counter
        + Op.MSTORE(ARG_ISWRITE, 1)
        + Op.POP(Op.CALL(address=_target_addr_op(target_idx), args_offset=ARG_SLOT, args_size=96))
        + Op.MSTORE(CTR, Op.ADD(Op.MLOAD(CTR), 1))
        + Op.MSTORE(ITER, Op.ADD(Op.MLOAD(ITER), 1))
    )


def _iter_body_mixed() -> Bytecode:
    """Mixed: even iter → SLOAD pre-pop slot; odd iter → SSTORE fresh slot."""
    # Conditional on (ITER & 1):
    #   0 → SLOAD branch (slot = stem_idx*256, isWrite=0)
    #   1 → SSTORE branch (slot = CTR, isWrite=1, then CTR++)
    # We inline both via the While body's branch.
    ITER = CTR + 32
    pair = Op.MLOAD(Op.ADD(SEQUENCE, Op.MUL(32, Op.MLOAD(ITER))))
    target_idx = Op.SHR(128, pair)
    stem_idx = Op.AND(pair, (1 << 128) - 1)
    is_write = Op.AND(Op.MLOAD(ITER), 1)
    # Compute slot conditionally with arithmetic (no branching needed):
    # slot = (1-is_write) * stem_idx * 256 + is_write * CTR
    # value = is_write * CTR
    # isWrite = is_write
    inv = Op.SUB(1, is_write)
    slot = Op.ADD(Op.MUL(inv, Op.MUL(256, stem_idx)), Op.MUL(is_write, Op.MLOAD(CTR)))
    value = Op.MUL(is_write, Op.MLOAD(CTR))
    return (
        Op.MSTORE(ARG_SLOT, slot)
        + Op.MSTORE(ARG_VALUE, value)
        + Op.MSTORE(ARG_ISWRITE, is_write)
        + Op.POP(Op.CALL(address=_target_addr_op(target_idx), args_offset=ARG_SLOT, args_size=96))
        + Op.MSTORE(CTR, Op.ADD(Op.MLOAD(CTR), is_write))  # CTR++ on writes only
        + Op.MSTORE(ITER, Op.ADD(Op.MLOAD(ITER), 1))
    )


def _attack_code(body_for_iter: Bytecode, K: int) -> Bytecode:
    """Loop body wrapped in a gas-bounded While."""
    return _setup(K) + While(
        body=body_for_iter,
        condition=Op.GT(Op.GAS, GAS_THRESHOLD),
    )


def _run(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
    body_for_iter: Bytecode,
):
    K = _locality_k()
    targets = _load_targets(pre, address_stubs)
    if len(targets) < K:
        pytest.skip(f"need at least K={K} target stubs, found {len(targets)}")
    start_counter = _start_counter()
    calldata = _calldata(targets, K, start_counter)
    attack = pre.deploy_contract(code=_attack_code(body_for_iter, K))
    intrinsic = fork.transaction_intrinsic_cost_calculator()(calldata=calldata)
    sender = pre.fund_eoa()
    tx_gas_limit = fork.transaction_gas_limit_cap() or gas_benchmark_value
    txs = []
    gas_remaining = gas_benchmark_value
    while gas_remaining > intrinsic:
        gas_available = min(gas_remaining, tx_gas_limit)
        if gas_available < intrinsic:
            break
        txs.append(
            Transaction(
                gas_limit=gas_available, to=attack, sender=sender, data=calldata
            )
        )
        gas_remaining -= gas_available
    benchmark_test(blocks=[Block(txs=txs)])


def test_storage_sload(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
):
    _run(pre, benchmark_test, address_stubs, gas_benchmark_value, fork, _iter_body_sload())


def test_storage_sstore(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
):
    _run(pre, benchmark_test, address_stubs, gas_benchmark_value, fork, _iter_body_sstore())


def test_storage_mixed(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
):
    _run(pre, benchmark_test, address_stubs, gas_benchmark_value, fork, _iter_body_mixed())
```

- [ ] **Step 2: Smoke-run pytest collection (no execute, just imports / parsing)**

```bash
cd /mnt/state_expiry_vol_data/execution-specs
/home/weiihann/.local/bin/uv run pytest \
  tests/benchmark/stateful/bloatnet/test_locality_sweep.py --collect-only 2>&1 | tail -20
```
Expected: 3 tests collected (`test_storage_sload`, `test_storage_sstore`, `test_storage_mixed`); no import errors.

- [ ] **Step 3: Commit (in execution-specs)**

```bash
cd /mnt/state_expiry_vol_data/execution-specs
git checkout -b bench/locality-sweep weiihann/bench/scattered-storage
git add tests/benchmark/stateful/bloatnet/test_locality_sweep.py
git commit -m "tests/benchmark/bloatnet: locality sweep (K-parametrized storage benchmarks)"
```

---

### Phase D: Account-zone EVM test

#### Task D1: Write `test_account_locality.py`

**Files:**
- Create: `/mnt/state_expiry_vol_data/execution-specs/tests/benchmark/stateful/bloatnet/test_account_locality.py`

- [ ] **Step 1: Write the test file**

```python
# execution-specs/tests/benchmark/stateful/bloatnet/test_account_locality.py
"""Account-zone locality sidecar — BALANCE read and value transfer across K accounts.

Targets are pre-deployed empty-code contracts (existing in basic-data with no code),
addressed by the stub prefix `account_target_<i>`. Each cell:

  account_balance_read: attack does BALANCE(table[i mod K]) per iter; K=10 mostly warm,
                        K=256 mostly cold → isolates account-zone clustering on reads.
  account_transfer:     attack does CALL(table[i mod K], value=1) per iter; same warm/cold
                        structure → isolates account-zone clustering on writes.
"""

import os

import pytest
from execution_testing import (
    Alloc,
    BenchmarkTestFiller,
    Block,
    Bytecode,
    Fork,
    Op,
    Transaction,
    While,
)

REFERENCE_SPEC_GIT_PATH = "DUMMY/bloatnet.md"
REFERENCE_SPEC_VERSION = "1.0"

ACCOUNT_STUB_PREFIX = "account_target_"

# Memory: TABLE at 0; CTR at 0x10000.
TABLE = 0
CTR = 0x10000
NMEM = CTR + 32
GAS_THRESHOLD = 100_000


def _load_accounts(pre: Alloc, address_stubs) -> list:
    if address_stubs is None:
        pytest.skip("account_locality requires --address-stubs (execute mode)")
    keys = address_stubs.extract_tokens(ACCOUNT_STUB_PREFIX)
    if not keys:
        pytest.skip(f"no stubs matched prefix '{ACCOUNT_STUB_PREFIX}'")
    keys = sorted(keys, key=lambda k: int(k[len(ACCOUNT_STUB_PREFIX):]))
    return [pre.deploy_contract(code=Bytecode(), stub=k) for k in keys]


def _locality_k() -> int:
    return int(os.environ.get("LOCALITY_K", "256"))


def _calldata(targets: list, K: int) -> bytes:
    """Calldata = K (uint256) || K addresses (32B each, left-padded)."""
    sel = targets[:K]
    return K.to_bytes(32, "big") + b"".join(bytes(a).rjust(32, b"\x00") for a in sel)


def _setup() -> Bytecode:
    return (
        Op.CALLDATACOPY(TABLE, 32, Op.SUB(Op.CALLDATASIZE, 32))
        + Op.MSTORE(NMEM, Op.CALLDATALOAD(0))  # K
        + Op.MSTORE(CTR, 0)
    )


def _target_addr() -> Bytecode:
    """table[(CTR mod K) * 32]; K is in NMEM."""
    return Op.MLOAD(Op.ADD(TABLE, Op.MUL(32, Op.MOD(Op.MLOAD(CTR), Op.MLOAD(NMEM)))))


def _balance_body() -> Bytecode:
    return Op.POP(Op.BALANCE(_target_addr())) + Op.MSTORE(CTR, Op.ADD(Op.MLOAD(CTR), 1))


def _transfer_body() -> Bytecode:
    # CALL(gas, addr, value, in_offset, in_size, out_offset, out_size)
    # Pass value=1; calldata empty (in_size=0); cap inner gas at 2300 (stipend) so the
    # callee can't do meaningful work even if it has code — pure account-zone touch.
    return (
        Op.POP(
            Op.CALL(
                gas=2300,
                address=_target_addr(),
                value=1,
                args_offset=0,
                args_size=0,
                ret_offset=0,
                ret_size=0,
            )
        )
        + Op.MSTORE(CTR, Op.ADD(Op.MLOAD(CTR), 1))
    )


def _attack_code(iter_body: Bytecode) -> Bytecode:
    return _setup() + While(body=iter_body, condition=Op.GT(Op.GAS, GAS_THRESHOLD))


def _run(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
    iter_body: Bytecode,
):
    K = _locality_k()
    targets = _load_accounts(pre, address_stubs)
    if len(targets) < K:
        pytest.skip(f"need at least K={K} account stubs, found {len(targets)}")
    calldata = _calldata(targets, K)
    attack = pre.deploy_contract(code=_attack_code(iter_body))
    intrinsic = fork.transaction_intrinsic_cost_calculator()(calldata=calldata)
    sender = pre.fund_eoa(amount=10**20)  # plenty for value=1 transfers
    tx_gas_limit = fork.transaction_gas_limit_cap() or gas_benchmark_value
    txs = []
    gas_remaining = gas_benchmark_value
    while gas_remaining > intrinsic:
        gas_available = min(gas_remaining, tx_gas_limit)
        if gas_available < intrinsic:
            break
        txs.append(
            Transaction(
                gas_limit=gas_available, to=attack, sender=sender, data=calldata, value=10**18
            )
        )
        gas_remaining -= gas_available
    benchmark_test(blocks=[Block(txs=txs)])


def test_account_balance_read(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
):
    _run(pre, benchmark_test, address_stubs, gas_benchmark_value, fork, _balance_body())


def test_account_transfer(
    pre: Alloc,
    benchmark_test: BenchmarkTestFiller,
    address_stubs,
    gas_benchmark_value: int,
    fork: Fork,
):
    _run(pre, benchmark_test, address_stubs, gas_benchmark_value, fork, _transfer_body())
```

- [ ] **Step 2: Smoke-collect**

```bash
cd /mnt/state_expiry_vol_data/execution-specs
/home/weiihann/.local/bin/uv run pytest \
  tests/benchmark/stateful/bloatnet/test_account_locality.py --collect-only 2>&1 | tail -20
```
Expected: 2 tests collected.

- [ ] **Step 3: Commit**

```bash
cd /mnt/state_expiry_vol_data/execution-specs
git add tests/benchmark/stateful/bloatnet/test_account_locality.py
git commit -m "tests/benchmark/bloatnet: account-zone locality sidecar (balance + transfer)"
```

#### Task D2: Remove superseded tests

- [ ] **Step 1: Delete the old + prototype tests**

```bash
cd /mnt/state_expiry_vol_data/execution-specs
git rm tests/benchmark/stateful/bloatnet/test_scattered_storage.py
git rm -f tests/benchmark/stateful/bloatnet/test_getter_proto.py 2>/dev/null || true
git rm -f tests/benchmark/stateful/bloatnet/test_storage_sweep_proto.py 2>/dev/null || true
git commit -m "tests/benchmark/bloatnet: drop scattered_storage + prototypes (superseded)"
```

---

### Phase E: Script edits — deploy two contract sets

#### Task E1: Modify `generate_dbs.sh` for 256 getters + 256 empty accounts

**Files:**
- Modify: `ubt-vs-pbt/scripts/generate_dbs.sh`

- [ ] **Step 1: Replace the getter-only Phase 2 deploy with two factorydeploytx runs**

Edit the file: replace the hardcoded `GETTER_INITCODE` default and the single-deploy block with calls that source initcode from `build_initcode.py` and run TWO deploys (getters at salts 0..N-1, accounts at salts N..2N-1).

Apply this patch — change the `GETTER_INITCODE="${GETTER_INITCODE:-0x...}"` line to source from the helper, then add an `ACCOUNT_INITCODE` and a second factorydeploytx invocation, plus a second `compute_create2_addresses.py` call writing `accounts.json`. The diff body is:

Find the line (current ~line 38):
```
GETTER_INITCODE="${GETTER_INITCODE:-0x600160005561001c60008160108239f3604035600d5801576000355450600b5801565b602035600035555b00}"
```
Replace with:
```bash
# Initcodes are generated at runtime from build_initcode.py so the bytecode and
# the per-stem SSTORE count stay in lockstep. Set NUM_STEMS to populate that many
# stems in each getter (default 256 to support T=256 sloads against any K).
NUM_STEMS="${NUM_STEMS:-256}"
GETTER_INITCODE=$(python3 "$CAMPAIGN_DIR/scripts/build_initcode.py" getter "$NUM_STEMS")
ACCOUNT_INITCODE=$(python3 "$CAMPAIGN_DIR/scripts/build_initcode.py" empty)
```

Find the existing deploy block (around current line 254–289) and replace with two deploys + two contracts.json files. Concretely, after the line `log "  [phase2] Deploying $NUM_CONTRACTS getter contracts via factorydeploytx (CREATE2)"`, replace the body through `log "  [phase2] contracts.json written..."` with:

```bash
  # ── Deploy 1: getter contracts (storage benchmarks) ────────────────────
  getter_log="$config_results/factorydeploy_getter.log"
  log "  [phase2] Deploying $NUM_CONTRACTS getter contracts (init=$NUM_STEMS-stem)"
  "$SPAMOOR_BIN" factorydeploytx \
    --rpchost="http://localhost:8545" \
    --privkey="$PRIVKEY" \
    --count="$NUM_CONTRACTS" \
    --init-code="$GETTER_INITCODE" \
    --start-salt=0 \
    -v > "$getter_log" 2>&1

  FACTORY=$(grep -oE "CREATE2 factory at: 0x[0-9a-fA-F]{40}" "$getter_log" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}")
  if [ -z "$FACTORY" ]; then
    log "    ERROR: getter deploy: factory not extracted"; tail -20 "$getter_log"; kill_geth; exit 1
  fi
  "$UV" run --with "eth-hash[pycryptodome]" python \
    "$CAMPAIGN_DIR/scripts/compute_create2_addresses.py" \
    "$FACTORY" "$GETTER_INITCODE" "$NUM_CONTRACTS" "$contracts_file" \
    2>&1 | tee -a "$getter_log"

  # Spot-check first getter has code on chain
  sample=$(python3 -c "import json; print(json.load(open('$contracts_file'))[0])")
  code_len=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$sample\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)")
  if [ "$code_len" -eq 0 ] 2>/dev/null; then
    log "    ERROR: sample getter $sample has no code"; kill_geth; exit 1
  fi
  log "  [phase2] getters: $NUM_CONTRACTS deployed, sample $sample (${code_len} bytes)"

  # ── Deploy 2: empty-account contracts (account benchmarks) ─────────────
  account_log="$config_results/factorydeploy_account.log"
  accounts_file="$config_results/accounts.json"
  ACCOUNT_START_SALT=$NUM_CONTRACTS
  log "  [phase2] Deploying $NUM_CONTRACTS empty-account contracts (start salt=$ACCOUNT_START_SALT)"
  "$SPAMOOR_BIN" factorydeploytx \
    --rpchost="http://localhost:8545" \
    --privkey="$PRIVKEY" \
    --count="$NUM_CONTRACTS" \
    --init-code="$ACCOUNT_INITCODE" \
    --start-salt="$ACCOUNT_START_SALT" \
    -v > "$account_log" 2>&1

  ACCOUNT_FACTORY=$(grep -oE "CREATE2 factory at: 0x[0-9a-fA-F]{40}" "$account_log" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}")
  if [ -z "$ACCOUNT_FACTORY" ]; then
    log "    ERROR: account deploy: factory not extracted"; tail -20 "$account_log"; kill_geth; exit 1
  fi
  "$UV" run --with "eth-hash[pycryptodome]" python \
    "$CAMPAIGN_DIR/scripts/compute_create2_addresses.py" \
    "$ACCOUNT_FACTORY" "$ACCOUNT_INITCODE" "$NUM_CONTRACTS" "$accounts_file" \
    --start-salt="$ACCOUNT_START_SALT" \
    2>&1 | tee -a "$account_log"

  sample_account=$(python3 -c "import json; print(json.load(open('$accounts_file'))[0])")
  # Empty-account: code length should be EXACTLY 0 (contract exists, has no code).
  acode_len=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$sample_account\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)")
  if [ "$acode_len" -ne 0 ] 2>/dev/null; then
    log "    ERROR: sample account $sample_account has code (expected empty)"; kill_geth; exit 1
  fi
  ncontracts=$(python3 -c "import json; print(len(json.load(open('$contracts_file'))))")
  naccounts=$(python3 -c "import json; print(len(json.load(open('$accounts_file'))))")
  log "  [phase2] both sets written: $ncontracts getters + $naccounts empty accounts"
```

- [ ] **Step 2: Modify `compute_create2_addresses.py` to accept `--start-salt`**

Read the file first:

```bash
cat /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/scripts/compute_create2_addresses.py
```

If it already accepts `--start-salt` or a positional 5th arg for the start salt, skip. Otherwise, add a `--start-salt INT` option (default 0) and use it as the base for the `salt = (start_salt + i)` loop. Concretely change:

```python
for i in range(int(count)):
    salt = i.to_bytes(32, "big")
```
to:

```python
for i in range(int(count)):
    salt = (start_salt + i).to_bytes(32, "big")
```

Plus argparse:
```python
import argparse
ap = argparse.ArgumentParser()
ap.add_argument("factory")
ap.add_argument("init_code")
ap.add_argument("count", type=int)
ap.add_argument("output")
ap.add_argument("--start-salt", type=int, default=0)
args = ap.parse_args()
```

- [ ] **Step 3: Update top-level diff guard at end of generate_dbs.sh**

Find:
```bash
if [ -f "$RESULTS_DIR/ubt/contracts.json" ] && [ -f "$RESULTS_DIR/pbt/contracts.json" ]; then
  if diff -q "$RESULTS_DIR/ubt/contracts.json" "$RESULTS_DIR/pbt/contracts.json" >/dev/null; then
    log "  OK: ubt and pbt contracts.json are identical"
  else
    ...
```
Add a parallel check for `accounts.json`:

```bash
  if diff -q "$RESULTS_DIR/ubt/accounts.json" "$RESULTS_DIR/pbt/accounts.json" >/dev/null; then
    log "  OK: ubt and pbt accounts.json are identical"
  else
    log "  WARN: ubt and pbt accounts.json DIFFER — account benchmarks would diverge"
  fi
```

- [ ] **Step 4: Commit**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks
git add ubt-vs-pbt/scripts/generate_dbs.sh ubt-vs-pbt/scripts/compute_create2_addresses.py
git commit -m "ubt-vs-pbt: generate_dbs deploys getters + empty accounts for locality sweep"
```

---

### Phase F: Script edits — benchmark runner

#### Task F1: Modify `run_benchmarks.sh` for K-sweep + period=1 + new bench names

**Files:**
- Modify: `ubt-vs-pbt/scripts/run_benchmarks.sh`

The shape of the new loop: outer `bench`, inner `K`, innermost `run`. Per cell: rebuild stubs.json from the appropriate addrlist (contracts.json for storage benchmarks, accounts.json for account benchmarks), export `LOCALITY_K`, name the per-cell logs `<bench>_k${K}_run${run}_geth.log`.

- [ ] **Step 1: Rewrite the BENCH_NAMES / BENCH_TESTS section**

Replace the BENCH_NAMES setup block (current lines ~53–73) with:

```bash
# Benchmark name | execution-specs test path | stub source (contracts.json or accounts.json)
declare -a BENCH_NAMES=()
declare -a BENCH_TESTS=()
declare -a BENCH_STUB_SOURCES=()  # "contracts" or "accounts"
declare -a BENCH_K_LISTS=()       # space-separated K values per bench
DEFAULT_BENCHMARKS="storage_sload storage_sstore storage_mixed account_balance_read account_transfer"
read -ra _BENCH_OVERRIDES <<< "${BENCHMARKS:-$DEFAULT_BENCHMARKS}"
DEFAULT_K_STORAGE="${K_VALUES_STORAGE:-1 10 100 256}"
DEFAULT_K_ACCOUNT="${K_VALUES_ACCOUNT:-10 256}"
for name in "${_BENCH_OVERRIDES[@]}"; do
  case "$name" in
    storage_sload)
      BENCH_NAMES+=("storage_sload"); BENCH_STUB_SOURCES+=("contracts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_locality_sweep.py::test_storage_sload")
      BENCH_K_LISTS+=("$DEFAULT_K_STORAGE") ;;
    storage_sstore)
      BENCH_NAMES+=("storage_sstore"); BENCH_STUB_SOURCES+=("contracts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_locality_sweep.py::test_storage_sstore")
      BENCH_K_LISTS+=("$DEFAULT_K_STORAGE") ;;
    storage_mixed)
      BENCH_NAMES+=("storage_mixed"); BENCH_STUB_SOURCES+=("contracts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_locality_sweep.py::test_storage_mixed")
      BENCH_K_LISTS+=("$DEFAULT_K_STORAGE") ;;
    account_balance_read)
      BENCH_NAMES+=("account_balance_read"); BENCH_STUB_SOURCES+=("accounts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_account_locality.py::test_account_balance_read")
      BENCH_K_LISTS+=("$DEFAULT_K_ACCOUNT") ;;
    account_transfer)
      BENCH_NAMES+=("account_transfer"); BENCH_STUB_SOURCES+=("accounts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_account_locality.py::test_account_transfer")
      BENCH_K_LISTS+=("$DEFAULT_K_ACCOUNT") ;;
    *)
      echo "ERROR: unknown benchmark '$name'" >&2; exit 1 ;;
  esac
done
```

- [ ] **Step 2: Change `GAS_BENCHMARK_VALUE` default from 16 to 6**

Find:
```bash
GAS_BENCHMARK_VALUE="${GAS_BENCHMARK_VALUE:-16}"
```
Change to:
```bash
GAS_BENCHMARK_VALUE="${GAS_BENCHMARK_VALUE:-6}"
```

- [ ] **Step 3: Change `--dev.period 10` to `--dev.period 1`**

Find (in `start_geth_for_bench`):
```bash
    --dev --dev.period 10 --dev.gaslimit 20000000 \
```
Change to:
```bash
    --dev --dev.period 1 --dev.gaslimit 20000000 \
```

Also update the log line a few lines above from `dev.period=10` → `dev.period=1`.

- [ ] **Step 4: Update `write_stub_file` to accept the source (contracts or accounts)**

Replace the current function with:

```bash
# write_stub_file <addr_json> <prefix>:
#   expose addresses under stub labels "<prefix>_<i>".
write_stub_file() {
  local addr_json="$1"
  local prefix="$2"
  python3 - "$addr_json" "$STUBS_FILE" "$prefix" <<'PY'
import json, sys
addrs = json.load(open(sys.argv[1]))
prefix = sys.argv[3]
stubs = {f"{prefix}_{i}": {"addr": a} for i, a in enumerate(addrs)}
json.dump(stubs, open(sys.argv[2], "w"), indent=2)
PY
}
```

- [ ] **Step 5: Rewrite the per-config benchmark loop**

Replace the existing block (current ~line 297–336) with:

```bash
  for bench_idx in "${!BENCH_NAMES[@]}"; do
    bench_name="${BENCH_NAMES[$bench_idx]}"
    bench_test="${BENCH_TESTS[$bench_idx]}"
    stub_source="${BENCH_STUB_SOURCES[$bench_idx]}"
    k_list="${BENCH_K_LISTS[$bench_idx]}"

    # Pick the right address source + stub prefix for this benchmark
    if [ "$stub_source" = "contracts" ]; then
      addr_json="$cfg_dir/contracts.json"
      stub_prefix="scattered_target"
    else
      addr_json="$cfg_dir/accounts.json"
      stub_prefix="account_target"
    fi

    if [ ! -f "$addr_json" ]; then
      log "  ERROR: $addr_json missing for $bench_name — re-run generate_dbs.sh"
      exit 1
    fi
    NCONTRACTS=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$addr_json")
    write_stub_file "$addr_json" "$stub_prefix"

    for K in $k_list; do
      log ""
      log "  ── BENCHMARK: ${bench_name}_k${K} (sweeping $NCONTRACTS-stub pool; effective K=$K)"

      # Clear stale logs
      for run in $(seq 1 "$NUM_RUNS"); do
        rm -f "$cfg_dir/${bench_name}_k${K}_run${run}_geth.log" \
              "$cfg_dir/${bench_name}_k${K}_run${run}_test.log"
      done

      for run in $(seq 1 "$NUM_RUNS"); do
        stem="${bench_name}_k${K}_run${run}"
        export SCATTERED_WRITE_OFFSET=$((run * 100000000))
        export LOCALITY_K="$K"
        log ""
        log "  --- $stem ($name) write-offset=$SCATTERED_WRITE_OFFSET ---"

        start_geth_for_bench "$geth_bin" "$db_path" "$name" "$cfg_dir/geth_current.log"

        log "  [bench] Running execute remote..."
        cd "$EXEC_SPECS"
        set +e
        "$UV" run execute remote \
          --fork Osaka \
          --tx-wait-timeout 600 \
          --gas-benchmark-values "$GAS_BENCHMARK_VALUE" \
          --address-stubs "$STUBS_FILE" \
          "$bench_test" \
          -v > "$cfg_dir/${stem}_test.log" 2>&1
        test_exit=$?
        set -e

        cp "$cfg_dir/geth_current.log" "$cfg_dir/${stem}_geth.log"

        passed=$(grep -c " PASSED" "$cfg_dir/${stem}_test.log" 2>/dev/null || echo "0")
        failed=$(grep -c " FAILED" "$cfg_dir/${stem}_test.log" 2>/dev/null || echo "0")
        errors=$(grep -c "missing trie node" "$cfg_dir/${stem}_geth.log" 2>/dev/null || echo "0")
        log "  [bench] exit=$test_exit passed=$passed failed=$failed missing_trie_node=$errors"
      done
    done
  done
```

- [ ] **Step 6: Commit**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks
git add ubt-vs-pbt/scripts/run_benchmarks.sh
git commit -m "ubt-vs-pbt: run_benchmarks K-sweep + period=1 + GBV=6"
```

#### Task F2: Modify `run_campaign.sh` for K plumbing

**Files:**
- Modify: `ubt-vs-pbt/scripts/run_campaign.sh`

- [ ] **Step 1: Add K env vars + update default BENCHMARKS**

In the env-var block (~lines 26–50), add:

```bash
export K_VALUES_STORAGE="${K_VALUES_STORAGE:-1 10 100 256}"
export K_VALUES_ACCOUNT="${K_VALUES_ACCOUNT:-10 256}"
export NUM_STEMS="${NUM_STEMS:-256}"
```

Change the default `BENCHMARKS` from:
```bash
export BENCHMARKS="${BENCHMARKS:-scattered_sload scattered_sstore scattered_mixed}"
```
to:
```bash
export BENCHMARKS="${BENCHMARKS:-storage_sload storage_sstore storage_mixed account_balance_read account_transfer}"
```

Change `GAS_BENCHMARK_VALUE` default from 16 to 6:
```bash
export GAS_BENCHMARK_VALUE="${GAS_BENCHMARK_VALUE:-6}"
```

- [ ] **Step 2: Commit**

```bash
git add ubt-vs-pbt/scripts/run_campaign.sh
git commit -m "ubt-vs-pbt: run_campaign — K env plumbing + locality-sweep defaults"
```

---

### Phase G: End-to-end smoke test on a tiny DB

A 1 GB, 5-getter, 5-account, K∈{1,5} × 3 storage benches × 1 run × 2 configs = 30-cell smoke. Goal: prove the whole pipeline (gen → bench → extract → consolidate) without burning hours.

#### Task G1: Run smoke campaign

- [ ] **Step 1: Prepare smoke workspace**

```bash
mkdir -p /mnt/state_expiry_vol_data/tmp/smoke
SMOKE_DIR=/mnt/state_expiry_vol_data/tmp/smoke
rm -rf "$SMOKE_DIR/data" "$SMOKE_DIR/dbs"
mkdir -p "$SMOKE_DIR/data" "$SMOKE_DIR/dbs"
```

- [ ] **Step 2: Run the smoke campaign**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt
TMPDIR=/mnt/state_expiry_vol_data/tmp UV_LINK_MODE=copy \
NUM_RUNS=1 NUM_CONTRACTS=5 TARGET_SIZE=1GB COLD_CACHE=0 GROUP_DEPTH=5 \
K_VALUES_STORAGE="1 5" K_VALUES_ACCOUNT="5" \
NUM_STEMS=5 \
GAS_BENCHMARK_VALUE=2 \
GETH_UBT_BIN=/tmp/bench-bins/geth-flat-state \
GETH_PBT_BIN=/tmp/bench-bins/geth-pbt-flat-state \
STATE_ACTOR_UBT_BIN=/tmp/bench-bins/state-actor-flat-state \
STATE_ACTOR_PBT_BIN=/tmp/bench-bins/state-actor-pbt-flat-state \
SPAMOOR_BIN=/tmp/bench-bins/spamoor EXEC_SPECS=/mnt/state_expiry_vol_data/execution-specs \
UV=/home/weiihann/.local/bin/uv \
DB_BASE="$SMOKE_DIR/dbs" RESULTS_DIR="$SMOKE_DIR/data" \
bash scripts/run_campaign.sh 2>&1 | tee "$SMOKE_DIR/smoke.log"
```

Expected within ~10 min: state-actor builds ~1 GB DB per config (might be smaller — TARGET_SIZE caps), deploys 5+5 contracts per config, runs 5 cells per config (storage_sload_k1, storage_sload_k5, storage_sstore_k1, storage_sstore_k5, storage_mixed_k1, storage_mixed_k5, account_balance_read_k5, account_transfer_k5 — wait, K=1 not in account list; that's 6 storage + 2 account = 8 cells × 2 configs = 16 invocations). All exit=0, no `missing trie node`, identical `contracts.json` and `accounts.json`.

- [ ] **Step 3: Manually inspect a sample log**

```bash
ls "$SMOKE_DIR/data/ubt/" | head -20
grep -c "tx_count=1" "$SMOKE_DIR/data/ubt/storage_sload_k1_run1_geth.log" || true
grep "slowblock" "$SMOKE_DIR/data/ubt/storage_sload_k1_run1_geth.log" | head -3
```
Expected: per-cell `_geth.log` and `_test.log`; the slowblock line shows `gas=` close to GAS_BENCHMARK_VALUE × 1e6 = 2_000_000.

- [ ] **Step 4: Verify CSV extraction handled new naming**

```bash
ls "$SMOKE_DIR/data/ubt/csv/"
head -5 "$SMOKE_DIR/data/ubt_vs_pbt_consolidated.csv"
python3 -c "
import csv, sys
with open('$SMOKE_DIR/data/ubt_vs_pbt_consolidated.csv') as f:
    rows = list(csv.DictReader(f))
print(f'{len(rows)} rows')
print('benchmarks:', sorted(set(r['benchmark'] for r in rows)))
print('configs:', sorted(set(r['config'] for r in rows)))
"
```
Expected: ~16 rows; benchmarks include `storage_sload_k1`, `storage_sload_k5`, etc.; configs = `['pbt', 'ubt']`.

- [ ] **Step 5: Verify analyze_data.py groups by (benchmark, config) sensibly**

```bash
cat "$SMOKE_DIR/data/analysis_results.json" | head -40
```
Expected: keys like `storage_sload_k1`, `storage_sload_k5`, `account_balance_read_k5`, etc. — each with PBT/UBT median ratios.

- [ ] **Step 6: Same-state smoke gate**

```bash
python3 << 'PY'
import csv, json
with open('/mnt/state_expiry_vol_data/tmp/smoke/data/ubt_vs_pbt_consolidated.csv') as f:
    rows = list(csv.DictReader(f))
by_cell = {}
for r in rows:
    by_cell.setdefault((r['benchmark'], r['config'], r['run']), []).append(r)
# For each (benchmark, run), compare ubt vs pbt gas_used and slots
benches_runs = set((b, run) for (b, _cfg, run) in by_cell)
for b, run in sorted(benches_runs):
    if (b, 'ubt', run) in by_cell and (b, 'pbt', run) in by_cell:
        u = by_cell[(b, 'ubt', run)]
        p = by_cell[(b, 'pbt', run)]
        # sum gas
        ug = sum(int(x['gas_used']) for x in u)
        pg = sum(int(x['gas_used']) for x in p)
        match = "OK" if ug == pg else f"DIFF u={ug} p={pg}"
        print(f"{b:30s} run={run}: {match}")
PY
```
Expected: every row says `OK` (same gas_used across configs).

- [ ] **Step 7: If smoke is clean, commit any incremental fixes**

If steps 1–6 surfaced bugs in the scripts or tests, fix them (re-run smoke). Commit each fix as a separate commit so the campaign launch (Phase H) starts from a clean tip.

---

### Phase H: Launch the real campaign

#### Task H1: Pre-launch cleanup

- [ ] **Step 1: Back up current `data/` (prior scattered campaign)**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt
mv data data-scattered-prior
mkdir data
```

- [ ] **Step 2: Wipe prior DBs (109 GB of bitarray + scattered campaign artifacts)**

```bash
du -sh /mnt/state_expiry_vol_data/ubt-vs-pbt-dbs 2>/dev/null || true
rm -r /mnt/state_expiry_vol_data/ubt-vs-pbt-dbs 2>/dev/null || true
df -h /mnt/state_expiry_vol_data
```
Expected: free space jumps by ~100 GB.

- [ ] **Step 3: Verify sudo NOPASSWD rule still works**

```bash
sudo -n /usr/sbin/sysctl -w vm.drop_caches=3
```
Expected: prints `vm.drop_caches = 3`; no password prompt.

#### Task H2: Launch + monitor

- [ ] **Step 1: Launch in foreground inside `tmux` (so it survives SSH drops)**

```bash
tmux new -d -s campaign 'cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt && \
TMPDIR=/mnt/state_expiry_vol_data/tmp UV_LINK_MODE=copy \
NUM_RUNS=20 NUM_CONTRACTS=256 TARGET_SIZE=500GB COLD_CACHE=1 GROUP_DEPTH=5 \
GAS_BENCHMARK_VALUE=6 NUM_STEMS=256 \
K_VALUES_STORAGE="1 10 100 256" K_VALUES_ACCOUNT="10 256" \
SA_ACCOUNTS=125000 SA_CONTRACTS=12800000 SA_MIN_SLOTS=1 SA_MAX_SLOTS=100000 \
GETH_UBT_BIN=/tmp/bench-bins/geth-flat-state \
GETH_PBT_BIN=/tmp/bench-bins/geth-pbt-flat-state \
STATE_ACTOR_UBT_BIN=/tmp/bench-bins/state-actor-flat-state \
STATE_ACTOR_PBT_BIN=/tmp/bench-bins/state-actor-pbt-flat-state \
SPAMOOR_BIN=/tmp/bench-bins/spamoor EXEC_SPECS=/mnt/state_expiry_vol_data/execution-specs \
UV=/home/weiihann/.local/bin/uv \
DB_BASE=/mnt/state_expiry_vol_data/ubt-vs-pbt-dbs \
RESULTS_DIR=$(pwd)/data \
bash scripts/run_campaign.sh 2>&1 | tee campaign-locality-$(date +%Y%m%d-%H%M%S).log'
```

- [ ] **Step 2: Monitor at intervals**

Phase 1 (~2 h): check chaindata is growing
```bash
tmux capture-pane -t campaign -p | tail -30
du -sh /mnt/state_expiry_vol_data/ubt-vs-pbt-dbs/ubt/geth/chaindata 2>/dev/null
free -h
```
Expected: state-actor logs progress; chaindata tracks toward 75 GB; no OOM in `dmesg`.

Phase 2 (~4 h): cells executing
```bash
ls ubt-vs-pbt/data/ubt/ | grep _geth.log | wc -l    # progress: should grow to 16*20=320
tail -50 ubt-vs-pbt/campaign-locality-*.log | grep -E "(BENCHMARK|exit=)"
```

- [ ] **Step 3: Final completion check**

```bash
grep -c "Campaign complete" ubt-vs-pbt/campaign-locality-*.log
ls ubt-vs-pbt/data/ubt_vs_pbt_consolidated.csv ubt-vs-pbt/data/analysis_results.json
```
Expected: both files exist; consolidated CSV has hundreds of rows.

---

### Phase I: Verify

#### Task I1: Block-shape gate (1 tx/block, ~6M gas)

- [ ] **Step 1: Verify each cell saw 1-tx blocks of ~6M gas**

```bash
python3 << 'PY'
import re, glob
problems = []
for log in sorted(glob.glob('/mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/data/*/[!a]*_k*_run*_geth.log')):
    # Find slowblock lines
    txc, gas = [], []
    with open(log) as f:
        for line in f:
            m = re.search(r'txs=(\d+).+gas=(\d+)', line)
            if m:
                t, g = int(m.group(1)), int(m.group(2))
                if t > 0:
                    txc.append(t); gas.append(g)
    if not txc:
        problems.append(f"{log}: no slowblock entries")
        continue
    if max(txc) != 1:
        problems.append(f"{log}: max tx_count={max(txc)} (expected 1)")
    # 6 M block expected; ±10% tolerance for non-storage cells where gas/call varies
    avg = sum(gas) / len(gas)
    if not (4_500_000 < avg < 7_000_000):
        problems.append(f"{log}: avg gas/block={avg:.0f} (expected ~6M)")
print(f"{len(problems)} problems" if problems else "All block-shape gates passed")
for p in problems[:20]:
    print(" ", p)
PY
```
Expected: "All block-shape gates passed". If not, investigate the specific cells — likely a missing `miner_setGasLimit` call or a dev.period interaction.

#### Task I2: Same-state gate

- [ ] **Step 1: Run same-state verification**

```bash
python3 << 'PY'
"""Compare gas_used + slot count between UBT and PBT per (benchmark, K, run)."""
import csv
from collections import defaultdict

p = '/mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt/data/ubt_vs_pbt_consolidated.csv'
with open(p) as f:
    rows = list(csv.DictReader(f))

by_cell = defaultdict(list)
for r in rows:
    # benchmark already includes _k${K}; group by (benchmark, run)
    by_cell[(r['benchmark'], r['run'], r['config'])].append(r)

diffs = []
for (b, run, _cfg), _ in list(by_cell.items()):
    u = by_cell.get((b, run, 'ubt'), [])
    p2 = by_cell.get((b, run, 'pbt'), [])
    if not u or not p2:
        continue
    ug = sorted(int(x['gas_used']) for x in u)
    pg = sorted(int(x['gas_used']) for x in p2)
    if ug != pg:
        diffs.append((b, run, sum(ug) - sum(pg)))

if diffs:
    print(f"{len(diffs)} same-state divergences:")
    for b, run, d in diffs[:10]:
        print(f"  {b} run={run} diff={d}")
else:
    print("Same-state gate: PASS for all cells")
PY
```
Expected: "Same-state gate: PASS for all cells".

If divergence: stop and investigate before regenerating the report.

---

### Phase J: Regenerate report

#### Task J1: Add ratio-vs-K graph generator

**Files:**
- Modify: `ubt-vs-pbt/scripts/generate_graphs.py`

- [ ] **Step 1: Add the new function**

Read the current file to find a good place to insert the new plotting function (probably near other `plot_*` functions). Add (and call from the main `if __name__ == "__main__":` block) something like:

```python
def plot_ratio_vs_K(df_consolidated, out_path: Path, theme: str = "dark"):
    """Headline: PBT/UBT throughput ratio vs K, three storage curves."""
    import matplotlib.pyplot as plt
    import numpy as np
    import re

    # df_consolidated has columns: benchmark, K, config, mgas_per_sec
    # benchmark column is like "storage_sload_k1"; split into (bench, K)
    rows = df_consolidated[df_consolidated["benchmark"].str.startswith("storage_")].copy()
    # extract K
    rows["base"] = rows["benchmark"].str.replace(r"_k\d+$", "", regex=True)
    rows["K"] = rows["benchmark"].str.extract(r"_k(\d+)$").astype(int)

    fig, ax = plt.subplots(figsize=(9, 6))
    for base in ("storage_sload", "storage_sstore", "storage_mixed"):
        sub = rows[rows["base"] == base]
        if sub.empty:
            continue
        # median ratio per K
        ks = sorted(sub["K"].unique())
        ratios, lo, hi = [], [], []
        for k in ks:
            u = sub[(sub["K"] == k) & (sub["config"] == "ubt")]["mgas_per_sec"]
            p = sub[(sub["K"] == k) & (sub["config"] == "pbt")]["mgas_per_sec"]
            if u.empty or p.empty:
                continue
            ratios.append(p.median() / u.median())
            # crude 95% via bootstrap
            rng = np.random.default_rng(42)
            boots = []
            for _ in range(2000):
                ub = rng.choice(u, size=len(u), replace=True)
                pb = rng.choice(p, size=len(p), replace=True)
                boots.append(pb.mean() / ub.mean())
            lo.append(np.percentile(boots, 2.5))
            hi.append(np.percentile(boots, 97.5))
        ax.plot(ks, ratios, marker="o", label=base.replace("storage_", ""))
        ax.fill_between(ks, lo, hi, alpha=0.15)

    ax.axhline(1.0, color="gray", linewidth=0.8, linestyle="--")
    ax.set_xscale("log")
    ax.set_xlabel("K (contracts per block)")
    ax.set_ylabel("PBT / UBT throughput ratio")
    ax.set_title("PBT vs UBT — locality sweep (T=256 stem touches/block)")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)
```

- [ ] **Step 2: Wire into main**

In whatever `if __name__ == "__main__":` (or main entry) the script has, call `plot_ratio_vs_K(df, graphs_dir / "ratio_vs_K.svg", theme)` and likewise for the light theme.

- [ ] **Step 3: Generate the graphs**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks/ubt-vs-pbt
python3 scripts/generate_graphs.py
ls graphs/ratio_vs_K.svg graphs-light/ratio_vs_K.svg
```
Expected: both SVGs exist.

- [ ] **Step 4: Commit**

```bash
git add ubt-vs-pbt/scripts/generate_graphs.py ubt-vs-pbt/graphs/ ubt-vs-pbt/graphs-light/
git commit -m "ubt-vs-pbt: ratio-vs-K headline graph"
```

#### Task J2: Rewrite `index.html` + top-level `README.md`

- [ ] **Step 1: Update `ubt-vs-pbt/index.html`**

Manual edit: rewrite the headline section to:
- Scope: "Locality sweep across K∈{1,10,100,256} contracts/block"
- Lead figure: ratio_vs_K
- Numeric headline: extract from `analysis_results.json` (PBT/UBT median at each K for each bench)
- Cite K=1 ↔ prior concentrated (1.75/2.83/2.41), K=256 ↔ prior scattered (0.84/1.43/1.05) as endpoint verifications
- Crossover point: where each curve crosses 1.0

- [ ] **Step 2: Update top-level `README.md`**

Replace the existing UBT-vs-PBT blurb (currently describing the scattered campaign) with one that describes the locality sweep and quotes the headline ratios at each K.

- [ ] **Step 3: Commit**

```bash
git add ubt-vs-pbt/index.html README.md
git commit -m "ubt-vs-pbt: rewrite index + README for locality sweep finding"
```

---

### Phase K: Push

#### Task K1: Push to origin/pbt only after user review

- [ ] **Step 1: Force-add data + push to feature branch**

```bash
cd /mnt/state_expiry_vol_data/bintrie-benchmarks
git add -f ubt-vs-pbt/data/
git commit -m "ubt-vs-pbt: locality sweep — data" || true   # may be empty if already tracked
git push -u origin feat/locality-sweep
```

- [ ] **Step 2: Open PR and let user review**

```bash
gh pr create --base pbt --head feat/locality-sweep \
  --title "ubt-vs-pbt: locality sweep — PBT's edge as a function of K" \
  --body "$(cat ubt-vs-pbt/SPEC-locality-sweep.md | head -50)"
```

- [ ] **Step 3: After user approval, fast-forward `pbt`**

```bash
gh pr merge --rebase --auto
```

---

## Risks & responses (operational)

| Risk | Response |
|---|---|
| Spamoor factorydeploytx times out on 256 × 5.6M-gas deploys | Verify Phase B3 (single-getter validation) first; if timeouts in real run, raise spamoor `--tx-wait-timeout` (defaults are usually fine for 1-min deploys). |
| K=1 measurements have high variance (only 256 cold reads in one Pebble region) | 20 runs per cell should still bound the CI; if not, push K=1 to 40 runs in a follow-up. |
| `_locality_k()` env var not propagated through `uv run` | `uv run` inherits env from the shell. If it doesn't, switch to passing via pytest `-p`-style config or wrap in `env LOCALITY_K=$K uv run …`. |
| Same-state gate fails — likely a `value=` propagation issue in account_transfer | Stop, diff sorted gas_used per (benchmark, K, run); usually reveals a counter or value mismatch. |
| 75 GB chaindata + 31 GB RAM → Pebble OOM during state-actor build | Stage-2 already uses `--cache 0`; Phase 1 caps cache at default. Watch `dmesg`. Reduce `SA_CONTRACTS` if needed. |
| getter constructor + 256 SSTOREs trips an Osaka tx-cap (16.7M gas) | Constructor cost ~5.6M well under cap; calldata 1.6KB × 16 = 26k. Total deploy tx < 6M. No issue. |

## Definition of done

- `ubt-vs-pbt/data/{ubt,pbt}/` populated with `_k{K}_run{N}_geth.log` for every cell.
- `ubt_vs_pbt_consolidated.csv`, `analysis_results.json` regenerated.
- `graphs/ratio_vs_K.svg` and light variant exist.
- `index.html` + top-level `README.md` updated with the locality-sweep narrative.
- Same-state gate passes for all 16 cells.
- Block-shape gate (`tx_count=1`, gas/block ≈ 6 M for storage) passes.
- Branch `feat/locality-sweep` pushed to origin; PR opened (or merged) to `pbt`.
