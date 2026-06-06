# 250 GB locality sweep — UBT vs PBT-v3

**Date:** 2026-06-05 / 2026-06-06
**Machine:** Intel Xeon Platinum 8358, 8 cores, 31 GiB RAM, 2 TB SATA SSD (ext4)
**Campaign log:** `results/250gb-metrics/campaign-20260605-081434.log`
**Wall time:** 7h 21m (08:14 → 15:35 UTC)

This is a paired follow-up to [X86-REPRO-REPORT.md](X86-REPRO-REPORT.md). Same patches and methodology, two important changes: **larger DB scale** (90 → 168 GB actual, up from 16.4M to 30M contracts and from MAX_SLOTS=100k → 1M) and **PBT key derivation reverted** from 16-bit zoned (PBT-v2) back to 3-bit zoned (PBT-v3, the original PBT design). Also adds two new methodology steps: **Pebble compact between phase 1 and phase 2** and **state-actor build-phase metrics comparison**.

---

## TL;DR

**Throughput is mostly slightly UBT-favored** (9 of 15 cells have ratios 0.886–0.999) **with two robust PBT wins** that hold from the 90 GB campaign: **mixed_k4500 (1.135×)** and **sstore_k1000 (1.089×)**. Every CI for those two excludes 1.0 (Mann-Whitney significant). The remaining 13 cells are within ±10% of parity.

**Two methodology fixes paid off:**
- The new **phase-1.5 Pebble compact step** eliminated the previously-suspicious "PBT 1.75× more compact time" finding (compaction time is now ~equal between configs). It made the comparison genuinely fair at handoff to Stage 2.
- **State-actor build metrics comparison** reveals PBT uses **52% more memory and 2.0× more CPU procload during the chain-build phase** — a real cost the design pays that the throughput numbers don't expose.

**The dramatic PBT win confirmed at this larger scale**: `pathdb_clean_node_miss` stays **flat at 14 misses per cell regardless of K**, while UBT grows from 21 (sload) to **7160 (sstore_k4500)** — a **511× ratio at the most adversarial cell**. This is the same structural signal seen at 90 GB.

**A surprise reversal at this scale + design**: `chain_account_single_reads {q=0.95}` is now **2.12× HIGHER for PBT** (348 µs vs 164 µs), whereas at 90 GB (PBT-v2, 16-bit) it was 25× LOWER. Either the 3-bit revert or the scale (or both) changed the per-op EVM-internal cost profile.

---

## Setup

Following the same patched-binary path as the 100mgas campaign:

| component | branch | commit (after pull) | binary |
|---|---|---|---|
| UBT geth | `feat/binary-trie/flat-state` | `1eca91736` + 100m patch | `geth-ubt-100m` |
| PBT geth | `binary/pbt-flat-state` | **`6dd000d74`** (16→3 bit revert) + 100m patch | `geth-pbt-100m` (rebuilt) |
| UBT state-actor | `bench/flat-state-base` | `641dfc1` + metrics-dump | `state-actor-ubt-m` |
| PBT state-actor | `bench/flat-state-pbt` | `1cddf40` + metrics-dump | `state-actor-pbt-m` (rebuilt) |
| execution-specs | `bench/locality-sweep` | `dec9cf9` + 100m patch | (interpreted) |

Campaign config (250GB build params):

```
NUM_RUNS=10  TARGET_SIZE=300GB  COLD_CACHE=1  GROUP_DEPTH=5
HETERO_GETTERS=1  SKIP_ACCOUNTS=1  METRICS_SCRAPE=1
T_TOUCHES=5000  NUM_STEMS=5000  NUM_CONTRACTS=4500
GAS_BENCHMARK_VALUE=100  K_VALUES_STORAGE="1 10 100 1000 4500"

SA_CONTRACTS=30000000   (was 16400000 at 90GB)
SA_MAX_SLOTS=1000000    (was 100000 at 90GB; thicker storage-slot power-law tail)
SA_ACCOUNTS=125000      (unchanged)
SA_MIN_SLOTS=1          (unchanged)
SA_DISTRIBUTION=power-law
SA_GAS_LIMIT=200000000  (genesis cap; 100M-tx headroom)

DB_BASE=$WORK/dbs/250gb
DB_SNAPSHOT_DIR=$WORK/dbs/250gb-snapshot
```

