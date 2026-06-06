#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Compare UBT vs PBT state-actor build-phase metrics.

State-actor's --metrics-dump flag (the state-actor-100m.patch) writes a
Prometheus exposition-format snapshot at end of phase 1 (chain history build).
This captures pebble compaction/cache/disk stats + pathdb commit + process disk
IO for the *build*, not the benchmark. The two campaigns we want compared:

    ubt: data/{ubt,pbt}/state-actor_metrics.prom     (default location, per-config)
    pbt: same path, different worktree

For each metric the two configs share, this script reports:
    UBT value, PBT value, ratio (PBT/UBT), absolute delta

Skips:
    - quantile rows (handle separately if needed)
    - metrics where both sides are zero
    - metrics missing in either file

Example:
    uv run scripts/compare_stateactor_metrics.py \\
        --ubt data/ubt/state-actor_metrics.prom \\
        --pbt data/pbt/state-actor_metrics.prom
"""
from __future__ import annotations

import argparse
import math
import re
from pathlib import Path

# Prometheus exposition: metric_name {label="val", ...} value timestamp?
# Simple form here (no labels for non-quantile metrics):
#   metric_name value
# Quantile form (skip for now):
#   metric_name {quantile="0.5"} value
LINE_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*(\{[^}]*\})?\s+([-+]?[\d.e]+(?:E[-+]?\d+)?)\s*$")


def parse_prom(path: Path) -> dict[str, float]:
    """Parse a prometheus text dump. Returns {metric_name: float}, including
    quantile-tagged metrics keyed as 'metric_name{quantile=Q}'."""
    out: dict[str, float] = {}
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            name, labels, value = m.group(1), m.group(2) or "", m.group(3)
            try:
                v = float(value)
            except ValueError:
                continue
            key = f"{name}{labels}" if labels else name
            out[key] = v
    return out


def fmt_num(x: float) -> str:
    if x == 0:
        return "0"
    ax = abs(x)
    if ax >= 1e6 or ax < 1e-3:
        return f"{x:.4g}"
    if ax >= 1000:
        return f"{x:,.0f}"
    return f"{x:.4g}"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--ubt", type=Path, required=True, help="UBT state-actor_metrics.prom")
    p.add_argument("--pbt", type=Path, required=True, help="PBT state-actor_metrics.prom")
    p.add_argument("--top", type=int, default=30,
                   help="show this many top-divergent metrics")
    p.add_argument("--out-csv", type=Path, default=None,
                   help="if set, write the full comparison CSV here")
    args = p.parse_args()

    if not args.ubt.exists():
        raise SystemExit(f"missing: {args.ubt}")
    if not args.pbt.exists():
        raise SystemExit(f"missing: {args.pbt}")

    ubt = parse_prom(args.ubt)
    pbt = parse_prom(args.pbt)
    print(f"UBT metrics: {len(ubt)}    PBT metrics: {len(pbt)}    overlap: {len(set(ubt) & set(pbt))}")

    rows = []
    for k in sorted(set(ubt) & set(pbt)):
        u, p = ubt[k], pbt[k]
        if u == 0 and p == 0:
            continue
        if u == 0:
            ratio = math.inf
        elif p == 0:
            ratio = 0.0
        else:
            ratio = p / u
        delta = p - u
        rows.append((k, u, p, ratio, delta))

    def keyfn(t):
        r = t[3]
        if r in (0, math.inf):
            return math.inf
        return abs(math.log(r))

    rows.sort(key=keyfn, reverse=True)
    print(f"\nNonzero overlap metrics: {len(rows)}")
    print(f"\n=== Top {min(args.top, len(rows))} divergent state-actor metrics ===")
    print(f"  {'metric':<58} {'UBT':>14} {'PBT':>14} {'PBT/UBT':>9} {'PBT-UBT':>14}")
    print("  " + "-" * 110)
    for k, u, p, r, d in rows[:args.top]:
        r_s = "∞" if r == math.inf else ("0" if r == 0 else f"{r:.3f}")
        mark = ""
        if r != 0 and r != math.inf:
            if r < 0.5 or r > 2.0:
                mark = " *"
            elif 0.85 < r < 1.15:
                mark = " ·"
        print(f"  {k[:57]:<58} {fmt_num(u):>14} {fmt_num(p):>14} {r_s:>9} {fmt_num(d):>14}{mark}")

    if args.out_csv:
        import csv
        with open(args.out_csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["metric", "ubt", "pbt", "pbt_over_ubt", "pbt_minus_ubt", "log_ratio"])
            for k, u, p, r, d in rows:
                lr = (math.log(r) if 0 < r < math.inf else
                      ("inf" if r == math.inf else "-inf"))
                w.writerow([k, u, p, r, d, lr])
        print(f"\nwrote {args.out_csv} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
