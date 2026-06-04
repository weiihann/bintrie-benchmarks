# Reproduce the 100M-gas (metrics) campaign on another machine

Self-contained recipe to rebuild the binaries, DBs, and rerun the metrics-instrumented
100M-gas UBT-vs-PBT-v2 locality campaign. The orchestration scripts are in `../scripts/`
(`run_campaign.sh`, `generate_dbs.sh`, `run_benchmarks.sh`, `getter_buckets.py`,
`parse_metrics.py`); this bundle adds the **fork patches**, **runners**, and an **env
template**. See `../ARM64-REPRO-REPORT.md` for what it measures and the findings.

## 0. Prereqs
- Linux, Go **1.24+**, `uv`, `curl`, `python3`.
- Fast SSD with **≥300 GB free** (two ~100 GB DBs + journals/bloat).
- Passwordless `sudo -n /usr/sbin/sysctl -w vm.drop_caches=3` (cold-cache) — or set `COLD_CACHE=0`.
- Everything off the system disk: edit `runners/env.sh.example` → `env.sh` and point `WORK`
  at a big-disk path (it routes GOPATH/GOCACHE/TMPDIR/DB_BASE there).

## 1. Clone the forks (weiihann/*) and check out the paired branches
```
geth      weiihann/go-ethereum   feat/binary-trie/flat-state   @ 1eca91736   (UBT)
geth      weiihann/go-ethereum   binary/pbt-flat-state         @ 6e82df62b   (PBT v2, zoned keys)
state-actor weiihann/state-actor bench/flat-state-base                       (UBT)
state-actor weiihann/state-actor bench/flat-state-pbt                        (PBT)
spamoor   weiihann/spamoor       master
exec-specs weiihann/execution-specs bench/locality-sweep       @ dec9cf9
```
geth's two branches are checked out as **sibling git worktrees** named exactly
`go-ethereum-flat-state` and `go-ethereum-pbt-flat-state` (state-actor's go.mod `replace`
resolves to them).

## 2. Apply the patches (in each fork checkout)
All patches are tiny and apply on top of the commits above.
```bash
# geth — same patch applies to BOTH worktrees (identical files):
#   params.MaxTxGas 1<<24 -> 1<<30  (per-tx gas cap bypass)
#   txMaxSize 4*txSlotSize -> 32*txSlotSize  (1MB, for ~300KB calldata)
git -C go-ethereum-flat-state      apply .../patches/geth-100m.patch
git -C go-ethereum-pbt-flat-state  apply .../patches/geth-100m.patch

# execution-specs — EIP-7825 cap off + env-driven T_TOUCHES + derived memory layout
git -C execution-specs apply .../patches/execution-specs-100m.patch   # on bench/locality-sweep

# state-actor — adds --metrics-dump (geth metrics.Enable + prometheus dump at end of build)
#   same patch applies to BOTH branches (identical main.go)
git -C state-actor apply .../patches/state-actor-100m.patch
```

## 3. Build the binaries (names the runners expect, into $BENCH_BINS)
```bash
# patched geth (per worktree)
(cd go-ethereum-flat-state     && make geth && cp build/bin/geth $BENCH_BINS/geth-ubt-100m)
(cd go-ethereum-pbt-flat-state && make geth && cp build/bin/geth $BENCH_BINS/geth-pbt-100m)
# patched state-actor (per branch)
(cd state-actor && git checkout bench/flat-state-base && go build -o $BENCH_BINS/state-actor-ubt-m .)
(cd state-actor && git checkout bench/flat-state-pbt  && go build -o $BENCH_BINS/state-actor-pbt-m .)
# spamoor
(cd spamoor && make && cp bin/spamoor $BENCH_BINS/spamoor)
# execution-specs harness
(cd execution-specs && uv sync)   # pin Python 3.12; bench/locality-sweep
```

## 4. Run
```bash
source env.sh
bash runners/run-smoke-100m-metrics.sh    # ~10 min, 1GB — validates the whole pipeline first
bash runners/run-100mgas-metrics.sh       # full: ~100GB DBs, NUM_RUNS=10, ~12-14h
```
Outputs land in `$RESULTS_DIR` (`results/100mgas-metrics/`): per-block `ubt_vs_pbt_consolidated.csv`,
per-cell `*_metrics.prom`, the wide `metrics_consolidated.csv` (1009 metrics/cell), and
state-actor build dumps. `METRICS_SCRAPE=1` (set in the runner) turns scraping on.

## 5. Gates / sanity
- block-shape: every benchmark block `tx_count=1`, ~100M gas
- same-state: `storage_slots_written` identical UBT vs PBT per cell
- metrics: `metrics_consolidated.csv` has 1 row/cell; `state/read/storage` identical UBT/PBT

## Known measurement caveats (see report)
- Throughput is wall-clock; per-cell PBT/UBT ratios carry ~±0.05 (±0.1 on write cells) of
  run-to-run noise — async pebble compaction + cold-NVMe variance + a fresh DB's
  non-deterministic SSTable layout. Differences inside that band are not signal.
- The campaign measures all UBT cells then all PBT cells (separate ~3.5h windows), so slow
  drift biases the ratio. **Interleaving configs per cell** would make the ratio drift-robust
  — a worthwhile change before drawing fine-grained conclusions.
- geth `eth/db/chaindata/disk/read` reads 0 (pebble mmap reads are page faults, uncounted);
  use `cache/block/{hit,miss}` + `system/disk/read*` as read proxies.