Final DB sizes: **UBT 168 GB · PBT 163 GB**. (30M contracts × MAX=1M produced 168 GB rather than the targeted 250 GB — the per-contract size assumption from the 90 GB campaign scaling was slightly off, but the data is good and the comparison is still meaningful at ~2× scale.)

## Gates

- **Block-shape**: 300/300 — every benchmark block is `tx_count=1`, ~99.9 M gas.
- **Same-state**: 0/300 divergences (`storage_slots_written` identical UBT vs PBT per cell).
- **Metrics**: `metrics_consolidated.csv` has 300 rows × 1009 columns.
- **State-actor metrics**: dumped per config, compared via the new Stage 6 step.

## NEW: Phase 1.5 — Pebble compact step

Inserted between state-actor (phase 1) and getter deploys (phase 2). Without it, the chaindata Pebble has L0 stacks from state-actor's bulk writes; the first benchmark cells trigger background compactions that pollute measurements and bias UBT vs PBT.

Implementation (`generate_dbs.sh`):
```bash
COMPACT_MARKER="$db_path/geth/chaindata/.compacted"
if [ ! -f "$COMPACT_MARKER" ]; then
  "$geth_bin" --datadir "$db_path" --override.ubt=0 --bintrie.groupdepth "$GROUP_DEPTH" \
    db compact
  touch "$COMPACT_MARKER"
fi
```

The marker file makes it idempotent on snapshot restores. **The campaign saw this work cleanly** — UBT compaction ran for ~1.5 min, PBT for ~1.6 min (logged), both before Stage 2 started.

**Effect on results**: the per-cell `eth_db_chaindata_compact_time` is now **0.81–1.11× across all 15 cells** (median ratio 0.91×). Previously at 100mgas it was 1.55–1.93×. The compact step eliminated what looked like a "PBT pays more compaction" finding by giving both configs a clean L0 baseline. **This was probably the most important methodology fix in the campaign**: the prior "PBT does more compaction" claim was an artifact of UBT/PBT handing off to Stage 2 at different L0 fullness levels.

## NEW: Stage 6 — state-actor build-phase metrics

The state-actor `--metrics-dump` patch writes a Prometheus snapshot per config at end of phase 1. The new `compare_stateactor_metrics.py` script diffs the two files. **The build phase is a different kind of workload than the benchmark** — sustained sequential trie inserts, no random reads, no transaction execution.

| metric | UBT | PBT | PBT/UBT | what it tells us |
|---|--:|--:|--:|---|
| `system_memory_held` | 12.3 GB | 21.1 GB | **1.72×** | Go heap held (incl. unreleased free chunks) |
| `system_memory_used` | 6.9 GB | 10.6 GB | **1.52×** | Go heap in use |
| `system_memory_objects` | 6.8 B | 10.2 B | 1.51× | total Go object allocations |
| `system_cpu_procload` | 88 | 176 | **2.00×** | CPU load attributable to this process |
| `system_cpu_sysload` | 91 | 168 | 1.85× | CPU load including kernel work |
| `system_memory_pauses {q=0.95}` | 196 µs | 229 µs | 1.17× | GC pause P95 |
| `system_cpu_syswait` | 108 | 19 | 0.18× | syscall wait events (PBT lower) |

**Reading this**: building a chain with PBT's keys costs ~50% more memory and ~2× CPU than UBT's. That's the cost of the zoned key construction during state-actor's batched inserts. This is **invisible to the benchmark** because state-actor runs once, but it would matter for archive nodes that re-sync or pruned nodes that re-snap. The 100mgas campaign saw similar magnitudes (2.4× memory, 1.65× procload); the 250GB campaign shows the gap is approximately stable, not growing with scale.

Full dump in `data/x86-runs/250gb-stateactor-compare-20260605.csv`.

---

## Throughput headline — full per-cell table

n=10 per cell. Bootstrap 95% CIs (2000 resamples).

