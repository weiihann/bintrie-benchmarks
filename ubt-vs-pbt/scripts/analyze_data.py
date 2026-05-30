#!/usr/bin/env python3
"""
Statistical analysis of UBT vs PBT benchmark data.

Reads ubt_vs_pbt_consolidated.csv and outputs:
- Per-benchmark summary tables (blocks with gas > 500K, excluding run 1)
- Mann-Whitney U pairwise comparisons (UBT vs PBT)
- Bootstrap ratio confidence intervals
- Welch's t-test on per-run medians
- Single-tx-block analysis
- Cold tail analysis (cache miss escalation)
- EVM tax correlation (execution_ms vs state_read_ms)
- CV% per config per benchmark

Usage:
    python scripts/analyze_data.py [--data-dir ../data] [--output analysis_results.json]
"""

import argparse
import csv
import json
import math
import os
import random
import sys
from collections import defaultdict
from pathlib import Path
import statistics

try:
    from scipy.stats import mannwhitneyu, ttest_ind, pearsonr
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


CONFIGS = ["ubt", "pbt"]
BENCHMARKS = ["scattered_sload", "scattered_sstore", "scattered_mixed"]
SUMMARY_COLS = ["total_ms", "mgas_per_sec", "state_read_ms", "state_hash_ms",
                "commit_ms", "storage_cache_hit_rate"]
COMPARISON_METRICS = ["total_ms", "mgas_per_sec", "ms_per_slot_read",
                      "ms_per_slot_hash", "ms_per_cache_miss",
                      "ms_per_slot_total", "gas_per_slot"]

# Bootstrap parameters
BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_CI = 0.95
RANDOM_SEED = 42


def load_data(data_dir):
    """Load consolidated CSV into {config: {benchmark: [rows]}}."""
    csv_path = data_dir / "ubt_vs_pbt_consolidated.csv"
    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found")
        sys.exit(1)

    data = defaultdict(lambda: defaultdict(list))
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            config = row["config"]
            bench = row["benchmark"]
            gas = int(row["gas_used"])
            run = int(row["run"])
            # gas > 500K drops trivial blocks; SKIP_FIRST_RUN=1 mimics the
            # mpt-vs-bintrie hygiene of discarding the first cold-cache run
            # (default off so NUM_RUNS=1 smoke tests produce non-empty data).
            skip_first = bool(int(os.environ.get("SKIP_FIRST_RUN", "0")))
            if gas > 500_000 and (not skip_first or run > 1):
                data[config][bench].append(row)
    return data


def get_values(rows, col):
    """Extract float values for a column from rows."""
    return [float(r[col]) for r in rows]


def safe_div(a, b):
    """Safe division, returns None if b is zero."""
    if b == 0:
        return None
    return a / b


def median(vals):
    """Median of a list, returns 0 for empty list."""
    if not vals:
        return 0
    return statistics.median(vals)


def mean(vals):
    """Mean of a list, returns 0 for empty list."""
    if not vals:
        return 0
    return statistics.mean(vals)


def cv_percent(vals):
    """Coefficient of variation as a percentage."""
    if len(vals) < 2:
        return 0
    m = statistics.mean(vals)
    if m == 0:
        return 0
    return 100 * statistics.stdev(vals) / m


def significance_stars(p):
    """Return significance stars for a p-value."""
    if p < 0.001:
        return "***"
    if p < 0.01:
        return "**"
    if p < 0.05:
        return "*"
    return "ns"


def compute_derived_metrics(rows):
    """Add derived per-row metrics to each row dict (in place)."""
    for r in rows:
        slots_read = int(r["storage_slots_read"])
        state_read = float(r["state_read_ms"])
        state_hash = float(r["state_hash_ms"])
        cache_misses = int(r["storage_cache_misses"])

        total_ms = float(r["total_ms"])
        gas_used = float(r["gas_used"])

        r["ms_per_slot_read"] = state_read / slots_read if slots_read > 0 else None
        r["ms_per_slot_hash"] = state_hash / slots_read if slots_read > 0 else None
        r["ms_per_cache_miss"] = state_read / cache_misses if cache_misses > 0 else None
        r["ms_per_slot_total"] = total_ms / slots_read if slots_read > 0 else None
        r["gas_per_slot"] = gas_used / slots_read if slots_read > 0 else None


