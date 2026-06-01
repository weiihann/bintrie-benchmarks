# UBT vs PBT Benchmarks

Locality-sweep mechanism characterization for Ethereum's binary trie under two
key-derivation strategies, with state reads served from a flat-state snapshot:

- **UBT** (Unified Binary Trie) — `key = H(addr ‖ slot)`. A contract's storage
  stems are randomly scattered across the keyspace.
- **PBT** (Partitioned Binary Trie) — `key = zone_prefix ‖ H(addr) ‖ slot`.
  Still a single binary trie, but the prefix forces a contract's storage stems
  to sit adjacent in Pebble's keyspace.

Same group depth (5), same EVM-level workload, same DB scale — only the key
derivation differs.

See [`index.html`](index.html) for the full report, [`SPEC-locality-sweep.md`](SPEC-locality-sweep.md)
for the design spec, and [`PLAN-locality-sweep.md`](PLAN-locality-sweep.md) for
the implementation plan.

## Headline

PBT lands **at parity with UBT** (ratios 0.94–1.07×), modestly favored on
high-clustering workloads. The original "PBT loses 0.54–0.97×" result was the
product of two compounding methodology issues:

1. The PBT geth fork carries a `parallel zone updates` commit (`928668da0`)
   that recursively deep-copies both halves of the trie on every block. Each
   commit pays ~30–70 ms of `copyFrom` overhead for a parallelism gain that
   almost never materializes (zone activity is heavily skewed in practice).
2. Geth was started with `--cache 0`, disabling Pebble's block cache and
   suppressing the within-block read locality PBT is designed to exploit.

After disabling the parallel-zone code (one-line patch forcing the existing
sequential fallback) and using Pebble's default cache while still dropping
OS page cache between runs:

| benchmark | K=1 | K=10 | K=100 | K=256 |
|---|---:|---:|---:|---:|
| SLOAD  | 0.99× | 0.99× | 1.01× | 1.02× |
| SSTORE | **1.07×** | **1.07×** | 1.02× | 0.94× |
| mixed  | **1.05×** | 0.99× | **1.05×** | 1.00× |

(PBT-noparallel / UBT throughput. Same-state: 0/480. Block-shape: 480/480.)
PBT wins on workloads with high per-contract clustering (low K) and slightly
loses at full scatter (K=256). The mechanism is visible in the per-block
timing decomposition (see [index.html](index.html)): clustering reduces both
`state_read_ms` (4–8 ms at high K) and `state_hash_ms` (3 ms at low K).

## What this benchmark probes

The hypothesis: PBT's clustering should translate to faster cold cross-stem
reads when consecutive accesses hit the same contract. To map where that
mechanism wins, we sweep **K = number of distinct contracts touched per block**,
holding the total work constant at **T = 256 stem touches per block**.

| K | distribution | what it tests |
|---|---|---|
| 1 | 1 contract × 256 stems | max PBT clustering |
| 10 | 10 contracts × ~26 stems each | moderate clustering |
| 100 | 100 contracts × ~3 stems each | weak clustering |
| 256 | 256 contracts × 1 stem each | no clustering (full scatter) |

Within each contract, stems are visited in **stem-strided** order: slot indices
0, 256, 512, … so each touch hits a different stem (no in-stem reuse). This
distinguishes the design from the prior "concentrated" benchmark, which used
consecutive slot indices and was inadvertently measuring within-stem reuse, not
cross-stem clustering.

The target contracts are 256 tiny synthetic getters (CREATE2-deployed via
spamoor's `factorydeploytx`, deterministic addresses, identical bytecode across
configs). The constructor pre-populates 256 stems via `SSTORE(stem_idx*256, 1)`
so cold SLOADs always hit populated slots. They are **not** real ERC20s.

## Methodology

Two confounds were addressed before throughput could be trusted:

1. **One transaction per block.** `GAS_BENCHMARK_VALUE=6` sizes each invocation
   as one ~6 M-gas tx, and `--dev.gaslimit 20000000` + `--dev.period 1` gives
   that tx its own block. Both configs produce byte-identical block structure
   (validated by the block-shape gate: same gas, `tx_count=1`) — no packing
   asymmetry, throughput is apples-to-apples.

2. **Cold-insert writes via a per-run counter offset.** `SCATTERED_WRITE_OFFSET
   = run × 10⁸` is exported as the first calldata word; the attack contract
   starts its write-slot counter there. Each run writes a never-used slot range
   — fresh cold inserts (~28 k gas/slot), identical across configs so
   same-state still holds.

3. **Cold cache between every run.** `COLD_CACHE=1` triggers
   `sudo -n /usr/sbin/sysctl -w vm.drop_caches=3` between runs; geth started
   with `--cache 0`.

## Layout

```
ubt-vs-pbt/
├── README.md                            # this file
├── SPEC-locality-sweep.md               # design spec
├── PLAN-locality-sweep.md               # implementation plan
├── index.html                           # report
├── graphs/, graphs-light/               # ratio_vs_K, state_read_ratio_vs_K,
│                                          timing_breakdown_k1, timing_breakdown_k256
├── scripts/
│   ├── run_campaign.sh                  # top-level driver
│   ├── generate_dbs.sh                  # per-config DB build (state-actor + factorydeploytx)
│   ├── run_benchmarks.sh                # per-config benchmark suite (geth + execution-specs)
│   ├── build_initcode.py                # generates getter (N stems) + empty-account initcode
│   ├── k_distribution.py                # (target_idx, stem_idx) sequence for the K-sweep
│   ├── compute_create2_addresses.py     # recomputes the N CREATE2 getter addresses
│   ├── analyze_data.py                  # statistical comparison (legacy; runs on consolidated CSV)
│   ├── generate_graphs.py               # legacy graph generator (prior campaign)
│   ├── generate_locality_graphs.py      # locality-sweep report graphs
│   └── tests/                           # unit tests for build_initcode + k_distribution
└── data/
    ├── ubt/                             # per-config artifacts (one log per cold invocation)
    │   ├── contracts.json               # the 256 deployed getter addresses
    │   ├── accounts.json                # 256 empty-code account addresses (for future account benchmarks)
    │   ├── factorydeploy_getter.log
    │   ├── factorydeploy_account.log
    │   ├── storage_sload_k<K>_run<N>_geth.log    # benchmark geth slow-block logs
    │   ├── storage_sstore_k<K>_run<N>_geth.log
    │   ├── storage_mixed_k<K>_run<N>_geth.log
    │   └── csv/                         # extracted per-block CSVs
    ├── pbt/
    ├── ubt_vs_pbt_consolidated.csv
    └── analysis_results.json
```