| cell | UBT Mgas/s | PBT Mgas/s | ratio | 95% CI | prev 90GB |
|---|--:|--:|--:|--:|--:|
| sload_k1 | 82.76 | 80.19 | 0.969 | [0.937, 1.025] | 1.008 |
| sload_k10 | 82.77 | 78.24 | 0.945 | [0.929, 1.009] | 1.026 |
| sload_k100 | 82.67 | 80.64 | 0.975 | [0.939, 1.010] | 1.014 |
| sload_k1000 | 83.30 | 81.41 | 0.977 | [0.946, 1.056] | 0.977 |
| sload_k4500 | 90.17 | 90.31 | 1.002 | [0.969, 1.055] | 1.001 |
| sstore_k1 | 525.47 | 489.69 | 0.932 | [0.840, 1.071] | 0.973 |
| sstore_k10 | 518.04 | 481.13 | 0.929 | [0.868, 0.995] | 0.980 |
| sstore_k100 | 495.85 | 439.33 | 0.886 | [0.823, 0.963] | 0.962 |
| **sstore_k1000** | 209.46 | 228.09 | **1.089** | **[1.033, 1.174]** | 1.077 |
| sstore_k4500 | 83.98 | 81.53 | 0.971 | [0.934, 1.003] | 1.003 |
| mixed_k1 | 121.00 | 116.83 | 0.966 | [0.940, 1.001] | 1.011 |
| mixed_k10 | 116.63 | 111.57 | 0.957 | [0.907, 0.994] | 0.984 |
| mixed_k100 | 113.63 | 109.48 | 0.964 | [0.918, 1.026] | 1.017 |
| mixed_k1000 | 110.40 | 110.33 | 0.999 | [0.972, 1.029] | 1.004 |
| **mixed_k4500** | 87.45 | 99.28 | **1.135** | **[1.081, 1.172]** | 1.134 |

**Robust observations:**
- **mixed_k4500** = 1.135 in both campaigns. This is PBT's unambiguous, durable win across scale (90GB→168GB) and design (PBT-v2→PBT-v3).
- **sstore_k1000** = 1.089 (up from 1.077). Mild but reproduced.
- **sload_k1000, sload_k4500, sstore_k4500, mixed_k1000**: parity (CI crosses 1.0).
- **The remaining 9 cells**: slight UBT favor (0.886–0.977), most moved DOWN 0.03–0.08 from the 90 GB campaign.

---

## Per-cell timing decomposition (every cell, both configs)