def get_derived_values(rows, col):
    """Extract derived metric values (skipping None)."""
    return [r[col] for r in rows if r.get(col) is not None]


def get_run_medians(rows, col):
    """Aggregate to per-run medians for a given column."""
    by_run = defaultdict(list)
    for r in rows:
        run = int(r["run"])
        if col in ("ms_per_slot_read", "ms_per_slot_hash", "ms_per_cache_miss",
                   "ms_per_slot_total", "gas_per_slot"):
            val = r.get(col)
            if val is not None:
                by_run[run].append(val)
        else:
            by_run[run].append(float(r[col]))
    return [statistics.median(vals) for vals in by_run.values() if vals]


def bootstrap_ratio_ci(vals_pbt, vals_ubt, n_resamples=BOOTSTRAP_RESAMPLES,
                        ci=BOOTSTRAP_CI, seed=RANDOM_SEED):
    """Compute median(PBT)/median(UBT) with bootstrap CI.

    Returns (ratio, ci_low, ci_high).
    """
    if not vals_pbt or not vals_ubt:
        return (None, None, None)

    observed_ratio = statistics.median(vals_pbt) / statistics.median(vals_ubt)

    if HAS_NUMPY:
        rng = np.random.RandomState(seed)
        bt_arr = np.array(vals_pbt)
        ubt_arr = np.array(vals_ubt)
        ratios = np.empty(n_resamples)
        for i in range(n_resamples):
            pbt_sample = bt_arr[rng.randint(0, len(bt_arr), size=len(bt_arr))]
            upbt_sample = ubt_arr[rng.randint(0, len(ubt_arr), size=len(ubt_arr))]
            upbt_med = np.median(upbt_sample)
            if upbt_med == 0:
                ratios[i] = np.nan
            else:
                ratios[i] = np.median(pbt_sample) / upbt_med
        ratios = ratios[~np.isnan(ratios)]
        alpha = (1 - ci) / 2
        ci_low = float(np.percentile(ratios, 100 * alpha))
        ci_high = float(np.percentile(ratios, 100 * (1 - alpha)))
    else:
        rng = random.Random(seed)
        ratios = []
        for _ in range(n_resamples):
            pbt_sample = rng.choices(vals_pbt, k=len(vals_pbt))
            upbt_sample = rng.choices(vals_ubt, k=len(vals_ubt))
            upbt_med = statistics.median(upbt_sample)
            if upbt_med != 0:
                ratios.append(statistics.median(pbt_sample) / upbt_med)
        ratios.sort()
        alpha = (1 - ci) / 2
        ci_low = ratios[int(len(ratios) * alpha)]
        ci_high = ratios[int(len(ratios) * (1 - alpha))]

    return (observed_ratio, ci_low, ci_high)


def print_separator(char="=", width=100):
    print(char * width)


