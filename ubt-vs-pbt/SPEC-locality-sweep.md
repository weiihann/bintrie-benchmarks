# UBT vs PBT — Locality Sweep (Mechanism Characterization)

## Context

We've published two UBT-vs-PBT campaigns against the flat-state geth read path:

- **Concentrated** (one contract, sequential SLOAD/SSTORE): PBT 1.75× / 2.83× / 2.41×
  read/write/mixed.
- **Scattered** (each op on a different CREATE2-deployed getter): PBT 0.84× /
  1.43× / 1.05× — locality gone; reads actually slightly slower in PBT.

The two campaigns are **endpoints**: K=1 contract/block and K≈T contracts/block.
The picture in between is unmapped, so the report can't say what shape PBT's
advantage takes — only that the endpoints are very different.

This campaign **fills the curve**. One headline graph: PBT/UBT throughput ratio
vs K (contracts touched per block), three lines for read/write/mixed, log x.
Locality is the only knob; everything else held byte-identical across configs.

**Mechanism reminder (corrected from prior thinking):** PBT is still a *single
unified trie*; the prefix bytes (`zone ‖ H(addr)`) just cluster keys in the
keyspace so a contract's storage stems sit adjacent in Pebble. There is **no**
parallel-commit, **no** 3-root overhead. PBT's edge is *entirely* Pebble physical
locality. This means writes won in the prior campaigns for the same reason reads
did when concentrated — trie-node writes cluster better when stems cluster.

### What dimensions matter — and what we drop

| Axis | Why it matters | Spec decision |
|---|---|---|
| **Locality** (K = contracts/block) | The *only* mechanism that separates PBT from UBT | Primary axis — sweep 4 points {1, 10, 100, 256} |
| **R/W ratio** | Reads = flat-state lookups; writes = trie+commit. Different code paths, may have different locality slopes | Secondary axis — {SLOAD, SSTORE, mixed} |
| **Zone** (storage / basic-data) | PBT clusters every zone, not just storage | Account-zone *sidecar* (4 cells) confirms the effect generalizes |
| Code-chunk zone | Not exercised by any normal workload at scale | **Skip** |
| Warm cache | Both configs equal once cached | **Skip** |
| Multi-zone per tx | Doesn't probe a new mechanism (PBT is a single tree) | **Skip** |
| Power-law / realistic workloads | Mixes locality with reuse; muddies mechanism story | **Skip** — report references prior scattered campaign as the "realistic" anchor |

### Key parameters

| Var | Value | Notes |
|---|---|---|
| `T` (touches per block) | 256 | Aligned with stem geometry (one stem = 256 slots wide) |
| `K` (contracts/block sweep) | {1, 10, 100, 256} | Log-spaced; covers concentration to full scatter |
| `GAS_BENCHMARK_VALUE` | 6 | One ~6 M-gas tx per block |
| `--dev.gaslimit` | 20 000 000 | Caps to 1 tx/block (verified at GBV=16, same logic at GBV=6) |
| `--dev.period` | **1** | Geth seals immediately after tx submission; no need for 10 s wait |
| `GROUP_DEPTH` | 5 | Matches prior campaigns |
| `SA_CONTRACTS` | 12 800 000 | ~75 GB chaindata per config (calibrated previously) |
| Runs per cell | 20 | Mann–Whitney + bootstrap CIs need ≥ 10; 20 leaves headroom |
| Cold cache | between every run | `sudo sysctl vm.drop_caches=3` (NOPASSWD rule already in place) |

### Branch matrix (unchanged from previous campaign)

| Config | geth branch (worktree)                                      | state-actor branch (worktree)                          |
|--------|--------------------------------------------------------------|--------------------------------------------------------|
| ubt    | `feat/binary-trie/flat-state` (`go-ethereum-flat-state`)     | `bench/flat-state-base` (`state-actor-flat-state`)     |
| pbt    | `binary/pbt-flat-state` (`go-ethereum-pbt-flat-state`)       | `bench/flat-state-pbt` (`state-actor-pbt-flat-state`)  |

