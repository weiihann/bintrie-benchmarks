# UBT vs PBT Benchmarks

Performance comparison of Ethereum's binary trie under two key-derivation strategies:

- **UBT** (Unified Binary Trie) — bitarray path encoding, single unified key-derivation (no zone partitioning).
- **PBT** (Partitioned Binary Trie) — bitarray + zone-partitioned key derivation (basic-data, code-chunk, storage-slot each hash into their own zone) + parallel zone commit.

Both configs use the same group depth (default 5) and the same EVM-level workload. The only variable under test is the trie-side change.

The workload spreads across multiple ERC20 contracts (default 10). The bloat phase deploys `NUM_CONTRACTS` contracts, splitting the target size evenly; the benchmark phase visits them on a **power-law weighted schedule** — each run performs `VISITS_PER_RUN` benchmark invocations distributed across the contracts by a Zipf (`1/rank^POWERLAW_EXP`) law, so a few "hot" contracts are visited many times and a long tail once (e.g. 30 visits → counts `[10,5,3,3,2,2,2,1,1,1]`). Which contract is hottest, and the interleaving (highest-averages placement, so the hot contract is spread evenly rather than fired back-to-back), are pure functions of `CONTRACT_ORDER_SEED` + the contract count — identical across configs, benchmarks, and runs, so UBT and PBT see the exact same contract-access sequence and only the trie shape differs.

## Status

This directory currently hosts the **local smoke test** at 1GB scale (laptop, hot cache, 1 run per benchmark). The smoke test validates that the orchestration pipeline produces all expected artifacts end-to-end. **The actual statistical campaign runs on a dedicated bare-metal Linux machine at 400GB scale with 10 cold-cache runs per benchmark** — same scripts, different env vars.

Do not draw performance conclusions from smoke-test output. Use it only to confirm the pipeline works.

## Layout

```
ubt-vs-pbt/
├── README.md                            # this file
├── scripts/
│   ├── run_campaign.sh                  # top-level driver
│   ├── generate_dbs.sh                  # per-config DB build (state-actor + spamoor)
│   ├── run_benchmarks.sh                # per-config benchmark suite (geth + execution-specs)
│   └── analyze_data.py                  # statistical comparison (Mann-Whitney + bootstrap CIs)
└── data/
    ├── ubt/                             # per-config artifacts
    │   ├── contracts.json               # the N deployed contract addresses
    │   ├── spamoor_c<N>.log             # per-contract bloat logs
    │   ├── <bench>_run<R>_c<idx>_geth.log   # per-contract benchmark geth logs
    │   └── csv/                         # extracted CSVs (carry a `contract` column)
    ├── pbt/
    └── ubt_vs_pbt_consolidated.csv      # merged input for analyze_data.py
```

## Branches

Use the **flat-state** branches — they wire up the binary-trie-native flat state
(`'F'`-prefix reader + write-on-commit), so state reads are served from a blob
fetch instead of a full trie traversal. That is what makes `state_read_ms`
benchmark-realistic.

| Config | geth branch (worktree) | state-actor branch (worktree) |
|---|---|---|
| `ubt` | `feat/binary-trie/flat-state` (`go-ethereum-flat-state`) | `bench/flat-state-base` (`state-actor-flat-state`) |
| `pbt` | `binary/pbt-flat-state` (`go-ethereum-pbt-flat-state`) | `bench/flat-state-pbt` (`state-actor-pbt-flat-state`) |

Build both pairs and stash the binaries before running the campaign (each branch
lives in its own worktree, so no checkout-switching is needed):

```bash
# geth:
make -C /Users/han/Documents/Codes/go-ethereum-flat-state geth \
  && cp /Users/han/Documents/Codes/go-ethereum-flat-state/build/bin/geth /tmp/bench-bins/geth-flat-state
make -C /Users/han/Documents/Codes/go-ethereum-pbt-flat-state geth \
  && cp /Users/han/Documents/Codes/go-ethereum-pbt-flat-state/build/bin/geth /tmp/bench-bins/geth-pbt-flat-state

# state-actor:
(cd /Users/han/Documents/Codes/state-actor-flat-state && go build -o state-actor . \
  && cp state-actor /tmp/bench-bins/state-actor-flat-state)
(cd /Users/han/Documents/Codes/state-actor-pbt-flat-state && go build -o state-actor . \
  && cp state-actor /tmp/bench-bins/state-actor-pbt-flat-state)
```

Then point the campaign at them (these are not the script defaults):

