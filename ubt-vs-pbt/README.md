# UBT vs PBT Benchmarks

Performance comparison of Ethereum's binary trie under two key-derivation strategies:

- **UBT** (Unified Binary Trie) — bitarray path encoding, single unified key-derivation (no zone partitioning).
- **PBT** (Partitioned Binary Trie) — bitarray + zone-partitioned key derivation (basic-data, code-chunk, storage-slot each hash into their own zone) + parallel zone commit.

Both configs use the same group depth (default 8) and the same EVM-level workload. The only variable under test is the trie-side change.

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
    ├── ubt/                             # per-config raw CSVs + benchmark logs
    ├── pbt/
    └── ubt_vs_pbt_consolidated.csv      # merged input for analyze_data.py
```

## Branches

| Config | geth branch | state-actor branch |
|---|---|---|
| `ubt` | `feat/binary-trie/bitarray` | `bench/bitarray-base` |
| `pbt` | `binary/pbt` | `bench/bitarray-pbt` |

Build both pairs and stash the binaries before running the campaign:

```bash
# In go-ethereum:
git checkout feat/binary-trie/bitarray && make geth && cp build/bin/geth /tmp/bench-bins/geth-ubt
git checkout binary/pbt && make geth && cp build/bin/geth /tmp/bench-bins/geth-pbt

# In state-actor:
git checkout bench/bitarray-base && go build -o state-actor . && cp state-actor /tmp/bench-bins/state-actor-ubt
git checkout bench/bitarray-pbt && go build -o state-actor . && cp state-actor /tmp/bench-bins/state-actor-pbt
```

## Running the smoke test

From this directory:

```bash
bash scripts/run_campaign.sh
```

That's the default — `NUM_RUNS=1`, `TARGET_SIZE=1GB`, `COLD_CACHE=0` (hot cache, no `sudo` needed). Total wall time on a laptop: ~45–60 min.

Output lands in `data/ubt/`, `data/pbt/`, `data/ubt_vs_pbt_consolidated.csv`, `data/analysis_results.json`.

## Configuration

All knobs are env vars with sensible defaults:

| Var | Default | Purpose |
|---|---|---|
| `NUM_RUNS` | `1` | runs per benchmark per config |
| `TARGET_SIZE` | `1GB` | state-actor's DB target |
| `SPAMOOR_TARGET_GB` | `0.1` | ERC20 bloat size on top of base DB |
| `GROUP_DEPTH` | `8` | bintrie group depth |
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
- spamoor `--seed=ubt-vs-pbt-smoke` → identical ERC20 deploy + bloat transactions.

PBT changes only **key derivation**, so on-disk stem distributions differ. The variable under test is the trie representation, not the workload.

Sanity check: in the consolidated CSV, per-block `gas_used` should be near-identical between configs for matched `(benchmark, run, block_number)` triples.
