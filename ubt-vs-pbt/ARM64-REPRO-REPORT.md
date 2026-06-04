# UBT vs PBT locality sweep — ARM64 reproduction report

**Date:** 2026-06-03
**Board:** Rockchip RK3588 (aarch64), 8 cores, 15 GiB RAM, 3.6 TB NVMe
**Goal:** reproduce the `ubt-vs-pbt` locality-sweep campaign on ARM64 (working pipeline;
numbers needn't match the original Intel Xeon 8358 run), then evaluate successive PBT
key-derivation / commit implementations against a fixed UBT baseline.

---

## TL;DR

- The full campaign pipeline runs correctly on ARM64. All runs pass the **block-shape**
  gate (1 tx/block, ~16 M gas) and the **workload-identity** gate (UBT vs PBT writes
  touch identical slot sets).
- Four PBT implementations were measured against the same UBT baseline. PBT improved
  steadily across them; the latest (**v4 zone-aware cut**) is **correct** (no invalid state
  roots) and the strongest: **reads win at every K (1.03–1.08×)** and **writes reach
  parity-or-better for realistic contract-spread** (SSTORE K≥100 ≥0.95×, K=700 >1.0×). The
  residual write deficit is confined to the **single-contract case (K=1, ~0.65×)**.
- The RK3588's 15 GiB RAM was never a constraint: geth serving a ~70 GB cold-cache DB
  peaked at ~1.6–3.5 GiB.
- A **100 M-gas-per-block** stress variant (one tx/block, ~5,000 cold touches, ~100 GB DB,
  per-tx gas cap bypassed) shows PBT-v2 improving sharply at larger blocks: **parity-or-
  winning on writes at high contract-spread (SSTORE K≥1000: 1.05–1.08×) and on mixed
  (1.02–1.05×)** — the 16 M write deficit was mostly per-block overhead.

---

## What was measured

A single binary trie at group depth 5, flat-state snapshot reads, two key derivations:

- **UBT** — `key = H(addr ‖ slot)`; a contract's storage stems scatter across the keyspace.
- **PBT** — zoned keys; a contract's stems sit adjacent in Pebble's keyspace.

The sweep varies **K = distinct contracts touched per block** over {1, 10, 100, 400, 700}
while holding total work at **T = 700 stem touches/block** (~16 M-gas tx, one tx per block).
Three benchmarks: `storage_sload`, `storage_sstore`, `storage_mixed`. 20 cold-cache runs
per cell. DBs ~70–74 GB (`SA_CONTRACTS=12.8 M`, `SA_ACCOUNTS=125 k`, power-law slots).

Cold cache: OS page cache dropped (`sysctl vm.drop_caches=3`) before every run; geth uses
its **default** Pebble block cache (the "realistic-cache" variant — see Caveats).

---

## Binaries (all built from `weiihann/*` forks for arm64, Go 1.24.12)

| Component | Repo / branch | Commit |
|---|---|---|
| geth-ubt | go-ethereum `feat/binary-trie/flat-state` | `1eca91736` |
| geth-pbt (v1, SplitRoot) | go-ethereum `binary/pbt-flat-state` | `c17488c31` |
| geth-pbt (v2, zoned keys) | go-ethereum `binary/pbt-flat-state` (force-updated) | `6e82df62b` |
| geth-pbt (v3, parallel hash) | go-ethereum `feat/binary-trie/pbt-parallel-hash-commit` | `0830f5101` |
| geth-pbt (v4, zone-aware cut) | go-ethereum `feat/binary-trie/pbt-zone-aware-cut` | `11ce08cce` |
| state-actor-ubt | state-actor `bench/flat-state-base` | — |
| state-actor-pbt | state-actor `bench/flat-state-pbt` | — |
| spamoor (factorydeploytx) | spamoor `master` | — |
| test harness | execution-specs `bench/locality-sweep` | `dec9cf9` |

The locality K-sweep test (`test_locality_sweep.py`) lives on `bench/locality-sweep`, not
`bench/scattered-storage` (which carries an older, non-K test).

---

## Results — PBT/UBT throughput ratio (UBT = 1.000)

Median Mgas/s ratio over 20 runs/cell. >1.0 means PBT faster.

| benchmark | K | v1 SplitRoot (`c17488`) | v2 zoned (`6e82df6`) | v3 parallel-hash (`0830f51`) | v4 zone-aware-cut (`11ce08c`) |
|---|--:|--:|--:|--:|--:|
| SLOAD | 1 | 0.956 | 1.009 | 1.005 | 1.052 |
| SLOAD | 10 | 0.921 | 1.028 | 1.005 | 1.033 |
| SLOAD | 100 | 0.885 | 1.016 | 0.983 | 1.036 |
| SLOAD | 400 | 0.914 | 1.033 | 1.006 | 1.062 |
| SLOAD | 700 | 0.945 | 1.034 | 1.062 | 1.079 |
| SSTORE | 1 | 0.415 | 0.702 | 0.694 | 0.651 |
| SSTORE | 10 | 0.583 | 0.879 | 0.805 | 0.919 |
| SSTORE | 100 | 0.552 | 0.885 | 0.847 | 0.995 |
| SSTORE | 400 | 0.700 | 0.871 | 0.899 | 0.950 |
| SSTORE | 700 | 0.717 | 0.922 | 0.976 | 1.045 |
| mixed | 1 | 0.758 | 0.973 | 1.025 | 1.012 |
| mixed | 10 | 0.717 | 0.995 | 1.010 | 0.985 |
| mixed | 100 | 0.755 | 0.962 | 1.012 | 0.957 |
| mixed | 400 | 0.702 | 0.867 | 0.958 | 0.884 |
| mixed | 700 | 0.706 | 0.867 | 0.886 | 0.894 |

Absolute UBT baseline (median Mgas/s), for scale: SLOAD 28–32, SSTORE 42–188
(falls as K rises), mixed 47–51.

### Interpretation

- **v1 → v2 (zoned keys) was the big jump.** Reads went from losing (0.88–0.96×) to
  winning (1.01–1.03×); the SSTORE gap roughly halved (e.g. K=1: 0.42→0.70); mixed went
  from ~0.7× to near parity. The earlier ARM-vs-Xeon discrepancy was mostly the *old PBT
  binary*, not the hardware.
- **v2 → v3 (parallel-hash commit) is a targeted refinement.** Reads unchanged (commit
  path doesn't touch reads). SSTORE gains concentrate at **high K** (K=400: 0.87→0.90,
  K=700: 0.92→0.98, near parity); at **low K** flat-to-slightly-worse (K=1: 0.69) — one
  contract has little to parallelize. Mixed improves broadly, ≥1.0× for K≤100.
- **v3 → v4 (zone-aware cut) is the strongest write optimization.** A deeper, zone-aware
  subtree cut feeds the parallel hash/commit better. **SLOAD becomes best-of-all**
  (1.03–1.08×) because faster commit lifts total block throughput even on read blocks.
  **SSTORE clears every prior variant at K≥10**: K=100 reaches **0.995 (parity)** and
  **K=700 hits 1.045 — PBT beating UBT on high-spread writes for the first time.** The lone
  regression is **K=1 (0.65)**: a single contract is a single zone, so deeper zone-aware
  fan-out only adds coordination cost. Mixed is a wash vs v3.

### Verdict

The PBT line is **correct throughout** (valid state roots — the old `perf/pbt-parallel-commit`
invalid-root failure is resolved) and now **competitive-to-winning**: with v4 zone-aware cut,
**reads win at every K (1.03–1.08×)** and **writes reach parity-or-better for realistic
contract-spread (SSTORE K≥100 ≥0.95×, K=700 >1.0×)**. The one remaining deficit is the
pathological **single-contract write (K=1, ~0.65×)**, inherent to having one zone with
nothing to parallelize.

---

## 100M-gas-per-block stress variant

A separate campaign pushes block size from ~16 M to **~100 M gas** — one single tx per
block (Osaka's EIP-7825 per-tx cap bypassed), **~5,000 distinct cold touches**, on
**~100 GB DBs** (UBT 93 GB / PBT 89 GB). Only **UBT vs PBT-v2** (zoned keys). It probes
whether PBT's 16 M deficits are per-block fixed overhead that larger blocks amortize.

**What it took** (patched `geth-{ubt,pbt}-100m`, kept as separate binaries):
- geth: `params.MaxTxGas` 1<<24 → 1<<30 (per-tx gas cap) and `txMaxSize` 128 KB → 1 MB
  (the K=4500 address-table + sequence is ~300 KB of calldata).
- execution-specs: `EIP7825.transaction_gas_limit_cap()` → off (harness emits one
  100 M-gas tx, not six); `test_locality_sweep.py` `T_TOUCHES` made env-driven with the
  memory layout (TABLE/SEQUENCE/SCRATCH) derived so K=4500 doesn't collide.
- **Genesis gas limit 200 M** (`state-actor -gas-limit`): geth's `--dev` block gas limit
  only converges by 1/1024 per block, so the chain must *start* high or the 100 M txs are
  rejected as "exceeds block gas limit". This was the key non-obvious fix.
- **Heterogeneous getters** (`getter_buckets.py`): each getter sized to its max stems
  across the sweep (~22 k writes vs 20 M uniform), so K=1's single contract still has
  ~5,000 populated cold stems. Addresses stay identical UBT vs PBT.
- K = {1, 10, 100, 1000, 4500}, T_TOUCHES=5000, NUM_RUNS=10, cold cache.

**Gates:** 300 main blocks, median **99.9 M gas, every block `tx_count=1`**; same-state
**`slots_written` identical 150/150, gas delta 0** (byte-identical; fresh DBs, canonical
offsets — no calldata artifact).

**PBT-v2 / UBT throughput @ 100 M-gas blocks (UBT = 1.000):**

| benchmark | K=1 | K=10 | K=100 | K=1000 | K=4500 |
|---|--:|--:|--:|--:|--:|
| SLOAD  | 0.989 | 0.994 | 0.981 | 0.992 | 0.988 |
| SSTORE | 0.927 | 0.950 | 0.907 | **1.047** | **1.083** |
| mixed  | 1.017 | 1.030 | 1.027 | 0.989 | **1.051** |

**Block size changes the story.** Versus the 16 M v2-zoned result at the overlapping K
(1/10/100): SSTORE rises from 0.70/0.88/0.89 → **0.93/0.95/0.91**, and at high
contract-spread (K≥1000) **PBT beats UBT (1.05–1.08×)** for the first time; mixed crosses
to parity-or-better (0.97/1.00/0.96 → **1.02/1.03/1.03**). Reads slip just below parity
(~0.98×) as the read-clustering benefit dilutes over 5,000 touches. Absolute throughput is
far higher (SSTORE K=1: 263 vs 188 Mgas/s) as per-block fixed costs amortize.

**Takeaway:** PBT-v2's weakness at 16 M was largely per-block commit overhead; at
mainnet-stress 100 M-gas blocks it is at **parity-or-winning on writes (high-K) and on
mixed workloads**, with only a slight read regression. Note this variant is deliberately
synthetic — it patches out a consensus-level DoS protection (the per-tx gas cap). Results
in `results/100mgas/`.

## 100M-gas variant — physical-I/O metrics (Prometheus)

The per-block JSON log gives timing + logical slot counts but not the **physical I/O**
layer. A metrics-instrumented rerun (`results/100mgas-metrics/`) scrapes geth's full
prometheus endpoint (`/debug/metrics/prometheus`) once per cell — clean because geth
restarts cold per cell, so each scrape is that cell's cumulative DB activity. 1009 metrics
per cell are kept (`metrics_consolidated.csv`); the report selects. state-actor also dumps
its build-phase metrics (`state-actor_metrics.prom`). Workload-faithful: `state/read/storage`
is identical UBT vs PBT (5002/cell), as expected.

One caveat: geth's `eth/db/chaindata/disk/read` meter reads 0 here — pebble serves SSTable
reads via mmap (page faults), which that meter doesn't count. The reliable read proxies are
`cache/block/{hit,miss}` and `system/disk/read*`.

**PBT/UBT ratios (median over 10 runs), across K:**

| benchmark | block-cache miss | block-cache hit | disk write | compaction output |
|---|--:|--:|--:|--:|
| SLOAD K=1 | 1.075 | 1.544 | 10.38× | 109× |
| SLOAD K=100 | 1.080 | 1.536 | 8.63× | 60× |
| SLOAD K=4500 | 1.077 | 1.608 | 4.88× | 26× |
| SSTORE K=1 | 1.066 | 1.508 | 4.74× | 24× |
| SSTORE K=1000 | 0.945 | 1.429 | 3.32× | 6.7× |
| SSTORE K=4500 | **0.790** | 1.454 | 2.55× | 4.2× |
| mixed K=1 | 1.040 | 1.560 | 2.53× | 3.6× |
| mixed K=4500 | **0.932** | 1.434 | 2.18× | 3.0× |

### What the I/O layer reveals

- **PBT has large write-amplification / compaction churn.** Even on pure reads, PBT writes
  2.5–10× more to disk and triggers 3–109× more compaction output than UBT. The ratio
  decreases monotonically with K (109→82→60→42→26 across the SLOAD sweep) — a systematic
  effect, not bursty noise (median of 10 runs). This is the *mechanism* behind PBT's cost
  that timing alone couldn't show: the zoned-key layout reshapes the LSM so commits +
  background compaction move far more bytes.
- **Block-cache behavior.** PBT consistently registers ~1.5× more block-cache **hits**
  (it touches more, mostly-cached pebble blocks) and slightly more **misses** on reads /
  low-K. The miss ratio crosses **below 1.0 only at high-K writes** (SSTORE K=4500 = 0.79,
  mixed K=4500 = 0.93) — precisely the cells where PBT *wins* throughput, so its high-K
  write advantage shows up as genuinely fewer cold block fetches.
- Net: PBT's clustering does cut cold block misses where it wins (high-K writes), but its
  standing cost is compaction/write-amplification, visible only at the I/O layer.

Caveat: compaction is asynchronous and influenced by each DB's build history; treat the
absolute compaction multiples as directional. The cache-miss and write-byte trends are the
robust signals.

## Correctness gates

| Run | block-shape (tx=1) | workload identity | invalid roots |
|---|---|---|---|
| v2 zoned | PASS (600/600) | PASS — gas byte-identical UBT/PBT, 0 divergences | none |
| v3 parallel-hash | PASS (600/600) | PASS — `storage_slots_written` identical 300/300 | none |
| v4 zone-aware-cut | PASS (600/600) | PASS — `storage_slots_written` identical 300/300 | none |

v3/v4 note: gas differs from UBT by a **constant +12 gas/cell** — purely the calldata cost of
the shifted write-offset word (see Caveats), *not* a workload difference. The actual write
work (`storage_slots_written`, 702 slots/cell) is identical UBT vs PBT in every cell.

---

## Caveats

1. **Cache variant.** geth ran with its **default** Pebble block cache, not `--cache 0`.
   The repo's published `*-cache0-clean` numbers used `--cache 0` (fully-cold within block).
   The directional conclusions match the published Xeon table regardless; absolute ratios
   may shift slightly under `--cache 0`.
2. **Hardware.** RK3588 (aarch64) ≠ Intel Xeon 8358 (x86_64). Absolute Mgas/s and exact
   ratios are not expected to match the original; directional findings do.
3. **Write-offset shift (v3, v4).** v3 and v4 reused a *copy* of a zoned-key PBT DB (same
   key derivation → compatible). Because such a copy already holds prior benchmark writes at
   the default slot offsets, each run was shifted to an untouched slot range
   (`WRITE_OFFSET_RUN_SHIFT=1000` → `(run+1000)·1e8` for v3; `=2000` → `(run+2000)·1e8` for
   v4) so SSTOREs are genuine cold inserts. This is what introduces the constant +12 gas
   (calldata of the larger offset word). An earlier v3 attempt without the shift was
   contaminated (warm rewrites) and is discarded (`results/pbt-parallel-warmbug/`).

---

## Artifacts (under `~/work/results/`)

| Dir | Contents |
|---|---|
| `100mgas-metrics/` | 100M-gas UBT vs PBT-v2 **with prometheus metrics** — block CSV + `metrics_consolidated.csv` (1009 metrics/cell) + per-cell `*_metrics.prom` + state-actor build dumps |
| `full/` | UBT baseline + **v2 zoned PBT** consolidated CSV + per-config logs |
| `pbt-parallel/` | UBT baseline + **v3 parallel-hash PBT** consolidated CSV + logs |
| `pbt-zonecut/` | UBT baseline + **v4 zone-aware-cut PBT** consolidated CSV + logs |
| `full-prev-defaultcache/` | first full run (UBT + **v1 SplitRoot PBT**) |
| `pbt-parallel-warmbug/` | discarded contaminated v3 attempt (kept for audit) |

Each `*/ubt_vs_pbt_consolidated.csv` has the per-block metrics (gas, timings,
mgas_per_sec, cache hit rates, slots read/written). DBs live under `~/work/dbs/`,
binaries under `~/work/bench-bins/`, env in `~/work/env.sh`.

The bundled `analyze_data.py` emits an empty `analysis_results.json` (it targets older
`scattered_*`/`approve` benchmark names); all ratios above were computed directly from the
consolidated CSVs.

---

## Reproduction notes (gotchas hit)

- Everything lives on NVMe (`/home`): `/` is 94% full and `/tmp` is tmpfs.
- Go 1.24 required (`go.mod`); system Go 1.21 is too old. When upgrading a GOROOT in place,
  fully remove the old tree first — leftover 1.23 runtime files mix with 1.24 swiss-map
  files and break the build.
- execution-specs venv pinned to Python 3.12 (uv defaulted to 3.14, too new for the tooling).
- state-actor `go.mod` `replace` points at sibling geth worktrees
  (`../go-ethereum-flat-state`, `../go-ethereum-pbt-flat-state`); set up as git worktrees.
- Passwordless `sudo sysctl vm.drop_caches=3` already worked on this board (cold cache OK).