def should_include_metric(bench, metric):
    """Determine whether a metric applies to a given benchmark."""
    # ms_per_slot_hash only for approve/mixed (write benchmarks)
    if metric == "ms_per_slot_hash" and bench == "scattered_sload":
        return False
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Analyze UBT vs PBT benchmark data")
    parser.add_argument("--data-dir", default="../data",
                        help="Directory with CSV files")
    parser.add_argument("--output", default="analysis_results.json",
                        help="JSON output file")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    data = load_data(data_dir)

    if not data:
        print("ERROR: No data loaded.")
        sys.exit(1)

    # Compute derived metrics for all rows
    for config in CONFIGS:
        for bench in BENCHMARKS:
            compute_derived_metrics(data[config][bench])

    results = {}

    # =========================================================================
    # 1. Per-benchmark summary table
    # =========================================================================
    print_separator()
    print("  PER-BENCHMARK SUMMARY (blocks with gas > 500K, excluding run 1)")
    print_separator()

    results["summary"] = {}

    for bench in BENCHMARKS:
        print(f"\n--- {bench} ---")
        header = f"{'Config':>10} {'Blocks':>7}"
        for col in SUMMARY_COLS:
            header += f" {col:>20}"
        print(header)
        print("-" * len(header))

        results["summary"][bench] = {}
        for config in CONFIGS:
            rows = data[config].get(bench, [])
            if not rows:
                print(f"{config:>10} {'--':>7}"
                      + "".join(f" {'--':>20}" for _ in SUMMARY_COLS))
                continue
            n_blocks = len(rows)
            line = f"{config:>10} {n_blocks:>7}"
            entry = {"n_blocks": n_blocks}
            for col in SUMMARY_COLS:
                vals = get_values(rows, col)
                med = median(vals)
                line += f" {med:>20.2f}"
                entry[f"median_{col}"] = round(med, 4)
            print(line)
            results["summary"][bench][config] = entry

    # =========================================================================
    # 2. Mann-Whitney U pairwise comparisons
    # =========================================================================
    print()
    print_separator()
    print("  MANN-WHITNEY U: UBT vs PBT")
    print_separator()

    results["mann_whitney"] = {}

    if HAS_SCIPY:
        for bench in BENCHMARKS:
            print(f"\n--- {bench} ---")
            results["mann_whitney"][bench] = {}
            rows_ubt = data["ubt"].get(bench, [])
            rows_pbt = data["pbt"].get(bench, [])
            if not rows_ubt or not rows_pbt:
                print("  Insufficient data")
                continue

            for metric in COMPARISON_METRICS:
                if not should_include_metric(bench, metric):
                    continue

                if metric in ("ms_per_slot_read", "ms_per_slot_hash",
                              "ms_per_cache_miss"):
                    vals_ubt = get_derived_values(rows_ubt, metric)
                    vals_pbt = get_derived_values(rows_pbt, metric)
                else:
                    vals_ubt = get_values(rows_ubt, metric)
                    vals_pbt = get_values(rows_pbt, metric)

                if not vals_ubt or not vals_pbt:
                    print(f"  {metric}: insufficient data")
                    continue

                stat, p = mannwhitneyu(vals_ubt, vals_pbt,
                                       alternative="two-sided")
                med_ubt = median(vals_ubt)
                med_pbt = median(vals_pbt)
                sig = significance_stars(p)
                print(f"  {metric:>22}: UBT {med_ubt:>10.2f}  PBT {med_pbt:>10.2f}"
                      f"  U={stat:.0f}  p={p:.2e} {sig}")
                results["mann_whitney"][bench][metric] = {
                    "U": round(stat, 2),
                    "p_value": float(f"{p:.6e}"),
                    "median_ubt": round(med_ubt, 4),
                    "median_pbt": round(med_pbt, 4),
                    "significant": sig != "ns",
                }
    else:
        print("\n  scipy not available -- skipping Mann-Whitney U tests")
        print("  Install with: pip install scipy")

    # =========================================================================
    # 3. Bootstrap ratio CIs
    # =========================================================================
    print()
    print_separator()
    print("  BOOTSTRAP RATIO CIs: median(PBT) / median(UBT), 95% CI")
    print_separator()

    results["bootstrap_ratios"] = {}

    for bench in BENCHMARKS:
        print(f"\n--- {bench} ---")
        results["bootstrap_ratios"][bench] = {}
        rows_ubt = data["ubt"].get(bench, [])
        rows_pbt = data["pbt"].get(bench, [])
        if not rows_ubt or not rows_pbt:
            print("  Insufficient data")
            continue

        for metric in COMPARISON_METRICS:
            if not should_include_metric(bench, metric):
                continue

            if metric in ("ms_per_slot_read", "ms_per_slot_hash",
                          "ms_per_cache_miss"):
                vals_ubt = get_derived_values(rows_ubt, metric)
                vals_pbt = get_derived_values(rows_pbt, metric)
            else:
                vals_ubt = get_values(rows_ubt, metric)
                vals_pbt = get_values(rows_pbt, metric)

            ratio, ci_lo, ci_hi = bootstrap_ratio_ci(vals_pbt, vals_ubt)
            if ratio is None:
                print(f"  {metric:>22}: insufficient data")
                continue
            print(f"  {metric:>22}: ratio={ratio:.4f}  "
                  f"95% CI [{ci_lo:.4f}, {ci_hi:.4f}]")
            results["bootstrap_ratios"][bench][metric] = {
                "ratio": round(ratio, 6),
                "ci_low": round(ci_lo, 6),
                "ci_high": round(ci_hi, 6),
            }

    # =========================================================================
    # 4. Welch's t-test on per-run medians
    # =========================================================================
    print()
    print_separator()
    print("  WELCH'S t-TEST ON PER-RUN MEDIANS")
    print_separator()

    results["welch_t"] = {}

    if HAS_SCIPY:
        for bench in BENCHMARKS:
            print(f"\n--- {bench} ---")
            results["welch_t"][bench] = {}
            rows_ubt = data["ubt"].get(bench, [])
            rows_pbt = data["pbt"].get(bench, [])
            if not rows_ubt or not rows_pbt:
                print("  Insufficient data")
                continue

            for metric in COMPARISON_METRICS:
                if not should_include_metric(bench, metric):
                    continue

                run_meds_ubt = get_run_medians(rows_ubt, metric)
                run_meds_pbt = get_run_medians(rows_pbt, metric)

                if len(run_meds_ubt) < 2 or len(run_meds_pbt) < 2:
                    print(f"  {metric:>22}: insufficient runs "
                          f"(UBT={len(run_meds_ubt)}, PBT={len(run_meds_pbt)})")
                    continue

                t_stat, p = ttest_ind(run_meds_ubt, run_meds_pbt,
                                      equal_var=False)
                sig = significance_stars(p)
                print(f"  {metric:>22}: t={t_stat:>8.3f}  p={p:.2e} {sig}"
                      f"  (n_ubt={len(run_meds_ubt)}, n_pbt={len(run_meds_pbt)})")
                results["welch_t"][bench][metric] = {
                    "t_statistic": round(float(t_stat), 4),
                    "p_value": float(f"{p:.6e}"),
                    "n_ubt": len(run_meds_ubt),
                    "n_pbt": len(run_meds_pbt),
                    "significant": sig != "ns",
                }
    else:
        print("\n  scipy not available -- skipping Welch's t-test")

    # =========================================================================
    # 5. Single-tx-block analysis
    # =========================================================================
    print()
    print_separator()
    print("  SINGLE-TX-BLOCK ANALYSIS (tx_count == 1)")
    print_separator()

    results["single_tx"] = {}

    for bench in BENCHMARKS:
        print(f"\n--- {bench} ---")
        results["single_tx"][bench] = {}

        header = f"{'Config':>10} {'Blocks':>7}"
        for col in SUMMARY_COLS:
            header += f" {col:>20}"
        print(header)
        print("-" * len(header))

        for config in CONFIGS:
            rows = data[config].get(bench, [])
            single_tx = [r for r in rows if int(r["tx_count"]) == 1]
            if not single_tx:
                print(f"{config:>10} {'--':>7}"
                      + "".join(f" {'--':>20}" for _ in SUMMARY_COLS))
                continue
            n = len(single_tx)
            line = f"{config:>10} {n:>7}"
            entry = {"n_blocks": n}
            for col in SUMMARY_COLS:
                vals = get_values(single_tx, col)
                med = median(vals)
                line += f" {med:>20.2f}"
                entry[f"median_{col}"] = round(med, 4)
            print(line)
            results["single_tx"][bench][config] = entry

    # =========================================================================
    # 6. Cold tail analysis (PBT approve, cache miss escalation)
    # =========================================================================
    print()
    print_separator()
    print("  COLD TAIL ANALYSIS: PBT scattered_sstore -- ms_per_cache_miss by tx_count")
    print_separator()

    results["cold_tail"] = {}

    rows_pbt_approve = data["pbt"].get("scattered_sstore", [])
    if rows_pbt_approve:
        by_txcount = defaultdict(list)
        for r in rows_pbt_approve:
            tx_count = int(r["tx_count"])
            val = r.get("ms_per_cache_miss")
            if val is not None:
                by_txcount[tx_count].append(val)

        print(f"{'tx_count':>10} {'n_blocks':>10} {'median_ms/miss':>16} {'mean_ms/miss':>16}")
        print("-" * 52)
        for tc in sorted(by_txcount.keys()):
            vals = by_txcount[tc]
            med = median(vals)
            avg = mean(vals)
            print(f"{tc:>10} {len(vals):>10} {med:>16.4f} {avg:>16.4f}")
            results["cold_tail"][str(tc)] = {
                "n_blocks": len(vals),
                "median_ms_per_cache_miss": round(med, 6),
                "mean_ms_per_cache_miss": round(avg, 6),
            }
    else:
        print("  No PBT approve data")

    # =========================================================================
    # 7. EVM tax correlation (execution_ms vs state_read_ms)
    # =========================================================================
    print()
    print_separator()
    print("  EVM TAX CORRELATION: Pearson r (execution_ms vs state_read_ms)")
    print_separator()

    results["evm_tax_correlation"] = {}

    if HAS_SCIPY:
        for config in CONFIGS:
            print(f"\n--- {config} ---")
            results["evm_tax_correlation"][config] = {}
            for bench in BENCHMARKS:
                rows = data[config].get(bench, [])
                if len(rows) < 3:
                    print(f"  {bench}: insufficient data")
                    continue
                exec_vals = get_values(rows, "execution_ms")
                read_vals = get_values(rows, "state_read_ms")
                r_val, p = pearsonr(exec_vals, read_vals)
                sig = significance_stars(p)
                print(f"  {bench:>25}: r={r_val:>7.4f}  p={p:.2e} {sig}"
                      f"  (n={len(rows)})")
                results["evm_tax_correlation"][config][bench] = {
                    "r": round(float(r_val), 6),
                    "p_value": float(f"{p:.6e}"),
                    "n": len(rows),
                    "significant": sig != "ns",
                }
    else:
        print("\n  scipy not available -- skipping Pearson correlation")

    # =========================================================================
    # 8. CV% per config per benchmark (total_ms, per-run medians)
    # =========================================================================
    print()
    print_separator()
    print("  COEFFICIENT OF VARIATION (CV%) -- total_ms (per-run medians)")
    print_separator()

    results["cv_percent"] = {}

    for bench in BENCHMARKS:
        print(f"\n--- {bench} ---")
        results["cv_percent"][bench] = {}
        for config in CONFIGS:
            rows = data[config].get(bench, [])
            if not rows:
                continue
            run_meds = get_run_medians(rows, "total_ms")
            cv = cv_percent(run_meds)
            print(f"  {config:>10}: CV = {cv:.1f}%  (n_runs={len(run_meds)})")
            results["cv_percent"][bench][config] = {
                "cv_percent": round(cv, 2),
                "n_runs": len(run_meds),
            }

    # =========================================================================
    # Write JSON summary
    # =========================================================================
    output_path = Path(args.output)
    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\n\nJSON summary written to {output_path}")


if __name__ == "__main__":
    main()
