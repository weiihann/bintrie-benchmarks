# Production campaign runbook

This is a self-contained guide for running the ubt-vs-pbt campaign on a dedicated bare-metal Linux machine, written for an AI agent picking up the task with no prior context. The local smoke-test has already passed end-to-end on a laptop at 1GB scale, so the pipeline itself is known-good; production differs only in scale, run count, and cold-cache discipline.

Read `README.md` first for what the campaign measures. Read this file second for how to execute it.

---

## 1. What you're running

Two trie configurations on the same EVM-level workload:

| Config | geth branch | state-actor branch | What it tests |
|---|---|---|---|
| `ubt` | `feat/binary-trie/bitarray` | `bench/bitarray-base` | Bitarray path encoding, single unified key derivation |
| `pbt` | `binary/pbt` | `bench/bitarray-pbt` | Bitarray + zone-partitioned keys + parallel zone commit |

The only variable under test is the trie. state-actor seed and spamoor seed are shared, so accounts/contracts/slots/transactions are byte-identical between configs.

---

## 2. Machine prerequisites

| Resource | Minimum |
|---|---|
| OS | Linux (the cold-cache step uses `sysctl vm.drop_caches=3`; macOS skips silently) |
| Disk (fast SSD) | ≥1.5TB free on the volume hosting `$DB_BASE`. Two ~400GB DBs + journals + bloat + room to breathe |
| RAM | ≥64GB. Pebble + geth's in-memory layer want headroom |
| CPU | ≥8 cores. PBT's parallel zone commit benefits from more |
| Go toolchain | ≥1.22 |
| `uv` | latest (`curl -LsSf https://astral.sh/uv/install.sh \| sh`) — execution-specs uses it |
| `sudo -n` | passwordless for `sysctl vm.drop_caches=3` only. Run `sudo -v` before the campaign, or add a NOPASSWD entry |

---

## 3. Build all binaries

Pick a working root (`$WORK`, e.g. `/opt`). All clones go there.

```bash
WORK=/opt
mkdir -p /tmp/bench-bins
cd $WORK

# go-ethereum — two binaries from two branches
git clone https://github.com/<your-fork>/go-ethereum.git
cd go-ethereum
git checkout feat/binary-trie/bitarray
make geth
cp build/bin/geth /tmp/bench-bins/geth-ubt
make clean
git checkout binary/pbt
make geth
cp build/bin/geth /tmp/bench-bins/geth-pbt

# state-actor — two binaries from two branches
cd $WORK
git clone https://github.com/<your-fork>/state-actor.git
cd state-actor
git checkout bench/bitarray-base
go build -o /tmp/bench-bins/state-actor-ubt .
git checkout bench/bitarray-pbt
go build -o /tmp/bench-bins/state-actor-pbt .

# spamoor — single binary
cd $WORK
git clone https://github.com/<your-fork>/spamoor.git
cd spamoor
make
cp bin/spamoor /tmp/bench-bins/spamoor

# execution-specs — pytest-driven benchmark harness (uv-managed)
cd $WORK
git clone https://github.com/ethereum/execution-specs.git
# Pin to a known-good revision. The smoke validated on HEAD as of 2026-05-13.
# Test names referenced: tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sload_erc20_generic
#                        tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sstore_erc20_generic
#                        tests/benchmark/stateful/bloatnet/test_multi_opcode.py::test_mixed_sload_sstore
# If those tests have been renamed again, update run_benchmarks.sh BENCH_TESTS accordingly.

# bintrie-benchmarks — this campaign directory
cd $WORK
git clone https://github.com/<your-fork>/bintrie-benchmarks.git
```

Verify every binary launches and reports the expected commit:

```bash
/tmp/bench-bins/geth-ubt version | grep "Git Commit"  # must be the HEAD of feat/binary-trie/bitarray
/tmp/bench-bins/geth-pbt version | grep "Git Commit"  # must be the HEAD of binary/pbt
/tmp/bench-bins/state-actor-ubt --help | head -3
/tmp/bench-bins/state-actor-pbt --help | head -3
/tmp/bench-bins/spamoor --help | head -3
```

