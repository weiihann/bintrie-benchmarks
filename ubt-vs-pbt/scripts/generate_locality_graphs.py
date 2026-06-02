#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["matplotlib"]
# ///
"""Generate the locality-sweep report graphs from ubt_vs_pbt_consolidated.csv.

Three graphs per theme (dark + light):
    1. ratio_vs_K.svg               — PBT/UBT throughput ratio vs K, 3 curves
    2. state_read_ratio_vs_K.svg    — same plot but for state_read_ms only
                                       (shows clustering benefit on disk reads)
    3. timing_breakdown_k256.svg    — stacked bar of mean execution/state_read/
                                       state_hash/commit per benchmark at K=256;
                                       isolates where PBT's overhead lives.
"""

from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Themes
# ---------------------------------------------------------------------------

THEMES = {
    "dark": {
        "bg": "#0f172a",
        "fg": "#e2e8f0",
        "grid": "#334155",
        "ubt": "#60a5fa",   # blue-400
        "pbt": "#f59e0b",   # amber-500
        "ref": "#94a3b8",
    },
    "light": {
        "bg": "#ffffff",
        "fg": "#1f2937",
        "grid": "#d1d5db",
        "ubt": "#1d4ed8",   # blue-700
        "pbt": "#b45309",   # amber-700
        "ref": "#6b7280",
    },
}

BENCH_LABELS = {
    "storage_sload": "SLOAD",
    "storage_sstore": "SSTORE",
    "storage_mixed": "mixed (50/50)",
}
BENCH_ORDER = ["storage_sload", "storage_sstore", "storage_mixed"]
K_VALUES = [1, 10, 100, 400, 700]


def _apply_theme(theme: dict) -> None:
    plt.rcParams.update({
        "figure.facecolor": theme["bg"],
        "axes.facecolor": theme["bg"],
        "axes.edgecolor": theme["fg"],
        "axes.labelcolor": theme["fg"],
        "axes.titlecolor": theme["fg"],
        "xtick.color": theme["fg"],
        "ytick.color": theme["fg"],
        "grid.color": theme["grid"],
        "text.color": theme["fg"],
        "savefig.facecolor": theme["bg"],
        "savefig.edgecolor": "none",
    })


def _load_data(csv_path: Path) -> dict:
    """Group benchmark blocks by (base_bench, K, config)."""
    by_cell = defaultdict(lambda: defaultdict(list))
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            if int(r["gas_used"]) <= 500_000:
                continue
            bench = r["benchmark"]
            if "_k" not in bench:
                continue
            base, k_str = bench.rsplit("_k", 1)
            try:
                k = int(k_str)
            except ValueError:
                continue
            if base not in BENCH_LABELS:
                continue
            cell_key = (base, k, r["config"])
            for field in ("mgas_per_sec", "execution_ms", "state_read_ms",
                          "state_hash_ms", "commit_ms", "total_ms"):
                by_cell[cell_key][field].append(float(r[field]))
    return by_cell


def _bootstrap_ratio_ci(u: list[float], p: list[float], n_boot: int = 2000,
                       seed: int = 42) -> tuple[float, float, float]:
    """Median ratio with 95% bootstrap CI."""
    rng = np.random.default_rng(seed)
    u_arr = np.asarray(u)
    p_arr = np.asarray(p)
    boots = np.empty(n_boot)
    for i in range(n_boot):
        ub = rng.choice(u_arr, size=len(u_arr), replace=True)
        pb = rng.choice(p_arr, size=len(p_arr), replace=True)
        boots[i] = float(np.median(pb) / np.median(ub))
    return float(np.median(p_arr) / np.median(u_arr)), \
           float(np.percentile(boots, 2.5)), \
           float(np.percentile(boots, 97.5))