go.mod `replace` directives resolve to the sibling worktree paths automatically.
All four binaries already exist at `/tmp/bench-bins/{geth,state-actor}-{flat-state,pbt-flat-state}`.

---

## Design — 16 cells

### Storage zone (12 cells)

|                  | K=1 | K=10 | K=100 | K=256 |
|------------------|:---:|:----:|:-----:|:-----:|
| `storage_sload`  |  ✓  |  ✓   |   ✓   |   ✓   |
| `storage_sstore` |  ✓  |  ✓   |   ✓   |   ✓   |
| `storage_mixed`  |  ✓  |  ✓   |   ✓   |   ✓   |

**Mechanism (each cell, one benchmark run):**

1. Pre-deploy `K` getter contracts via spamoor `factorydeploytx` (CREATE2,
   deterministic). Getter constructor pre-populates **256 stems** by `SSTORE(256*i, 1)`
   for `i ∈ [0, 256)` — ~5.6 M gas; fits one deploy tx.
2. Attack contract receives calldata `[start_counter(32) ‖ K addresses(32 each)]`.
   For T=256, K ∈ {1, 10, 100, 256}, S = ⌈T/K⌉ ∈ {256, 26, 3, 1}. The first
   `T mod K` contracts get S stems; the rest get S−1. (For K ∈ {1, 256} the
   distribution is uniform.) The block always executes exactly T=256 stem
   touches; only their distribution across K contracts changes.
3. Loop iteration `i ∈ [0, T)`:
   - `target_idx = which contract owns touch i` (computed from the uneven
     distribution above)
   - `stem_idx = which stem within that contract` (0-indexed within target)
   - For SLOAD: `slot = stem_idx * 256` — hits pre-populated slot 0 of that stem
   - For SSTORE: `slot = start_counter + i` — fresh, cold-insert (per-run offset already in harness)
   - For mixed: alternate SLOAD/SSTORE based on `i & 1`; SLOAD uses pre-populated slot, SSTORE uses fresh slot
4. Block executes the full T=256 touches as one tx. Gas/time recorded in geth's slow-block log.

**Why stem-strided slot indices?** Multiple slots within the same stem share
one Pebble fetch (flat-state value = `bitmap(32) ‖ values` blob per stem). If
we used contiguous slot indices, K=1 would mostly measure in-stem reuse, not
disk locality. Stride 256 ensures each of the T touches is one Pebble fetch.

### Account zone sidecar (4 cells)

|                          | K=10 | K=256 |
|--------------------------|:----:|:-----:|
| `account_balance_read`   |  ✓   |   ✓   |
| `account_transfer`       |  ✓   |   ✓   |

- Address table holds K random EOAs sampled from state-actor-seeded accounts
  (existing in basic-data).
- `account_balance_read`: attack does `BALANCE(table[i % K])` per iter. K=10 → mostly
  warm reuse (only first 10 are cold). K=256 → every BALANCE on a distinct account →
  all cold. The K=10 vs K=256 delta isolates the account-zone clustering effect.
- `account_transfer`: attack does `CALL(table[i % K], value=1)` per iter. Same warm/cold
  structure; writes the recipient's balance.
- Block gas budget = 6 M (same as storage). Ops/block falls out of op cost
  (BALANCE ~2700 cold / 100 warm; CALL+value ~9000+); we don't fix T for the
  account cells, only K.

### Methodology guarantees (carried from prior campaign — no change)

1. **One tx per block.** `GAS_BENCHMARK_VALUE=6`, `--dev.gaslimit 20000000`,
   `miner_setGasLimit 0x1312D00`. Validate post-run: both configs produce
   byte-identical 1-tx blocks. No packing asymmetry — Mgas/s is apples-to-apples.
2. **Cold cache** between every run. `COLD_CACHE=1` triggers
   `sudo -n /usr/sbin/sysctl -w vm.drop_caches=3` between runs (NOPASSWD rule
   already configured).