---

## 4. Pick the workload scale

state-actor's `-target-size` flag is a **stop condition only** — it doesn't grow the workload past the built-in defaults (1000 accounts / 100 contracts / 1–10000 slots ≈ 1MB base). The smoke test got away with this because spamoor's bloat overlay did the heavy lifting; at 400GB you need state-actor to do most of the work.

The campaign exposes direct scaling flags as opt-in env vars:

| Env var | state-actor flag | Default |
|---|---|---|
| `SA_ACCOUNTS` | `-accounts` | 1000 |
| `SA_CONTRACTS` | `-contracts` | 100 |
| `SA_MIN_SLOTS` | `-min-slots` | 1 |
| `SA_MAX_SLOTS` | `-max-slots` | 10000 |
| `SA_DISTRIBUTION` | `-distribution` | `power-law` |

If unset, the corresponding flag is omitted and state-actor uses its default. For 400GB you'll want to set them.

**Calibration step (mandatory before the full run):**

Pick provisional values, do a 10GB run, measure the resulting DB size, and scale `SA_CONTRACTS` linearly to hit 400GB. Don't skip this — the relationship between `(accounts, contracts, max-slots)` and disk size depends on the distribution shape and Pebble's compression, so there's no analytic formula. PowerLaw (default) is the realistic distribution; `α=1.5` means a few contracts dominate, so `SA_MAX_SLOTS` matters a lot.

A typical starting point to refine:

```bash
SA_ACCOUNTS=1000000
SA_CONTRACTS=100000
SA_MIN_SLOTS=1
SA_MAX_SLOTS=100000
SA_DISTRIBUTION=power-law   # or omit; this is the default
```

Run a 10GB calibration:

```bash
cd $WORK/bintrie-benchmarks/ubt-vs-pbt
TARGET_SIZE=10GB \
SPAMOOR_TARGET_GB=0.1 \
NUM_RUNS=1 \
COLD_CACHE=0 \
SA_ACCOUNTS=1000000 SA_CONTRACTS=100000 SA_MIN_SLOTS=1 SA_MAX_SLOTS=100000 \
GETH_UBT_BIN=/tmp/bench-bins/geth-ubt \
GETH_PBT_BIN=/tmp/bench-bins/geth-pbt \
STATE_ACTOR_UBT_BIN=/tmp/bench-bins/state-actor-ubt \
STATE_ACTOR_PBT_BIN=/tmp/bench-bins/state-actor-pbt \
SPAMOOR_BIN=/tmp/bench-bins/spamoor \
EXEC_SPECS=$WORK/execution-specs \
DB_BASE=/data/ubt-vs-pbt-cal \
RESULTS_DIR=$(pwd)/data-cal \
bash scripts/run_campaign.sh
```

After it finishes, check `du -sh /data/ubt-vs-pbt-cal/{ubt,pbt}/geth/chaindata`. If you got `X GB`, scale `SA_CONTRACTS` by `400 / X` for the prod run. Keep `SA_ACCOUNTS`, `SA_MIN_SLOTS`, `SA_MAX_SLOTS` the same so the slot-size distribution stays comparable.

If the calibration DB sizes between ubt and pbt diverge by more than a few percent, that's a real finding (PBT's key derivation produces a different node distribution → different compression). Note it and report — it doesn't block the campaign.

---

## 5. The production command

