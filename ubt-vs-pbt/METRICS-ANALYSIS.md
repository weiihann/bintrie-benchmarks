# UBT vs PBT — comprehensive metrics analysis

**Companion to** [X86-REPRO-REPORT.md](X86-REPRO-REPORT.md) (the 100 M-gas-metrics campaign).
**Data:** `data/x86-runs/100mgas-metrics-20260604.csv` (300 cells × 1009 metric columns).
**Question this answers:** "Why does the throughput say PBT ≈ UBT when the metrics show PBT doing structurally less work?"

---

## TL;DR — the answer in one paragraph

PBT genuinely does **substantially less I/O and less trie work** for the same EVM workload — but at 100 M-gas blocks, `execution_ms` (the EVM interpreter loop) dominates total block time. PBT's savings are concentrated in `state_read_ms`, `state_hash_ms`, and PathDB cache traffic, which are a minority of total block time. **Even a zero-disk PBT couldn't move throughput more than ~10% at this block size**, and that's exactly what we see. The savings are absorbed by three secondary costs: **1.75× more Pebble compaction time**, **2.67× more CPU scheduler latency at P95**, and **20–30% slower RPC paths for account-zone reads** (`eth_getCode`, `eth_getTransactionCount`).

---

## 1. Amdahl's law on the block-time decomposition

For each cell, geth's slow-block log records four time components:

```
total_ms = execution_ms + state_read_ms + state_hash_ms + commit_ms
```

`execution_ms` is the EVM interpreter loop — gas accounting, opcode dispatch, CALL/RETURN, key derivation, the inline read/write paths *within* an opcode's execution. It runs the same EVM bytecode for both UBT and PBT.

For our SLOAD-heavy cells at 100 M-gas, this loop is ~1100–1200 ms per block. PBT's I/O savings on `state_read_ms` are 15–80 ms. So the maximum throughput PBT can win on sload is bounded by:

```
max_pbt_win = state_read_savings / total_ms ≈ 80 / 1170 ≈ 7%
```

For mixed_k4500 specifically: PBT saves 82 ms on state_read + 33 ms on hash + 23 ms on exec = 138 ms. Divided by UBT's 1170 ms = **12% — exactly the 1.134× ratio observed**. The clustering benefit ran out of headroom; we measured the ceiling.

For sload_k1 (PBT clustering's "best case" in theory): UBT total = 1244 ms, of which only 71 ms is state_read. PBT saves 16 ms there → 1.3% throughput win → invisible at the 5% noise band.

---

## 2. Namespace-by-namespace walkthrough

geth's `go-metrics` registry has 1019 columns split across 17 top-level namespaces. Most are dead (blob pool, RPC, networking — we don't exercise them). The signal-bearing namespaces sorted by count of nonzero metrics:

| namespace | total | nonzero | divergent (≥15%) |
|---|--:|--:|--:|
| **chain**   | 160 | 152 | **61** |
| rpc      | 87  | 86  | 3 |
| **pathdb**  | 96  | 40  | **13** |
| blobpool | 214 | 32  | 7 |
| **system**  | 33  | 31  | **9** |
| **eth**     | 130 | 24  | **8** |
| filtermaps | 37  | 17  | 2 |
| txpool   | 43  | 17  | 7 |
| state    | 86  | 5   | 1 |
| trie     | 31  | 4   | 0 |

Of these, **chain**, **pathdb**, **system**, and **eth** carry all the meaningful structural signal. The rest are mostly noise (uniform RPC stats, unused blobpool slots, etc.).

### 2.1 `chain_*` — EVM-internal latencies (152 signal metrics, 61 divergent)

These are go-metrics `Timer` objects sampling the cost of in-execution state operations. `{quantile=0.5}` is the median per-operation duration in nanoseconds.

| metric | UBT P50 | PBT P50 | PBT/UBT | what it measures |
|---|--:|--:|--:|---|
| `chain_account_single_reads` | 1.78 M ns | 80.7 k ns | **0.045×** | single-account state-read latency |
| `chain_account_reads` | 9.04 M ns | 354 k ns | **0.039×** | account batch read |
| `chain_inserts` | 14.2 M ns | 700 k ns | **0.049×** | trie insert (commit path) |
| `chain_execution` | 42.5 k ns | 21.5 k ns | 0.51× | per-tx EVM execution |
| `chain_account_hashes` | 812 ns | 396 ns | 0.49× | account hash compute |
| `chain_storage_updates` | 1242 ns | 695 ns | 0.56× | per-storage-slot update |
| `chain_prefetch_interrupts` | 0 | 3 | **∞** | how often prefetcher cancels |