```bash
GETH_UBT_BIN=/tmp/bench-bins/geth-flat-state \
GETH_PBT_BIN=/tmp/bench-bins/geth-pbt-flat-state \
STATE_ACTOR_UBT_BIN=/tmp/bench-bins/state-actor-flat-state \
STATE_ACTOR_PBT_BIN=/tmp/bench-bins/state-actor-pbt-flat-state \
bash scripts/run_campaign.sh
```

For the **pre-flat-state baseline** (every read traverses the trie — the "before"
numbers), build from the parent branches instead: geth `feat/binary-trie/bitarray`
+ state-actor `bench/bitarray-base` (`ubt`), and geth `binary/pbt` + state-actor
`bench/bitarray-pbt` (`pbt`).

## Running the smoke test

From this directory:

```bash
bash scripts/run_campaign.sh
```

That's the default — `NUM_RUNS=1`, `TARGET_SIZE=1GB`, `NUM_CONTRACTS=10`, `VISITS_PER_RUN=30`, `COLD_CACHE=0` (hot cache, no `sudo` needed). Benchmark invocations are `3 benchmarks × 2 configs × NUM_RUNS × VISITS_PER_RUN`, so the smoke run is 180 invocations — budget a few hours on a laptop, or drop `VISITS_PER_RUN` for a faster sanity check.

Output lands in `data/ubt/`, `data/pbt/`, `data/ubt_vs_pbt_consolidated.csv`, `data/analysis_results.json`.

## Configuration

All knobs are env vars with sensible defaults:

| Var | Default | Purpose |
|---|---|---|
| `NUM_RUNS` | `1` | runs per benchmark per config |
| `TARGET_SIZE` | `1GB` | state-actor's DB target |
| `SPAMOOR_TARGET_GB` | `0.1` | ERC20 bloat size, split evenly across contracts |
| `NUM_CONTRACTS` | `10` | ERC20 contracts to deploy + benchmark |
| `VISITS_PER_RUN` | `30` | weighted benchmark invocations per run, spread across the contracts |
| `POWERLAW_EXP` | `1.0` | Zipf exponent for the contract-visit weighting (higher = steeper) |
| `CONTRACT_ORDER_SEED` | `ubt-vs-pbt-contract-order` | seed pinning the weighted visit schedule |
| `GROUP_DEPTH` | `5` | bintrie group depth |
| `COLD_CACHE` | `0` | drop OS + Pebble caches between runs (Linux + sudo only) |
| `BENCHMARKS` | `"erc20_balanceof erc20_approve mixed_sload_sstore"` | space-separated override |
| `GETH_UBT_BIN`, `GETH_PBT_BIN` | `/tmp/bench-bins/geth-{ubt,pbt}` | geth binaries |
| `STATE_ACTOR_UBT_BIN`, `STATE_ACTOR_PBT_BIN` | `/tmp/bench-bins/state-actor-{ubt,pbt}` | state-actor binaries |
| `SPAMOOR_BIN` | `/Users/han/Documents/Codes/spamoor/bin/spamoor` | spamoor binary |
| `EXEC_SPECS` | `/Users/han/Documents/Codes/execution-specs` | execution-specs checkout |
| `RESULTS_DIR` | `./data` | where CSVs and logs land |
| `DB_BASE` | `/tmp/ubt-vs-pbt-dbs` | where built DBs live |

## Production campaign

To run on the dedicated bench machine (Linux, ~400GB scale, 10 cold-cache runs):

```bash
NUM_RUNS=10 TARGET_SIZE=400GB COLD_CACHE=1 bash scripts/run_campaign.sh
```

`COLD_CACHE=1` requires `sudo -v` first (the script invokes `sudo sysctl vm.drop_caches=3` between runs).

## Same-state guarantee

Both configs see byte-identical EVM-level workload:
- state-actor `-seed 25519` → identical logical accounts/contracts/slots.
- spamoor `--seed=ubt-vs-pbt-smoke` with per-contract seeds `${SPAMOOR_SEED}-c<N>` → identical ERC20 deploys + bloat transactions. Each contract's address depends only on `(privkey, seed)`, not the trie backend, so `ubt/contracts.json` and `pbt/contracts.json` are identical (asserted at the end of `generate_dbs.sh`).
- The benchmark visits contracts on a weighted schedule derived purely from `CONTRACT_ORDER_SEED` + the contract count + `VISITS_PER_RUN` + `POWERLAW_EXP`, so the access sequence is identical across configs, benchmarks, and runs.

PBT changes only **key derivation**, so on-disk stem distributions differ. The variable under test is the trie representation, not the workload.

Sanity check: in the consolidated CSV, per-block `gas_used` should be near-identical between configs for matched `(benchmark, run, contract, block_number)` tuples.
