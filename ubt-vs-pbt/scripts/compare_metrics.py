#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Compare UBT vs PBT metrics from a `metrics_consolidated.csv` produced by
`parse_metrics.py`.

Each row of `metrics_consolidated.csv` is one cell's (benchmark, k, run) end-of-cell
cumulative Prometheus snapshot from geth. Per-row counters ≈ per-block work because
each cell starts fresh geth on cold cache.

This script:
  1. Ranks metrics by |log(PBT_median / UBT_median)| across all rows. Surfaces
     the biggest structural differences regardless of which metric family they
     live in.
  2. Per-cell tables for a curated set of "interesting" metric families (Pebble
     SSTable layout, disk I/O, pathdb cache misses, EVM-level account/insert
     latencies). Lets you see how each ratio evolves across K.
  3. Optional --csv outputs the ranked table so it can be loaded into a
     spreadsheet for offline browsing.

Example:
  uv run ubt-vs-pbt/scripts/compare_metrics.py \\
    --csv ubt-vs-pbt/data/x86-runs/100mgas-metrics-20260604.csv \\
    --top 30
"""
from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path


# Curated metric families worth a per-cell breakdown. Order matters — the most
# mechanistically interesting families come first.
FAMILIES: list[tuple[str, str]] = [
    # Pebble disk layout — clustering's first-order effect
    ("Pebble L5 SSTable count",        "eth_db_chaindata_tables_level5"),
    ("Pebble L0 SSTable count",        "eth_db_chaindata_tables_level0"),
    ("Pebble compact_write bytes",     "eth_db_chaindata_compact_write"),
    ("Pebble cache block hits",        "eth_db_chaindata_cache_block_hit"),
    ("Pebble cache block misses",      "eth_db_chaindata_cache_block_miss"),
    # OS-level I/O (kernel /proc/self/io — the truth about disk activity)
    ("system disk read bytes",         "system_disk_readbytes"),
    ("system disk read count",         "system_disk_readcount"),
    ("system disk write bytes",        "system_disk_writebytes"),
    # PathDB / trie-state-DB layer
    ("pathdb dirty_node_read",         "pathdb_dirty_node_read"),
    ("pathdb dirty_node_write",        "pathdb_dirty_node_write"),
    ("pathdb clean_node_hit",          "pathdb_clean_node_hit"),
    ("pathdb clean_node_miss",         "pathdb_clean_node_miss"),
    ("pathdb dirty_node_depth P99",    "pathdb_dirty_node_depth {quantile=0.99}"),
    # EVM-execution-internal stats (ns; geth's go-metrics timer P50)
    ("chain account_reads P50 (ns)",   "chain_account_reads {quantile=0.5}"),
    ("chain account_hashes P50 (ns)",  "chain_account_hashes {quantile=0.5}"),
    ("chain inserts P50 (ns)",         "chain_inserts {quantile=0.5}"),
    ("chain execution P50 (ns)",       "chain_execution {quantile=0.5}"),
    ("chain storage_updates P50 (ns)", "chain_storage_updates {quantile=0.5}"),
]

ID_COLS = {"config", "benchmark", "k", "run"}


def asnum(s: str) -> float | None:
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def median(vals: list[float]) -> float | None:
    return statistics.median(vals) if vals else None


def load(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    """Read the metrics CSV. Returns (rows, metric column names)."""
    with open(path) as f:
        reader = csv.DictReader(f)
        cols = list(reader.fieldnames or [])
        rows = list(reader)
    metric_cols = [c for c in cols if c not in ID_COLS]
    return rows, metric_cols


def rank_overall(rows: list[dict[str, str]], metric_cols: list[str]) -> list[tuple[str, float, float, float]]:
    """For each metric, compute UBT vs PBT median across all rows. Return list of
    (metric, ubt_med, pbt_med, pbt_over_ubt) sorted by |log(ratio)| descending.
    Skips metrics where both medians are 0; flags one-zero cases separately."""
    out = []
    for m in metric_cols:
        u = [asnum(r[m]) for r in rows if r["config"] == "ubt"]
        p = [asnum(r[m]) for r in rows if r["config"] == "pbt"]
        u = [v for v in u if v is not None]
        p = [v for v in p if v is not None]
        if not (u and p):
            continue
        um, pm = median(u), median(p)
        if um == 0 and pm == 0:
            continue
        if um == 0:
            ratio = math.inf
        elif pm == 0:
            ratio = 0.0
        else:
            ratio = pm / um
        out.append((m, um, pm, ratio))
    # Rank by absolute log distance from 1.0
    def keyfn(t: tuple[str, float, float, float]) -> float:
        r = t[3]
        if r == 0 or r == math.inf:
            return math.inf  # one-zero cases first
        return abs(math.log(r))

    out.sort(key=keyfn, reverse=True)
    return out


def per_cell_table(rows: list[dict[str, str]], metric_col: str) -> list[tuple[str, float | None, float | None]]:
    """Per-cell (benchmark string) UBT vs PBT median. Each cell pools all 10
    runs for that config."""
    buckets: dict[tuple[str, str], list[float]] = defaultdict(list)
    for r in rows:
        v = asnum(r[metric_col])
        if v is None:
            continue
        buckets[(r["benchmark"], r["config"])].append(v)
    benches = sorted({r["benchmark"] for r in rows})
    return [(b, median(buckets.get((b, "ubt"), [])), median(buckets.get((b, "pbt"), []))) for b in benches]


def fmt_num(x: float | None) -> str:
    if x is None:
        return "-"
    if x == 0:
        return "0"
    if abs(x) >= 1e6 or abs(x) < 1e-3:
        return f"{x:.4g}"
    if abs(x) >= 1000:
        return f"{x:,.0f}"
    return f"{x:.4g}"


def ratio_mark(r: float) -> str:
    if r == 0 or r == math.inf:
        return " ∞"
    if r < 0.5 or r > 2.0:
        return " *"
    if 0.85 < r < 1.15:
        return " ·"
    return ""


def main() -> None:
    p = argparse.ArgumentParser(description="Compare UBT vs PBT metrics.")
    p.add_argument("--csv", default="data/x86-runs/100mgas-metrics-20260604.csv",
                   type=Path, help="metrics_consolidated.csv path")
    p.add_argument("--top", type=int, default=20,
                   help="show this many top metrics in the overall ranking")
    p.add_argument("--out-ranked", type=Path, default=None,
                   help="if set, write the full ranked CSV here")
    args = p.parse_args()

    if not args.csv.exists():
        raise SystemExit(f"missing: {args.csv}")
    rows, metric_cols = load(args.csv)
    print(f"loaded {len(rows)} rows, {len(metric_cols)} metric columns")
    print(f"  configs: {sorted({r['config'] for r in rows})}")
    print(f"  benchmarks: {len(set(r['benchmark'] for r in rows))}")
    print()

    # 1. Overall ranking
    ranked = rank_overall(rows, metric_cols)
    print(f"=== Top {args.top} metrics by |log(PBT/UBT)| (median of {len(rows)//2} rows per config) ===")
    print(f"  {'metric':<58} {'UBT med':>14} {'PBT med':>14} {'PBT/UBT':>9}")
    print("  " + "-" * 95)
    for m, u, pm, r in ranked[:args.top]:
        mark = ratio_mark(r)
        ratio_s = "∞" if r == math.inf else f"{r:.3f}"
        print(f"  {m[:57]:<58} {fmt_num(u):>14} {fmt_num(pm):>14} {ratio_s:>9}{mark}")
    print()

    if args.out_ranked is not None:
        with open(args.out_ranked, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["metric", "ubt_median", "pbt_median", "pbt_over_ubt",
                        "log_ratio"])
            for m, u, pm, r in ranked:
                lr = (math.log(r) if 0 < r < math.inf else
                      ("inf" if r == math.inf else "-inf"))
                w.writerow([m, u, pm, r, lr])
        print(f"wrote {args.out_ranked} ({len(ranked)} rows)")
        print()

    # 2. Per-cell breakdown for curated families
    print("=== Per-cell PBT/UBT ratios for selected metric families ===")
    print("legend:  * = ratio < 0.5 or > 2.0   · = within ±15% of parity")
    for label, col in FAMILIES:
        if col not in metric_cols:
            print(f"\n  -- {label}  ({col}): NOT FOUND in CSV")
            continue
        per_cell = per_cell_table(rows, col)
        valid = [(b, u, p) for b, u, p in per_cell if u is not None and p is not None and (u or p)]
        if not valid:
            continue
        print(f"\n  -- {label}  ({col})")
        print(f"    {'cell':<28} {'UBT median':>14} {'PBT median':>14} {'PBT/UBT':>9}")
        for b, u, pm in valid:
            if u == 0 and pm == 0:
                continue
            if u == 0:
                r_s = "∞"
                mark = " ∞"
            elif pm == 0:
                r_s = "0"
                mark = " 0"
            else:
                r = pm / u
                r_s = f"{r:.3f}"
                mark = ratio_mark(r)
            print(f"    {b:<28} {fmt_num(u):>14} {fmt_num(pm):>14} {r_s:>9}{mark}")


if __name__ == "__main__":
    main()