```bash
cd $WORK/bintrie-benchmarks/ubt-vs-pbt

# Prime sudo so drop_caches works through the run without interactive prompts.
# If this errors, fix the sudoers file first — don't disable COLD_CACHE.
sudo -v

NUM_RUNS=10 \
TARGET_SIZE=400GB \
SPAMOOR_TARGET_GB=1 \
COLD_CACHE=1 \
GROUP_DEPTH=8 \
SA_ACCOUNTS=<tuned> \
SA_CONTRACTS=<tuned> \
SA_MIN_SLOTS=1 \
SA_MAX_SLOTS=100000 \
GETH_UBT_BIN=/tmp/bench-bins/geth-ubt \
GETH_PBT_BIN=/tmp/bench-bins/geth-pbt \
STATE_ACTOR_UBT_BIN=/tmp/bench-bins/state-actor-ubt \
STATE_ACTOR_PBT_BIN=/tmp/bench-bins/state-actor-pbt \
SPAMOOR_BIN=/tmp/bench-bins/spamoor \
EXEC_SPECS=$WORK/execution-specs \
DB_BASE=/data/ubt-vs-pbt-dbs \
RESULTS_DIR=$(pwd)/data \
bash scripts/run_campaign.sh 2>&1 | tee campaign-$(date +%Y%m%d-%H%M%S).log
```

Substitute the tuned `SA_ACCOUNTS` / `SA_CONTRACTS` from step 4 before running. `DB_BASE` must point at the fast SSD with ≥1.5TB free.

Run inside `screen` or `tmux` — total wall time is 12–24 hours depending on disk speed.

---

## 6. Budget

Order of magnitude, not commitment:

| Stage | Per config | × 2 configs |
|---|---|---|
| state-actor phase (400GB) | 1–3 hours | 2–6 hours |
| spamoor bloat (1GB overlay on 400GB) | 30–60 min | 1–2 hours |
| Benchmarks (3 benchmarks × 10 runs, cold cache, 400GB lookups) | 4–10 hours | 8–20 hours |
| CSV extraction + analysis | <5 min | <5 min |

Disk usage peak: each config's DB ~400GB + ~50–500GB journal during active commit + bloat overlay. Plan for 800GB–1.2TB peak, freed back down to ~800GB once journals flush.

---

## 7. Resumption and partial recovery

The scripts are idempotent at stage boundaries:

- **`generate_dbs.sh`** skips a config whose `stubs.json` already exists. To force a rebuild of one config, delete that config's `stubs.json` and its DB directory under `$DB_BASE`, then re-run.
- **`run_benchmarks.sh`** clears per-run logs at the start of each config. It overwrites; it doesn't append. If you interrupt mid-benchmark, the most recent run's logs may be partial — re-run that benchmark by re-invoking the script (cheap, only the benchmark stage repeats).
- **`run_campaign.sh`** runs all four stages in sequence. If stages 1–2 already produced clean output, you can skip them and run stages 3–4 manually:

```bash
# Stage 3 — extract CSVs from existing geth logs
for name in ubt pbt; do
  python3 ../group-depth-benchmarks/scripts/extract_csv.py "data/$name" \
    --config "$name" --trie-type "bintrie" --group-depth 8 --pebble-block-size-kb 4
done

# Stage 4 — consolidate + analyze
head -1 data/ubt/csv/ubt_all_benchmarks.csv > data/ubt_vs_pbt_consolidated.csv
tail -n +2 data/ubt/csv/ubt_all_benchmarks.csv >> data/ubt_vs_pbt_consolidated.csv
tail -n +2 data/pbt/csv/pbt_all_benchmarks.csv >> data/ubt_vs_pbt_consolidated.csv
python3 scripts/analyze_data.py --data-dir data --output data/analysis_results.json
```

---

## 8. What to verify after each stage