3. **Same-state guarantee:**
   - Deterministic CREATE2 factory + identical getter initcode →
     byte-identical target addresses across configs (`diff data/{ubt,pbt}/contracts.json`).
   - Identical per-run `SCATTERED_WRITE_OFFSET` exported to both configs → identical
     write-slot sequences.
   - Identical address tables (state-actor `-seed 25519`) for account cells.
   - Post-run gate: aggregate `gas_per_slot` ratio ≈ 1.0 per benchmark per K.
4. **Stage 1 (DB-gen)**: state-actor seeded with `SA_CONTRACTS=12.8 M`,
   `SA_ACCOUNTS=125 k`, `SA_MIN_SLOTS=1`, `SA_MAX_SLOTS=100000`, `GROUP_DEPTH=5` →
   ~75 GB chaindata per config. Same as the prior published campaign.
5. **Stage 2 (benchmark)**: 20 runs per cell × 16 cells × 2 configs = 640
   invocations. Each invocation: drop caches → start geth → submit tx → wait
   for block → read slow-block log → kill geth.

---

## Runtime estimate

| Stage | Time |
|---|---|
| Stage 1 — DB build (×2) | ~2 h |
| Stage 2 — 640 runs × ~23 s | ~4 h |
| Stage 3 — extract CSVs + analyze | ~10 min |
| Stage 4 — regenerate graphs + report | ~30 min |
| **Total** | **~6.5–7 h** |

(Per-run wall time at `--dev.period 1` is ~23 s; cold-drop + geth startup
dominates. Down from ~30 s at period=10 in the prior campaign.)

---

## Implementation outline (what changes — to be planned in writing-plans phase)

**Existing reused files (mostly param plumbing):**

- `ubt-vs-pbt/scripts/run_campaign.sh` — top-level driver. Add `K_VALUES` env;
  iterate over (benchmark, K) pairs.
- `ubt-vs-pbt/scripts/generate_dbs.sh` — deploys 256 getter contracts. Bump
  pre-population from 1 stem → 256 stems in the getter initcode.
- `ubt-vs-pbt/scripts/run_benchmarks.sh` — per-cell runner. Add K to the
  exported env and to the test invocation; change `--dev.period 10` → `1`;
  change `GAS_BENCHMARK_VALUE` default 16 → 6.
- `ubt-vs-pbt/scripts/compute_create2_addresses.py` — unchanged (initcode hash
  recomputes deterministically when getter changes).
- `ubt-vs-pbt/scripts/analyze_data.py` — unchanged (runs on consolidated CSV).
- `ubt-vs-pbt/scripts/generate_graphs.py` — add "ratio-vs-K" curve graph
  (3 lines). Existing per-benchmark bar graphs can stay.

**execution-specs test files (new + edit):**

- Replace: `tests/benchmark/stateful/bloatnet/test_scattered_storage.py` with
  `test_locality_sweep.py` that parametrizes K. Old file deleted (the scattered
  K=T case is now `storage_sload_k256` etc.).
- The new getter initcode lives in `generate_dbs.sh`; we'll precompute it and
  reference its bytes from the test (or just trust the CREATE2 addresses computed
  by `compute_create2_addresses.py`).

**New cells (account sidecar):**

- New test: `test_account_locality.py` with `test_account_balance_read` and
  `test_account_transfer`. Both parametrized by K ∈ {10, 256}.
- Account-table source: sample K addresses from a state-actor-exported list
  (state-actor's account export, if present; otherwise reconstruct
  deterministically from `seed=25519`).

**Report regeneration:**

- Primary graph: `ratio_vs_K.svg` (3 storage curves; log K-axis).
- Secondary graph: `account_sidecar.svg` (4 bars: 2 ops × 2 K).
- `index.html` rewritten: scope is now "locality sweep" not "scattered access";
  prior endpoint numbers (concentrated and scattered campaigns) cited as the K=1
  and K=T verifications.

---

## Critical files

- `ubt-vs-pbt/scripts/run_campaign.sh:33-49` — env-var plumbing block
- `ubt-vs-pbt/scripts/run_benchmarks.sh` (whole file) — per-cell runner;
  needs K parameterization and `--dev.period 1`