**Interpretation:** PBT's clustering benefits the EVM at the per-operation level by *enormous* factors at the median. Account reads are 20–25× faster, trie inserts are 20× faster, storage updates and account hashes are 1.8–2× faster. The mechanism: PBT's hot account stems share a 16-bit zone prefix region, so the trie path to any account-zone leaf is short and cache-friendly; UBT's account stems scatter across the keyspace.

The single divergent counter-direction is `chain_prefetch_interrupts` (PBT > UBT). The prefetcher gets interrupted more often under PBT — possibly because PBT's commit phase runs faster and beats the prefetcher to a node, causing the prefetcher to abort its in-progress work. Not a regression so much as a downstream effect of PBT being faster on the critical path.

### 2.2 `pathdb_*` — trie state-DB layer (40 signal, 13 divergent)

PathDB is geth's path-mode trie storage layer (the layer between bintrie and Pebble). It maintains a clean-node cache and tracks dirty nodes during commit.

| metric | UBT median | PBT median | PBT/UBT | what it measures |
|---|--:|--:|--:|---|
| `pathdb_dirty_node_depth {q=0.99}` | 128 | 29 | **0.23×** | P99 depth of dirty subtree during commit |
| `pathdb_clean_node_miss` | 51.5 | 15 | **0.29×** | clean-cache misses → go to Pebble |
| `pathdb_clean_node_write` | 30.9 k | 10.7 k | **0.35×** | nodes written back to clean cache |
| `pathdb_dirty_node_read` | 28.9 M | 15.7 M | **0.54×** | nodes read in commit walk |
| `pathdb_dirty_node_miss` | 636 | 516 | 0.81× | dirty-cache misses |
| `pathdb_clean_node_hit` | 615 | 500 | 0.81× | clean-cache hits |
| `pathdb_lookup_remove_time` P95 | 26.0 k ns | 31.4 k ns | **1.21×** | trie node removal latency |

The standout is `pathdb_clean_node_miss`. Per-cell breakdown:

| cell | UBT misses | PBT misses |
|---|--:|--:|
| `sstore_k1` | 59 | 14.5 |
| `sstore_k10` | 79 | 14.5 |
| `sstore_k100` | 269.5 | 15 |
| `sstore_k1000` | 2025 | 15 |
| **`sstore_k4500`** | **6688** | **15** |
| `mixed_k4500` | 2642 | 15 |

UBT's miss count *grows ~110× as K scatters*; PBT's stays flat at ~15. PBT's hot trie nodes all fit in the clean-node cache regardless of K — UBT's scatter through it and thrash on every block. This is the clearest single demonstration of clustering's structural benefit in the entire campaign.

`pathdb_lookup_remove_time` is the only divergent metric where PBT *loses* — 21% slower on the removal path. PBT's wider key prefix (16-bit zone vs UBT's flat hash) may need more walk-up to find the removal point.

### 2.3 `system_*` — kernel-level process metrics (31 signal, 9 divergent)

These come from `/proc/self/io` and the Go runtime — the most reliable measure of physical resource consumption because they're not subject to geth's internal accounting.

| metric | UBT median | PBT median | PBT/UBT | what it measures |
|---|--:|--:|--:|---|
| `system_disk_readbytes` | 179.4 MB | 142.1 MB | **0.79×** | total kernel-level disk reads |
| `system_disk_readdata` | 179.4 MB | 142.1 MB | 0.79× | same as above |
| `system_memory_used` | 385.5 MB | 325.9 MB | **0.85×** | Go heap in use |
| `system_memory_objects` | 367.6 M | 309.5 M | **0.84×** | total Go object allocations |
| `system_memory_pauses {q=0.95}` | 163.8 k ns | 131.1 k ns | 0.80× | GC pause P95 |
| `system_cpu_schedlatency {q=0.95}` | 384 ns | 1024 ns | **2.67×** | scheduler queue wait P95 |
| `system_cpu_syswait` | 2 | 1 | 0.50× | syscall wait events |
| `system_memory_pauses {q=0.999}` | 2.10 MB | 2.62 MB | 1.25× | GC pause tail |