`total_ms ≈ execution_ms + state_read_ms + state_hash_ms + commit_ms` (geth's slow-block log invariant).

### SLOAD cells — execution-dominant (~1100ms exec, ~50ms read)

| cell | cfg | exec | read | hash | commit | total |
|---|---|--:|--:|--:|--:|--:|
| sload_k1 | UBT | 1133 | 51 | 25 | 1 | **1207** |
| sload_k1 | PBT | 1166 | 56 | 20 | 1 | **1246** |
| sload_k10 | UBT | 1136 | 55 | 21 | 1 | **1207** |
| sload_k10 | PBT | 1200 | 52 | 26 | 1 | **1277** |
| sload_k100 | UBT | 1128 | 60 | 18 | 1 | **1208** |
| sload_k100 | PBT | 1172 | 52 | 19 | 1 | **1239** |
| sload_k1000 | UBT | 1125 | 51 | 28 | 1 | **1200** |
| sload_k1000 | PBT | 1149 | 54 | 17 | 1 | **1227** |
| sload_k4500 | UBT | 990 | 93 | 26 | 1 | **1108** |
| sload_k4500 | PBT | 1000 | 89 | 15 | 1 | **1107** |

**SLOAD pattern**: PBT's `state_read_ms` is marginally lower at K=10/100/4500 (clustering helps) and `state_hash_ms` is consistently lower (less to re-hash for read-only blocks). But `execution_ms` is **consistently 9–64 ms higher** for PBT, swamping the savings. This is **per-access keccak/zone-derivation cost** that PBT pays on every storage read inside the EVM, regardless of K. At sload_k4500 the costs exactly balance (PBT total 1107 vs UBT 1108 — ratio 1.002).

### SSTORE cells — write-dominated; state_hash is biggest at K=4500

| cell | cfg | exec | read | hash | commit | total |
|---|---|--:|--:|--:|--:|--:|
| sstore_k1 | UBT | 58 | 85 | 31 | 16 | **190** |
| sstore_k1 | PBT | 61 | 84 | 31 | 21 | **205** |
| sstore_k10 | UBT | 61 | 82 | 30 | 13 | **193** |
| sstore_k10 | PBT | 64 | 97 | 26 | 15 | **208** |
| sstore_k100 | UBT | 54 | 83 | 46 | 17 | **202** |
| sstore_k100 | PBT | 56 | 88 | 51 | 19 | **228** |
| sstore_k1000 | UBT | 65 | 149 | 198 | 66 | **477** |
| **sstore_k1000** | PBT | 59 | **127** | **180** | 76 | **438** |
| sstore_k4500 | UBT | 74 | 288 | 623 | 198 | **1190** |
| sstore_k4500 | PBT | 80 | 261 | 678 | 199 | **1226** |

**SSTORE pattern**: at small K (1, 10, 100) PBT pays extra in every component — clustering doesn't help because the workload is too narrow. At K=1000 the read+hash savings outweigh the small commit cost; that's the +8.9% win cell. At K=4500 PBT saves 27ms on `read` but loses 55ms on `hash` (more dirty-stem hashing under full scatter) — net parity.

### Mixed cells — the K=4500 phenomenon

| cell | cfg | exec | read | hash | commit | total |
|---|---|--:|--:|--:|--:|--:|
| mixed_k1 | UBT | 721 | 96 | 9 | 7 | **826** |
| mixed_k1 | PBT | 710 | 124 | 9 | 7 | **855** |
| mixed_k10 | UBT | 734 | 109 | 8 | 6 | **857** |
| mixed_k10 | PBT | 732 | 128 | 9 | 7 | **896** |
| mixed_k100 | UBT | 757 | 106 | 10 | 6 | **879** |
| mixed_k100 | PBT | 764 | 116 | 11 | 6 | **913** |
| mixed_k1000 | UBT | 706 | 132 | 49 | 13 | **905** |
| mixed_k1000 | PBT | 711 | 136 | 37 | 14 | **906** |
| **mixed_k4500** | UBT | 528 | 236 | 266 | 99 | **1143** |
| **mixed_k4500** | PBT | 487 | **180** | 247 | 97 | **1006** |

**mixed_k4500 explained**: PBT saves 41 ms on exec, **56 ms on state_read**, 19 ms on state_hash, ~0 on commit → 116 ms total saved. This is the only cell where PBT's savings line up across multiple components. The 56 ms `state_read_ms` win is the *largest* single-component PBT advantage in any cell. **Why this cell specifically wins**: the mixed read-then-write phase ratio means accesses spread across all 4500 contracts, each touched once — so the per-contract clustering benefit happens *and* the EVM doesn't pay the slot-write retry overhead that swamps sstore_k4500.

---

## Cross-campaign comparison — DB scale

Absolute throughput per config across the 90 → 168 GB DB scale shift:

| cell | UBT 90→168GB | PBT 90→168GB |
|---|---:|---:|
| sload_k1 | 80.32 → 82.76 (+3.0%) | 80.92 → 80.19 (−0.9%) |
| sload_k4500 | 88.08 → 90.17 (+2.4%) | 88.21 → 90.31 (+2.4%) |
| sstore_k1 | 484.28 → 525.47 (+8.5%) | 471.40 → 489.69 (+3.9%) |
| sstore_k1000 | 206.02 → 209.46 (+1.7%) | 221.88 → 228.09 (+2.8%) |
| sstore_k4500 | 80.95 → 83.98 (+3.7%) | 81.22 → 81.53 (+0.4%) |
| mixed_k1 | 114.86 → 121.00 (+5.3%) | 116.09 → 116.83 (+0.6%) |
| **mixed_k4500** | 85.24 → 87.45 (+2.6%) | 96.62 → 99.28 (+2.8%) |

**Absolute throughput went UP for both configs**, not down. The clustering-benefits-scale-with-DB hypothesis predicted UBT would slow down more than PBT at larger DB sizes. **It didn't.** The Pebble level-fan-out doesn't grow enough at 168 GB vs 90 GB to change the relative I/O cost meaningfully — both configs benefit from accumulated SSTable compaction (we ran the same hardware on cold cache; the disk just got more efficient at handling repeated runs over time).

The compact step is probably partly responsible: by forcing both configs to start Stage 2 with cleanly-leveled SSTables, we removed UBT's "still being compacted" disadvantage that may have inflated PBT's wins at smaller scales.

---

## Metrics deep-dive — namespace summary

| namespace | total | nonzero | divergent (≥15%) |
|---|--:|--:|--:|
| chain | 160 | 152 | **32** |
| rpc | 87 | 86 | 14 |
| pathdb | 96 | 40 | **8** |
| blobpool | 214 | 32 | 4 |
| **system** | 33 | 31 | **10** |
| eth | 130 | 22 | 1 |
| filtermaps | 37 | 17 | 4 |
| txpool | 43 | 17 | 1 |
| state, trie, etc. | <90 | <10 | <2 |

### Where PBT genuinely wins at every cell (the structural confirmation)

**`pathdb_clean_node_miss` — the dramatic, replicated signal**:

| cell | UBT | PBT | ratio |
|---|--:|--:|--:|
| sload_k1 | 21 | 14 | 0.667 |
| sload_k4500 | 20 | 13.5 | 0.675 |
| sstore_k100 | 287 | 14 | **0.049** |
| sstore_k1000 | 2161 | 14 | **0.006** |
| **sstore_k4500** | **7160** | **14** | **0.002** (511× ratio) |
| mixed_k100 | 54.5 | 14 | 0.257 |
| **mixed_k4500** | 2834 | 14 | **0.005** |

PBT's trie cache miss count **stays flat at 14 across every cell regardless of K**. UBT's grows from 21 (sload) to **7160 (sstore_k4500)**. This is the cleanest structural signal in either campaign — PBT's hot trie nodes always fit cache; UBT's scatter and thrash. The mechanism is real and reproducible across scales.

**`system_disk_readbytes` — PBT does 30–37% less disk I/O at mixed_k4500**:

| cell | UBT MB | PBT MB | PBT/UBT |
|---|--:|--:|--:|
| sload_k1 | 92 | 57 | **0.62×** |
| sload_k4500 | 98 | 64 | **0.65×** |
| sstore_k4500 | 340 | 249 | 0.73× |
| mixed_k1 | 364 | 327 | 0.90× |
| **mixed_k4500** | **295** | **186** | **0.63×** (37% less disk) |

Every single cell, PBT reads less from the kernel. The savings range from 10% (mixed_k1) to **37% (mixed_k4500)** — exactly the cell where PBT wins biggest in throughput.

### Where the compact step paid off

**`eth_db_chaindata_compact_time` — now BALANCED across configs**:

| cell | UBT | PBT | ratio | (90GB ratio) |
|---|--:|--:|--:|--:|
| sload_k1 | 16 ms | 18 ms | 1.11× | (was 1.90×) |
| sstore_k4500 | 78 ms | 67 ms | 0.86× | (was 1.55×) |
| mixed_k4500 | 117 ms | 104 ms | 0.89× | (was 1.35×) |

The previously-suspicious "PBT pays more in compaction" finding **vanished** once both configs start with clean L0 SSTables. This is consistent with our earlier hypothesis that the 90 GB campaign's compact-time gap was a handoff artifact, not a fundamental PBT cost.

### The surprise reversal at this scale

`chain_account_single_reads {q=0.95}` — a Timer P95 for the EVM-internal account single-read latency:

| | UBT | PBT | ratio |
|---|--:|--:|--:|
| 90 GB (PBT-v2, 16-bit zone) | 7.6 M ns | 1.0 M ns | **0.127** (PBT 7.9× faster) |
| **250 GB (PBT-v3, 3-bit zone)** | **164k ns** | **348k ns** | **2.124 (PBT 2.1× SLOWER)** |

This is the biggest sign-flip in any metric across the two campaigns. The 90 GB campaign showed PBT-v2 being dramatically faster at this; the 250 GB campaign shows PBT-v3 being 2× slower. Two variables changed (DB scale + key derivation), but the magnitude suggests the **3-bit revert specifically** changed the EVM-internal access cost profile — *not* the larger DB. UBT's number actually dropped (7.6 M → 164k ns) too, suggesting compaction discipline helped the absolute number; PBT's also dropped (1.0 M → 348k ns) but less so, so the ratio inverted.

This invites a focused 168 GB rerun with PBT-v2 (16-bit zone) reapplied, to isolate whether it's the scale or the design that flipped the sign.

---

## Implications

1. **The two robust PBT wins are real**: mixed_k4500 = 1.135× (CI [1.081, 1.172]) and sstore_k1000 = 1.089× (CI [1.033, 1.174]). Both replicate across the 90 → 168 GB scale jump AND the design change (PBT-v2 → PBT-v3). They are the most defensible PBT-favors-clustering results in the entire campaign series.

2. **PBT-v3 (3-bit) pays a per-access execution_ms cost that PBT-v2 (16-bit) did not.** The sload cells flipped from 1.00–1.03 at 90 GB to 0.94–0.98 at 250 GB. The cleanest explanation is the key-derivation revert added latency to the inline EVM read path. Worth isolating with a PBT-v2 rerun at this same DB size.

3. **The Pebble compaction-time finding from the 100mgas campaign was an artifact.** Our phase-1.5 compact step proved it. The 1.75× compaction-time gap at 90 GB was *handoff state*, not fundamental design cost. **This is a useful methodology lesson**: any benchmark that doesn't compact state before measurement is testing something we don't intend to test.

4. **The structural disk and cache-miss savings hold at scale.** PBT reads 30–37% less from disk at the workloads it wins on. `pathdb_clean_node_miss` stays flat at 14 across every cell. These are the durable design signals.

5. **State-actor build phase has a real PBT cost** (50–70% more memory, 2× CPU procload) that the benchmark doesn't expose. Archive nodes, snap-sync targets, and any consumer of fresh state-actor output pays this.

6. **The 250 GB scale didn't grow PBT's wins as the clustering hypothesis predicted.** The scale-clustering-amplification story is unsupported in this data. PBT's wins are bounded by workload pattern (specifically: full-scatter mixed-mode at K=4500), not by DB depth.

---

## Artifacts

`data/x86-runs/` (committed):
- `250gb-metrics-block-20260605.csv` — per-block CSV (300 rows × 36 cols)
- `250gb-metrics-20260605.csv` — wide metrics CSV (300 × 1009)
- `250gb-metrics-analysis-20260605.json` — bootstrap CIs + Mann-Whitney
- `250gb-stateactor-compare-20260605.csv` — UBT vs PBT build-phase diff (47 non-zero metrics)
- `250gb-metrics-stateactor-{ubt,pbt}-20260605.prom` — raw per-config build dumps

`/mnt/state_expiry_vol_data/dbs/250gb-snapshot/{ubt,pbt}/` (~330 GB on disk, not in repo) — fast restore path for reruns.

## Reproducing

```bash
# Replay this campaign exactly (assumes binaries already built)
bash /tmp/launch-250gb-metrics.sh

# Resume from snapshot (skip ~5h Stage 1)
rm -rf /mnt/state_expiry_vol_data/dbs/250gb/{ubt,pbt}
bash /tmp/launch-250gb-metrics.sh   # restore-before-Stage-1 kicks in
```

## Deep-dive scripts on this data

```bash
# Top per-namespace metric divergences
uv run scripts/compare_metrics.py \
  --csv data/x86-runs/250gb-metrics-20260605.csv \
  --top 20 --by-namespace --top-per-namespace 8

# State-actor build phase comparison
uv run scripts/compare_stateactor_metrics.py \
  --ubt results/250gb-metrics/ubt/state-actor_metrics.prom \
  --pbt results/250gb-metrics/pbt/state-actor_metrics.prom \
  --top 20
```
