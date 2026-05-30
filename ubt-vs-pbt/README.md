# UBT vs PBT Benchmarks

Performance comparison of Ethereum's binary trie under two key-derivation strategies, with state reads served from a flat-state snapshot:

- **UBT** (Unified Binary Trie) — single key-derivation; a contract's storage slots scatter across the keyspace by a full hash.
- **PBT** (Partitioned Binary Trie) — zone-partitioned keys (`zone + H(addr)` high-bit prefix) so a contract's storage slots cluster contiguously in Pebble; the three zone subtries commit in parallel.

Same group depth (default 5), same EVM-level workload, same DB — only the trie's key derivation differs.

## What this benchmark probes

To isolate **where** PBT's advantage comes from, the benchmark forces each EVM operation to land in a *different* contract — so PBT cannot stream a single contract's clustered storage. Concretely, each invocation is one transaction that walks an in-memory table of `NUM_CONTRACTS` distinct contract addresses and `CALL`s a different one every iteration, with each call doing a `SLOAD` or `SSTORE` against that contract's storage.

The target contracts are tiny synthetic getters (CREATE2-deployed via spamoor's `factorydeploytx`, deterministic addresses, identical bytecode). On call with calldata `[slot, value, isWrite]` they do `SLOAD(slot)` or `SSTORE(slot, value)`. They are **not** real ERC20s — at this scale (~2000 contracts) `factorydeploytx` is the only feasible deployer (~20 min vs ~9 days for spamoor's `erc20_bloater`). So this is a clean **across-contract clustering probe**, not a faithful ERC20-semantics workload.

## Methodology fixes (mirroring mpt-vs-bintrie)

Two confounds were addressed before throughput could be trusted:

1. **One transaction per block.** `GAS_BENCHMARK_VALUE=16` sizes each invocation as one ~16M-gas tx (Osaka's per-tx cap), and `--dev.period 10` gives that tx its own block. Both configs produce byte-identical block structure (validated: same gas, `tx_count=1`) — no packing asymmetry, throughput is apples-to-apples.
2. **Cold-insert writes via a per-run counter offset.** The harness exports `SCATTERED_WRITE_OFFSET = run × 100M` as the first calldata word; the attack contract starts its counter there. Each run writes a never-used slot range — fresh cold inserts (~28k gas/slot), identical across configs so same-state still holds.

## Layout

```
ubt-vs-pbt/
├── README.md                            # this file
├── scripts/
│   ├── run_campaign.sh                  # top-level driver
│   ├── generate_dbs.sh                  # per-config DB build (state-actor + factorydeploytx)
│   ├── run_benchmarks.sh                # per-config benchmark suite (geth + execution-specs)
│   ├── compute_create2_addresses.py     # recomputes the N CREATE2 getter addresses
│   ├── analyze_data.py                  # statistical comparison (Mann-Whitney + bootstrap CIs)
│   └── generate_graphs.py               # report graphs (dark + light themes)
└── data/
    ├── ubt/                             # per-config artifacts (one log per cold invocation)
    │   ├── contracts.json               # the N deployed getter addresses
    │   ├── factorydeploy.log
    │   ├── scattered_sload_run<N>_geth.log    # benchmark geth slow-block logs
    │   ├── scattered_sstore_run<N>_geth.log
    │   ├── scattered_mixed_run<N>_geth.log
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

Each pair is checked out in a sibling git worktree under `/mnt/state_expiry_vol_data/`, so the state-actor `go.mod` `replace` directives resolve to the matching geth worktree without patching.

## Running

```bash
NUM_RUNS=30 NUM_CONTRACTS=2000 GAS_BENCHMARK_VALUE=16 \
TARGET_SIZE=500GB SPAMOOR_TARGET_GB=0 GROUP_DEPTH=5 COLD_CACHE=1 \
SA_ACCOUNTS=125000 SA_CONTRACTS=12800000 SA_MIN_SLOTS=1 SA_MAX_SLOTS=100000 \
GETH_UBT_BIN=… GETH_PBT_BIN=… STATE_ACTOR_UBT_BIN=… STATE_ACTOR_PBT_BIN=… \
SPAMOOR_BIN=… EXEC_SPECS=… UV=… \
DB_BASE=… RESULTS_DIR=./data \
bash scripts/run_campaign.sh
```

`COLD_CACHE=1` requires `sudo -v` (the script invokes `sudo sysctl vm.drop_caches=3` between runs).

## Configuration

| Var | Default | Purpose |
|---|---|---|
| `NUM_RUNS` | `1` | cold 1-tx blocks per benchmark per config |
| `NUM_CONTRACTS` | `10` | scattered getter target contracts (CREATE2-deployed) |
| `GAS_BENCHMARK_VALUE` | `16` | gas per invocation, in M (~16M = one Osaka-cap tx = one block) |
| `TARGET_SIZE` | `1GB` | state-actor's DB target size (just a cap; `SA_CONTRACTS` is what drives size at scale) |
| `GROUP_DEPTH` | `5` | bintrie group depth |
| `COLD_CACHE` | `0` | drop OS + Pebble caches between runs (Linux + sudo only) |
| `BENCHMARKS` | `"scattered_sload scattered_sstore scattered_mixed"` | space-separated override |
| `GETH_UBT_BIN`, `GETH_PBT_BIN` | `/tmp/bench-bins/geth-{ubt,pbt}` | geth binaries |
| `STATE_ACTOR_UBT_BIN`, `STATE_ACTOR_PBT_BIN` | `/tmp/bench-bins/state-actor-{ubt,pbt}` | state-actor binaries |
| `SPAMOOR_BIN` | (path) | spamoor binary (needs `factorydeploytx` scenario) |
| `EXEC_SPECS` | (path) | execution-specs checkout (provides `scripts/test_scattered_storage.py`) |
| `RESULTS_DIR` | `./data` | where CSVs and logs land |
| `DB_BASE` | `/tmp/ubt-vs-pbt-dbs` | where built DBs live |

## Same-state guarantee

Both configs see byte-identical EVM-level workload:
- state-actor `-seed 25519` → identical logical accounts/contracts/slots.
- The CREATE2 factory is a well-known deterministic deployer wallet at nonce 0, and the getter initcode is identical, so the 2000 deployed addresses (salts `0..NUM_CONTRACTS-1`) are byte-identical across configs (asserted: `diff ubt/contracts.json pbt/contracts.json`).
- The harness passes the same `SCATTERED_WRITE_OFFSET` per run to both configs → identical write-slot sequences.

Verified post-run by aggregate `gas_per_slot` ratio ≈ 1.0 across all three benchmarks.

## What the campaign currently reports

See [`index.html`](index.html) for the full report. Headline (scattered access, 75 GB / GD5 / cold cache / 30 runs / 1-tx blocks): reads 0.84× (PBT slower — locality gone), writes 1.43× (PBT faster — parallel commit), mixed 1.05× (NS). PBT's edge decomposes into a structural write win plus a workload-dependent locality bonus on reads.