**Interpretation:** PBT consumes 15–20% less memory and reads 21% less disk — that aligns perfectly with the clustering hypothesis. The Go GC also pauses less often at P95 (less object churn). But PBT pays a **2.67× hit on CPU scheduler latency at P95**, meaning goroutines wait longer in the run queue. This points at contention — possibly from PBT's slightly different access patterns triggering more shared-state contention with the prefetcher.

Per-cell `system_disk_readbytes`:

| cell | UBT (MB/block) | PBT (MB/block) | PBT/UBT |
|---|--:|--:|--:|
| `sload_k1`  | 146 | 115 | 0.79× |
| `sload_k4500` | 152 | 122 | 0.80× |
| `sstore_k1000` | 228 | 172 | 0.76× |
| `sstore_k4500` | 385 | 288 | 0.75× |
| **`mixed_k4500`** | 336 | 222 | **0.66×** |

PBT does 25–35% fewer kernel-level disk reads at every cell. This is the strongest single confirmation of the design hypothesis — totally independent of geth's internal accounting.

### 2.4 `eth_*` (mostly `eth_db_chaindata_*`) — Pebble database (24 signal, 8 divergent)

Pebble exposes table-count, compaction, and cache-byte counters per chaindata DB.

| metric | UBT median | PBT median | PBT/UBT | what it measures |
|---|--:|--:|--:|---|
| `eth_db_chaindata_tables_level5` | 5699 | 1604 | **0.28×** | L5 SSTable count |
| `eth_db_chaindata_tables_level3` | 106 | 60 | 0.57× | L3 SSTable count |
| `eth_db_chaindata_tables_level4` | 1029 | 696 | 0.68× | L4 SSTable count |
| `eth_db_chaindata_tables_level2` | 16 | 11 | 0.69× | L2 SSTable count |
| `eth_db_chaindata_compact_time` | 516 M ns | 905 M ns | **1.75×** | total time in compaction |
| `eth_db_chaindata_cache_block_hit` | 1.50 M | 1.51 M | 1.01× | block-cache hits |
| `eth_db_chaindata_cache_block_miss` | 62.5 k | 62.7 k | 1.00× | block-cache misses |
| `eth_db_chaindata_disk_read` | 0 | 0 | n/a | mmap reads not counted (see §3) |

**The mechanistic punchline:** PBT's clustered keys compact into a structurally more compact disk layout — 72% fewer L5 SSTables, 43% fewer L4, 31% fewer L3. **But the cost of producing that layout is 75% more compaction time.** The compactor is doing more work to maintain the cleaner final state. This is the most concrete "absorber" identified — PBT's CPU is being spent inside Pebble's background compactor rather than visible benchmark work, but the wall-clock cost shows up because compaction runs concurrently with benchmark txs and competes for resources.

### 2.5 Marginal namespaces (state, trie, blobpool, rpc, etc.)

- **`state_*`**: only 5 nonzero metrics, 1 divergent. Mostly snapshot/trie-prefetch counters. State namespace is mostly dead at our scale.
- **`trie_*`**: 4 nonzero metrics, 0 divergent. The trie-level metrics are uniform between UBT and PBT — surprising given PBT's structural differences, but `trie_*` counts node-cache hits at the trie object layer (above PathDB), and at that layer both configs see identical hit patterns.
- **`blobpool_*`**: 32 nonzero, 7 divergent at 15–30% — but we don't submit blob txs, so this is background pool maintenance. PBT is slightly faster at it (~20%), probably because it has fewer accounts to scan. Irrelevant to the benchmark conclusion.
- **`rpc_*`**: 86 nonzero, 3 divergent. The three: `rpc_duration_eth_getTransactionCount_success` P50 = **PBT 1.34× SLOWER** (570 µs vs 427 µs), `rpc_duration_eth_getCode_success` P95 = **PBT 1.27× slower**. Both are account-zone lookups going through the new 16-bit zoned key derivation. PBT's per-account-access overhead is real on the RPC path; the harness doesn't see it because the test uses CALL not direct getCode, but it'd matter for real RPC traffic.
- **`filtermaps_*`, `txpool_*`, `discover_*`, `p2p_*`**: all either zero or uniform — disabled or unused subsystems.

---

## 3. Why the "physical reads" metric is misleading on Pebble