| After… | Check |
|---|---|
| state-actor phase (per config) | `$gen_log` ends with `=== State Generation Complete ===` and a state root. DB size matches expectation. |
| spamoor bloat (per config) | `$spamoor_log` ends with `progress: 100.00%`. `data/<config>/stubs.json` exists and contains a contract address. |
| Graceful geth shutdown | The campaign log shows `[geth] exited cleanly after Xs` (not `SIGKILL`). Critical: a SIGKILL'd geth leaves the PathDB journal incomplete and benchmarks will fail with `missing trie node`. |
| Per-benchmark run | Test log shows `exit=0 passed=1` (or `passed=5` for mixed_sload_sstore which has 5 parametrizations). Geth log has no `missing trie node` lines. |
| CSV extraction | Per-config CSV has ≥10 rows per benchmark per run, with non-zero `gas_used` and realistic `mgas_per_sec`. |
| Consolidation | `data/ubt_vs_pbt_consolidated.csv` row count = (sum of per-config CSV rows). `awk -F, 'NR>1 {print $1}' … \| sort \| uniq -c` shows roughly equal ubt/pbt counts. |
| Analysis | `data/analysis_results.json` exists. The text report shows Mann-Whitney U p-values, bootstrap ratio CIs, and CV% > 0 (CV% = 0 means N=1 — a smoke-test signature, not prod). |

---

## 9. Known failure modes and fixes

**`missing trie node …` in geth log during benchmark.**
The PathDB journal didn't flush before geth was killed. `kill_geth` in both `generate_dbs.sh` and `run_benchmarks.sh` polls for clean exit up to 120s; if your prod DB is huge, that may not be enough. Bump the `waited -lt 120` limit in both files to e.g. 600.

**`account already exists` (in geth stderr at startup).**
Harmless. `start_geth_*` runs `account import` idempotently before each launch — geth reports it once per restart. Ignore.

**`exit=5 passed=0` from pytest.**
Tests were collected but immediately deselected. Likely cause: execution-specs test names drifted again, or a marker filter (`-m stateful`) snuck back in. Check `data/<config>/<benchmark>_run1_test.log` for the `collected N items / N deselected` line. The current bloatnet tests have no markers; selection is purely by path.

**`address-stubs: invalid model_validate_json_or_file value`.**
The execution-specs `AddressStubs` schema changed. Current schema is `{"label": {"addr": "0x..."}}`. `generate_dbs.sh` writes this format. If execution-specs changes the schema again, update the `STUBS_EOF` heredoc in `generate_dbs.sh`.

**spamoor stalls partway through bloat.**
geth ran out of disk. Check `$DB_BASE` free space. Cleanup, retry.

**Cold-cache step fails: `sudo: a password is required`.**
Either run `sudo -v` immediately before the campaign (the sudo timestamp is good for ~15min by default; the campaign's per-run drop_caches calls refresh it) or add `NOPASSWD: /sbin/sysctl` to sudoers for the benchmark user.

---

## 10. Deliverables to hand back

Compress and return:

```
data/
├── ubt/
│   ├── csv/ubt_all_benchmarks.csv         # extracted per-block metrics
│   ├── csv/ubt_<benchmark>.csv            # per-benchmark splits
│   ├── stubs.json                         # contract address used
│   ├── state-actor.log                    # phase-1 build log
│   ├── geth_deploy.log                    # phase-2 ERC20 deploy
│   ├── spamoor.log                        # bloat log
│   └── <benchmark>_run<N>_{geth,test}.log # all 30 benchmark runs (3 × 10)
├── pbt/                                    # same shape
├── ubt_vs_pbt_consolidated.csv             # merged
├── analysis_results.json                   # final statistical comparison
└── campaign-<timestamp>.log                # full campaign stdout/stderr
```

That's the complete artifact set. The `analysis_results.json` is the deliverable for downstream reporting; everything else is for reproducibility and debugging.

---

## 11. Sanity check on results

Two correctness checks before drawing performance conclusions:

1. **Same-state**: in the consolidated CSV, for each `(benchmark, run, intra-run-block-index)` the `gas_used` should be byte-identical between ubt and pbt. Block numbers will differ by a small offset (chain head delta from idle `--dev` blocks before benchmarks start) but the gas sequence inside each run should match.

2. **No silent failures**: every benchmark run should have `gas_used > 0` on the second-and-later blocks within each run. If a config has all-zero blocks for an entire benchmark, the test was collected but ran no transactions — investigate before trusting the analysis.

If both pass, the numbers in `analysis_results.json` are the real comparison.