## Branches

| Config | geth branch | state-actor branch |
|---|---|---|
| `ubt` | `feat/binary-trie/flat-state` | `bench/flat-state-base` |
| `pbt` | `binary/pbt-flat-state` | `bench/flat-state-pbt` |

Each pair is checked out in a sibling git worktree under
`/mnt/state_expiry_vol_data/`, so the state-actor `go.mod` `replace` directives
resolve to the matching geth worktree without patching.

## Running

```bash
NUM_RUNS=20 NUM_CONTRACTS=256 GAS_BENCHMARK_VALUE=6 NUM_STEMS=256 \
K_VALUES_STORAGE="1 10 100 256" \
TARGET_SIZE=500GB COLD_CACHE=1 GROUP_DEPTH=5 \
SA_ACCOUNTS=125000 SA_CONTRACTS=12800000 SA_MIN_SLOTS=1 SA_MAX_SLOTS=100000 \
GETH_UBT_BIN=… GETH_PBT_BIN=… STATE_ACTOR_UBT_BIN=… STATE_ACTOR_PBT_BIN=… \
SPAMOOR_BIN=… EXEC_SPECS=… UV=… \
DB_BASE=… RESULTS_DIR=./data \
bash scripts/run_campaign.sh
```

`COLD_CACHE=1` requires `sudo -v` (the script invokes `sudo sysctl
vm.drop_caches=3` between runs).

## Configuration

| Var | Default | Purpose |
|---|---|---|
| `NUM_RUNS` | `1` | cold 1-tx blocks per cell per config |
| `NUM_CONTRACTS` | `10` | scattered getter target contracts (CREATE2-deployed) |
| `NUM_STEMS` | `256` | stems pre-populated by each getter constructor |
| `GAS_BENCHMARK_VALUE` | `6` | gas per invocation, in M (~6 M = one tx = one block) |
| `K_VALUES_STORAGE` | `"1 10 100 256"` | space-separated K sweep values |
| `TARGET_SIZE` | `1GB` | state-actor's DB target size (cap; `SA_CONTRACTS` drives actual size) |
| `GROUP_DEPTH` | `5` | bintrie group depth |
| `COLD_CACHE` | `0` | drop OS + Pebble caches between runs (Linux + sudo only) |
| `BENCHMARKS` | `"storage_sload storage_sstore storage_mixed"` | space-separated override |
| `GETH_UBT_BIN`, `GETH_PBT_BIN` | `/tmp/bench-bins/geth-{ubt,pbt}` | geth binaries |
| `STATE_ACTOR_UBT_BIN`, `STATE_ACTOR_PBT_BIN` | `/tmp/bench-bins/state-actor-{ubt,pbt}` | state-actor binaries |
| `SPAMOOR_BIN` | (path) | spamoor binary (needs `factorydeploytx` scenario) |
| `EXEC_SPECS` | (path) | execution-specs checkout (provides `tests/benchmark/stateful/bloatnet/test_locality_sweep.py`) |
| `RESULTS_DIR` | `./data` | where CSVs and logs land |
| `DB_BASE` | `/tmp/ubt-vs-pbt-dbs` | where built DBs live |

## Same-state guarantee

Both configs see byte-identical EVM-level workload:

- state-actor `-seed 25519` → identical logical accounts/contracts/slots.
- The CREATE2 factory is a well-known deterministic deployer wallet at nonce 0,
  and the getter initcode is identical, so the 256 deployed addresses (salts
  `0..NUM_CONTRACTS-1`) are byte-identical across configs (asserted: `diff
  ubt/contracts.json pbt/contracts.json`).
- The harness passes the same `SCATTERED_WRITE_OFFSET` per run to both configs
  → identical write-slot sequences.
- The K-distribution sequence (`(target_idx, stem_idx)` pairs) is shipped in
  calldata, identical across configs.

Verified post-run by the same-state gate: `gas_used` is byte-identical UBT vs
PBT per cell across all 480 runs (0 divergences).

## Account-zone benchmarks (deferred)

`test_account_locality.py` (BALANCE-read + value-transfer, parametrized by K)
is in execution-specs but disabled in the campaign default — `account_transfer`
hangs geth at 10 GB RSS on both UBT and PBT (likely a flat-state path issue
under high-frequency value-transfer workloads). Empty-code "account" contracts
are still deployed by `generate_dbs.sh` so the account benchmarks can be
re-enabled once the hang is debugged.

## Verdict

The clustering mechanism works — PBT's prefix design measurably reduces cold
disk fetches, by up to 1.64×. But PBT's trie-shape tax (constant per block) is
2–4× larger than the read savings at 75 GB / 6 M-gas blocks. Whether PBT could
break even at larger DB scale (the clustering benefit should scale roughly
linearly with DB size while the tax stays constant) is an open question — see
the report's verdict section for projections.