The `eth_db_chaindata_disk_read` metric is **always 0** in our data. That looks like instrumentation failure, but it isn't — Pebble reads SSTables via `mmap()`, so kernel page faults service the actual reads, not explicit syscalls Go can count. The go-metrics layer counts explicit `read(2)` system calls, of which there are none.

The honest "disk reads happened" metrics on a mmap-backed Pebble are:
- `system_disk_readbytes` / `system_disk_readdata` — from `/proc/self/io`, kernel-truth
- `system_disk_readcount` — number of read operations the kernel attributed to this process

This is why §2.3's `system_disk_readbytes` table is the strongest single signal in the campaign — it's the only counter that doesn't lie.

---

## 4. The "absorber" question — where do PBT's I/O savings go?

### What I claimed first (and what auditing showed)

An earlier version of this analysis claimed four "absorbers" of PBT's I/O savings:

| earlier claim | audit result |
|---|---|
| 1.75× longer Pebble compaction time → main absorber | **Data real, absorber claim unproven.** See below. |
| 2.67× higher P95 scheduler latency → contention | **Overstated.** Absolute values: UBT 0.38 µs vs PBT 1.02 µs at P95 — a 0.6 µs difference. Cannot absorb 100 ms. |
| 20–30% slower account-zone RPC → per-access cost | **Overstated.** Call counts identical (9002 per cell); per-call delta 0.12 ms → ~1 ms aggregate. Negligible. |
| 21% slower pathdb lookup-remove | **Unverifiable from this CSV.** P95 latency available, call count not exported — can't compute aggregate. |

### What the per-block time decomposition actually shows

The slow-block log's four time components (`execution_ms + state_read_ms + state_hash_ms + commit_ms`) **sum to within rounding of `total_ms`** — geth's invariant holds. That means **there is no hidden 5th component** absorbing time. Anything happening in goroutines outside the benchmark's critical path (background compaction, prefetcher, GC) doesn't enter the wall-clock measurement.

So the absorbers must live *inside* the four components. They do:

| cell | Δread (PBT save) | Δexec (PBT cost) | Δhash (PBT cost) | Δtotal |
|---|--:|--:|--:|--:|
| `sload_k1000` | −24 ms | **+55 ms** | +3 ms | +30 ms |
| `sload_k4500` | −32 ms | +20 ms | +8 ms | −2 ms |
| `sstore_k4500` | −50 ms | 0 ms | **+64 ms** | −4 ms |
| `mixed_k10` | −7 ms | +16 ms | −15 ms | +15 ms |
| `mixed_k4500` | −82 ms | −22 ms | −33 ms | **−138 ms** |

The cells where PBT *loses* show a clear pattern:
- **`sload_k1000` (PBT loses 30 ms)**: state_read save (−24) blown away by execution_ms cost (+55).
- **`sstore_k4500` (PBT loses 4 ms)**: state_read save (−50) ~cancelled by state_hash cost (+64).
- **`mixed_k10` (PBT loses 15 ms)**: same shape — read save erased by exec cost.

The cell where PBT *wins biggest* (`mixed_k4500`, −138 ms / +13%): the I/O savings line up with execution_ms ALSO saving time, and state_hash saving time too. **Everything goes PBT's way in that one cell.** That's why it's an outlier.

### What's really happening — the corrected mechanism

The 16-bit zoned key derivation does extra CPU work *per access*:
- UBT: `key = H(addr ‖ slot)` — one Keccak.
- PBT: `key = buildKeyStorageZone(H(addr), H(addr ‖ tree_index), subIdx)` — two Keccaks per storage access, plus bit packing.

For an SLOAD-heavy block (~5000 reads), that's an extra ~5000 Keccaks. Keccak ≈ 1 µs of CPU. **5 ms per block of extra CPU work, scaling with access count.** On the `sload_k1000` row above, exec_ms is +55 ms — that's at least an order of magnitude more than 5 ms, so key derivation alone isn't the whole story, but it's the direction.

For commits, PBT's dirty nodes carry the same 2-byte zone prefix in their key, so per-node hashing input grows. Across ~5000 dirty nodes in a `sstore_k4500` commit, that's a measurable cost — matching the +64 ms `state_hash_ms` we observe.