- `ubt-vs-pbt/scripts/generate_dbs.sh` (Phase 2 getter deploy) — bump pre-population
- `ubt-vs-pbt/scripts/analyze_data.py` — verify it groups by `(benchmark, K)` correctly
- `ubt-vs-pbt/scripts/generate_graphs.py` — add ratio-vs-K graph generator
- `ubt-vs-pbt/index.html` — rewrite scope + headline
- `execution-specs/tests/benchmark/stateful/bloatnet/test_locality_sweep.py`
  (new, replaces `test_scattered_storage.py`)
- `execution-specs/tests/benchmark/stateful/bloatnet/test_account_locality.py`
  (new) — account sidecar cells
- `group-depth-benchmarks/scripts/extract_csv.py` — verify it tolerates the
  new benchmark names (`storage_sload_k1`, `storage_sload_k10`, …)

---

## Risks & responses

| Risk | Response |
|---|---|
| Getter constructor at 5.6 M gas runs into per-tx limits on spamoor's factorydeploytx | Test deploy of one getter ahead of campaign; if too large, drop S_max from 256 → 128 (T=128, K_max=128, GBV=3). |
| K=1 saturates measurement at a single Pebble region (cache-hit-skewed) | Cold-cache drop between runs eliminates carryover; verify per-cell first-block I/O via `iostat` if numbers look suspicious. |
| `--dev.period 1` mines empty blocks during cold-drop pause | Cold-drop is between runs (geth not running); period only ticks while geth is up. No effect. |
| Account-table sampling diverges between configs | Derive table from deterministic seed (25519) + sorted contract list; verify same hashes on UBT and PBT. |
| Same-state gate fails on any K cell | Investigate before trusting numbers; points to EVM-level divergence (deployer-nonce drift, RNG mismatch). |
| Pebble OOM at 75 GB (31 GB RAM) | Stage-2 already runs `--cache 0`; if needed drop `SA_CONTRACTS` for shorter DB and retest. |

---

## Verification (Stage 5)

- Per config: `state-actor.log` ends with `State Generation Complete` and a
  non-zero root; each `spamoor_c*.log` shows 100 % deploy success;
  `data/{ubt,pbt}/contracts.json` byte-identical via `diff`; every Stage-2 run
  `exit=0`, `missing_trie_node=0`, no early `SIGKILL`.
- **Same-state gate**: per (benchmark, K, run), sorted non-zero `gas_used`
  sequences UBT == PBT; aggregate `gas_per_slot` ratio ≈ 1.0000. Script:
  adapt `/mnt/state_expiry_vol_data/tmp/verify_same_state.py` to also group by K.
- **Block-shape gate**: per cell, `tx_count == 1` and `gas_used` within 1 % of
  6 M for both configs. Confirms 1-tx-per-block held.
- `analysis_results.json` exists with non-zero CV% (CV%=0 ⇒ N=1 smoke signature).

---

## Reporting (Stage 6)

- Headline graph: PBT/UBT ratio vs K (log axis), three storage curves overlaid.
  Shaded 95 % CI bands. Horizontal y=1 reference line.
- Account sidecar: 4-bar chart of ratios at K=10 and K=256, read vs transfer.
- `index.html`: rewrite scope as "locality sweep". Headline: "PBT's edge is
  purely Pebble locality; it crosses break-even at K≈<measured>; account zone
  shows the same shape." Cite prior concentrated (K=1) and scattered (K=T)
  campaigns as endpoint verifications.
- Top-level `README.md`: update UBT-vs-PBT blurb with the new ratio-vs-K finding.
- Commit and push to `origin/pbt` only after user reviews numbers.

---

## Definition of done

- `ubt-vs-pbt/data/{ubt,pbt}/` populated for all 16 cells × 20 runs.
- `ubt_vs_pbt_consolidated.csv`, `analysis_results.json` regenerated.
- `graphs/` + `graphs-light/` regenerated; new `ratio_vs_K.svg` exists.
- `ubt-vs-pbt/index.html` and top-level `README.md` updated with locality-sweep finding.
- Committed and pushed to `origin/pbt`.
- Same-state gate passes for all 16 cells.
- Block-shape gate (`tx_count=1`, gas/block ≈ 6 M) passes for both configs across all cells.
