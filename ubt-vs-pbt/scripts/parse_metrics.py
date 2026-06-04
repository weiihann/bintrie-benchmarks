#!/usr/bin/env python3
"""Flatten per-cell geth prometheus scrapes into one wide consolidated CSV.

run_benchmarks.sh (with METRICS_SCRAPE=1) writes one prometheus text dump per cell:
    <RESULTS_DIR>/<config>/<benchmark>_k<K>_run<N>_metrics.prom
Because geth restarts cold per cell, each dump is that cell's cumulative DB activity
(physical disk reads, pebble/pathdb caches, compaction, chain timers, ...).

This script keeps EVERY metric (scrape-all; the report selects later). It emits one row
per cell keyed by (config, benchmark, run) — where `benchmark` is the `<name>_k<K>` form
used by the per-block CSV, so the two join cleanly — with one column per metric. The
column set is the union across all cells; missing values are blank.

Usage:
    parse_metrics.py <results_dir> --configs ubt pbt [--output <csv>]
Default output: <results_dir>/metrics_consolidated.csv
"""
import argparse
import csv
import glob
import os
import re

# <benchmark>_k<K>_run<N>_metrics.prom   (benchmark e.g. storage_sload)
_NAME_RE = re.compile(r"^(?P<bench>.+?)_k(?P<k>\d+)_run(?P<run>\d+)_metrics\.prom$")


def parse_prom(path):
    """Parse a prometheus text file into {column: value_string}.

    Standard text format: `metric_name{labels} value [timestamp]`, `# ...` are comments.
    geth's exporter mostly emits label-free names; histogram/summary lines carry a
    {quantile=...}/{le=...} label which we fold into the column so they stay distinct.
    """
    out = {}
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                name_part, value = line.rsplit(None, 1)
            except ValueError:
                continue
            # Fold any {labels} into the column name; keep CSV-safe (no comma/quote).
            mlab = re.match(r"^([^{]+)(\{.*\})?$", name_part)
            if not mlab:
                col = name_part
            else:
                base, labels = mlab.group(1), mlab.group(2) or ""
                col = base + (labels.replace(",", ";").replace('"', "") if labels else "")
            out[col] = value
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--configs", nargs="+", required=True)
    ap.add_argument("--output", default=None)
    args = ap.parse_args()

    rows = []
    all_metric_cols = set()
    for config in args.configs:
        cfg_dir = os.path.join(args.results_dir, config)
        for path in sorted(glob.glob(os.path.join(cfg_dir, "*_k*_run*_metrics.prom"))):
            m = _NAME_RE.match(os.path.basename(path))
            if not m:
                continue
            metrics = parse_prom(path)
            if not metrics:
                continue
            row = {
                "config": config,
                "benchmark": f"{m['bench']}_k{m['k']}",
                "k": int(m["k"]),
                "run": int(m["run"]),
            }
            row.update(metrics)
            all_metric_cols.update(metrics.keys())
            rows.append(row)

    if not rows:
        print("parse_metrics: no *_metrics.prom files found — nothing written")
        return

    header = ["config", "benchmark", "k", "run"] + sorted(all_metric_cols)
    out_path = args.output or os.path.join(args.results_dir, "metrics_consolidated.csv")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=header, extrasaction="ignore")
        w.writeheader()
        for r in sorted(rows, key=lambda x: (x["config"], x["benchmark"], x["run"])):
            w.writerow(r)
    print(f"parse_metrics: wrote {len(rows)} cells × {len(all_metric_cols)} metrics -> {out_path}")


if __name__ == "__main__":
    main()