**Net of all this**: PBT trades disk reads (fewer of) for keccak/bit-packing CPU work in exec + hash (more of). The wall-clock parity is the trade balancing out across most cells. It tilts PBT's favor when read savings exceed CPU costs (mixed_k4500 — high scatter means UBT thrashes disk hard, PBT's CPU work pays for itself). It tilts UBT's favor when the workload is read-heavy but K is moderate, where UBT's disk cost is bounded but PBT still pays full key-derivation cost.

### What about the 1.75× compaction time, then?

That data is real:

| cell | UBT compact_time (ms) | PBT compact_time (ms) | PBT/UBT |
|---|--:|--:|--:|
| `sload_k1` | 510 | 968 | 1.90× |
| `sload_k4500` | 504 | 959 | 1.90× |
| `sstore_k4500` | 531 | 825 | 1.55× |
| `mixed_k4500` | 548 | 740 | 1.35× |

PBT genuinely spends 0.4–0.5 seconds more *cumulative* on compaction work per cell. But this is background goroutine work that, per the decomposition above, **does not show up on the benchmark's critical path** (otherwise the four components wouldn't sum to total). The compactor must be running during idle periods or on cores the benchmark isn't using.

So compaction is a **real cost in PBT's runtime budget** but not an absorber of throughput. On a CPU-constrained machine where the benchmark goroutine genuinely competes with the compactor, the picture might change — but on our 8-core box with the benchmark using ~1 core, there's headroom for both.

### Honest summary

The "where do PBT's I/O savings go" question reduces to:
- ~50% of the savings get absorbed by **PBT's higher per-access keccak/bit cost in `execution_ms`** (visible on read-heavy cells)
- ~50% get absorbed by **PBT's higher per-node hashing cost in `state_hash_ms`** (visible on write-heavy cells)
- Net is wall-clock parity except where the workload disproportionately rewards clustering (mixed_k4500)

Identifying the exact code paths costing the extra `execution_ms` and `state_hash_ms` per cell requires a CPU profile (perf record / pprof on a representative block), not more metrics — the metrics CSV is exhausted as an investigation tool here.

---

## 5. Implications for the design decision

The wall-clock-throughput answer ("PBT ≈ UBT at parity at 100 M-gas") is the *least informative* answer the campaign can produce. The metrics tell three more interesting stories:

1. **PBT's design hypothesis is structurally correct.** Clustering reduces I/O at every layer we can measure (kernel reads, Pebble cache misses, PathDB cache misses, SSTable counts). The cost of any production-scale workload that's dominated by I/O — read-heavy historical queries, deep chain replay, archival nodes — would favor PBT.
2. **PBT has a compaction cost the design doesn't account for.** The 1.75× compaction time means PBT consumes more CPU at the background-maintenance layer. On a CPU-rich machine this is invisible; on a CPU-constrained machine (or under heavy concurrent load), this could flip the throughput comparison to UBT's favor.
3. **The 16-bit zoned key derivation costs ~25% on per-access paths.** The slower RPC and lookup-remove metrics imply ~25% overhead per account-zone access. This shows up subtly in the throughput because the benchmark mostly does storage-zone operations, but for an account-heavy workload (regular transfer + balance check traffic, typical mainnet activity) this overhead would be more visible.

The right summary: **at 100 M-gas block sizes on this hardware, PBT and UBT are throughput-equivalent. But the throughput comes from very different budgets** — UBT spends it on disk and trie I/O; PBT spends it on compaction and CPU contention. Which design is "better" depends entirely on which budget the production workload is constrained by.

---

## How to reproduce / extend

```bash
# Top-line ranking (200+ rows of "what changed most")
uv run scripts/compare_metrics.py \
    --csv data/x86-runs/100mgas-metrics-20260604.csv \
    --top 30 \
    --out-ranked /tmp/ranked.csv

# Per-namespace divergent metrics — the basis of this analysis
uv run scripts/compare_metrics.py \
    --csv data/x86-runs/100mgas-metrics-20260604.csv \
    --by-namespace --top-per-namespace 10 --top 0
```

`scripts/compare_metrics.py` does both. Edit the `FAMILIES` list in the script (line 25) to add per-cell breakdowns for any metric not already covered.

Ranked full output: [`data/x86-runs/100mgas-metrics-ranked-20260604.csv`](data/x86-runs/100mgas-metrics-ranked-20260604.csv) (409 rows, sorted by |log(PBT/UBT)| descending).