def plot_ratio_vs_K(data: dict, out_path: Path, theme: dict, metric: str = "mgas_per_sec",
                    title: str = "PBT / UBT throughput ratio vs K") -> None:
    """Headline: PBT/UBT ratio of `metric` plotted vs K, three curves (one per benchmark).

    For mgas_per_sec, ratio > 1 means PBT wins. For state_read_ms (lower is better),
    we invert so ratio > 1 still means PBT wins on disk reads.
    """
    _apply_theme(theme)
    fig, ax = plt.subplots(figsize=(9, 5.5))

    bench_colors = {
        "storage_sload": theme["ubt"],
        "storage_sstore": theme["pbt"],
        "storage_mixed": "#10b981" if theme is THEMES["dark"] else "#047857",
    }
    invert = metric == "state_read_ms"

    for bench in BENCH_ORDER:
        xs, ratios, los, his = [], [], [], []
        for k in K_VALUES:
            u = data.get((bench, k, "ubt"), {}).get(metric, [])
            p = data.get((bench, k, "pbt"), {}).get(metric, [])
            if not u or not p:
                continue
            if invert:
                # Use 1/x so that ratio > 1 means PBT is faster.
                u_inv = [1.0 / x for x in u if x > 0]
                p_inv = [1.0 / x for x in p if x > 0]
                r, lo, hi = _bootstrap_ratio_ci(u_inv, p_inv)
            else:
                r, lo, hi = _bootstrap_ratio_ci(u, p)
            xs.append(k); ratios.append(r); los.append(lo); his.append(hi)
        if not xs:
            continue
        color = bench_colors[bench]
        ax.plot(xs, ratios, marker="o", linewidth=2.5, markersize=8,
                color=color, label=BENCH_LABELS[bench])
        ax.fill_between(xs, los, his, alpha=0.18, color=color)

    ax.axhline(1.0, color=theme["ref"], linewidth=1, linestyle="--",
               label="PBT == UBT")
    ax.set_xscale("log")
    ax.set_xticks(K_VALUES)
    ax.set_xticklabels([str(k) for k in K_VALUES])
    ax.set_xlabel("K  (distinct contracts per block)", fontsize=11)
    metric_label = {
        "mgas_per_sec": "PBT / UBT  total throughput",
        "state_read_ms": "UBT / PBT  state_read_ms  (>1 = PBT faster on disk)",
    }[metric]
    ax.set_ylabel(metric_label, fontsize=11)
    ax.set_title(title, fontsize=13, pad=14)
    ax.grid(True, alpha=0.3, linewidth=0.6)
    ax.legend(loc="best", framealpha=0.9, facecolor=theme["bg"],
              edgecolor=theme["grid"])
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def plot_timing_breakdown(data: dict, out_path: Path, theme: dict,
                          k: int = 256) -> None:
    """Stacked bar: execution_ms / state_read_ms / state_hash_ms / commit_ms
    per (benchmark, config) at a single K. Shows where PBT's overhead lives.
    """
    _apply_theme(theme)
    fig, ax = plt.subplots(figsize=(10, 5.5))

    components = [
        ("execution_ms", "execution", "#64748b"),
        ("state_read_ms", "state read (disk)", "#3b82f6"),
        ("state_hash_ms", "state hash", "#ef4444"),
        ("commit_ms", "commit", "#a855f7"),
    ]

    bench_names = BENCH_ORDER
    n_groups = len(bench_names) * 2  # ubt + pbt per benchmark
    bar_w = 0.36

    xs = []
    labels = []
    for i, bench in enumerate(bench_names):
        # two bars per benchmark: ubt then pbt
        center = i * 1.0
        for j, cfg in enumerate(("ubt", "pbt")):
            xs.append(center + (j - 0.5) * (bar_w + 0.02))
            labels.append(f"{cfg.upper()}")

    bottoms = [0.0] * len(xs)
    for field, comp_label, color in components:
        heights = []
        for bench in bench_names:
            for cfg in ("ubt", "pbt"):
                vs = data.get((bench, k, cfg), {}).get(field, [])
                heights.append(statistics.median(vs) if vs else 0.0)
        ax.bar(xs, heights, bar_w, bottom=bottoms, label=comp_label,
               color=color, edgecolor=theme["bg"], linewidth=0.5)
        bottoms = [a + b for a, b in zip(bottoms, heights)]

    # Bench-name labels under each pair
    for i, bench in enumerate(bench_names):
        ax.text(i, -max(bottoms) * 0.08, BENCH_LABELS[bench],
                ha="center", va="top", fontsize=10, color=theme["fg"])

    ax.set_xticks(xs)
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylabel("median block time (ms)", fontsize=11)
    ax.set_title(f"Block time decomposition at K={k}  (median over 20 runs)",
                 fontsize=13, pad=14)
    ax.grid(True, axis="y", alpha=0.3, linewidth=0.6)
    ax.legend(loc="upper left", framealpha=0.9, facecolor=theme["bg"],
              edgecolor=theme["grid"])
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="data/ubt_vs_pbt_consolidated.csv",
                    type=Path)
    ap.add_argument("--out-dark", default="graphs", type=Path)
    ap.add_argument("--out-light", default="graphs-light", type=Path)
    args = ap.parse_args()

    if not args.csv.exists():
        raise SystemExit(f"Missing consolidated CSV: {args.csv}")
    data = _load_data(args.csv)
    print(f"Loaded {len(data)} (bench, K, config) cells from {args.csv}")

    for out_dir, theme_name in ((args.out_dark, "dark"), (args.out_light, "light")):
        out_dir.mkdir(parents=True, exist_ok=True)
        theme = THEMES[theme_name]
        plot_ratio_vs_K(
            data, out_dir / "ratio_vs_K.svg", theme,
            metric="mgas_per_sec",
            title="PBT / UBT throughput ratio vs K  (T=700 stem touches/block, 16M-gas blocks, 75 GB DB)",
        )
        plot_ratio_vs_K(
            data, out_dir / "state_read_ratio_vs_K.svg", theme,
            metric="state_read_ms",
            title="PBT / UBT state-read advantage vs K  (clustering benefit isolated)",
        )
        plot_timing_breakdown(
            data, out_dir / "timing_breakdown_k700.svg", theme, k=700,
        )
        plot_timing_breakdown(
            data, out_dir / "timing_breakdown_k1.svg", theme, k=1,
        )
        print(f"  wrote {out_dir}/{{ratio_vs_K,state_read_ratio_vs_K,timing_breakdown_k1,timing_breakdown_k700}}.svg")


if __name__ == "__main__":
    main()
