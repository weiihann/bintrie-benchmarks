#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["matplotlib"]
# ///
"""
Generate 8 benchmark visualization PNGs for UBT vs PBT comparison.

Usage:
    python scripts/generate_graphs.py --output-dir graphs --theme dark
    python scripts/generate_graphs.py --output-dir graphs-light --theme light
    uv run --with matplotlib scripts/generate_graphs.py
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.ticker as mticker


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CONFIGS = ["ubt", "pbt"]
CONFIG_LABELS: dict[str, str] = {
    "ubt": "UBT",
    "pbt": "PBT",
}

COLORS: dict[str, str] = {
    "ubt": "#1f77b4",     # blue
    "pbt": "#F59E0B",  # amber
}

BENCHMARKS = ["scattered_sload", "scattered_sstore", "scattered_mixed"]
BENCH_LABELS: dict[str, str] = {
    "scattered_sload": "balanceOf",
    "scattered_sstore": "approve",
    "scattered_mixed": "mixed",
}

STACKED_COMPONENTS = ["state_read_ms", "execution_ms", "state_hash_ms", "commit_ms"]
STACKED_LABELS = ["State Read", "Execution", "Trie Updates", "Commit"]
STACKED_COLORS = ["#3B82F6", "#14B8A6", "#EF4444", "#A855F7"]

FIGSIZE = (10, 6)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

class Theme:
    def __init__(self, name: str, bg: str, text: str, grid: str, axes: str) -> None:
        self.name = name
        self.bg = bg
        self.text = text
        self.grid = grid
        self.axes = axes

    def apply(self) -> None:
        plt.rcParams.update({
            "figure.facecolor": self.bg,
            "axes.facecolor": self.bg,
            "axes.edgecolor": self.axes,
            "axes.labelcolor": self.text,
            "text.color": self.text,
            "xtick.color": self.text,
            "ytick.color": self.text,
            "grid.color": self.grid,
            "legend.facecolor": self.bg,
            "legend.edgecolor": self.axes,
            "legend.labelcolor": self.text,
        })


THEMES: dict[str, Theme] = {
    "dark": Theme(
        name="dark",
        bg="#0A0E17",
        text="#E2E8F0",
        grid="#1E293B",
        axes="#475569",
    ),
    "light": Theme(
        name="light",
        bg="#FFFFFF",
        text="#1E293B",
        grid="#E2E8F0",
        axes="#94A3B8",
    ),
}


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_data(data_dir: Path) -> dict[str, list[dict[str, Any]]]:
    """Load ubt_vs_pbt_consolidated.csv, return dict keyed by config.

    Applies filters: gas_used > 500_000 and run > 1 (exclude warmup).
    Computes derived columns: ms_per_slot_read, ms_per_slot_hash, ms_per_cache_miss.
    """
    fpath = data_dir / "ubt_vs_pbt_consolidated.csv"
    if not fpath.exists():
        print(f"  ERROR: {fpath} not found", file=sys.stderr)
        return {}

    float_cols = [
        "gas_used", "execution_ms", "state_read_ms", "state_hash_ms",
        "commit_ms", "total_ms", "mgas_per_sec",
        "account_cache_hit_rate", "storage_cache_hit_rate",
        "code_cache_hit_rate",
    ]
    int_cols = [
        "run", "block_number", "tx_count",
        "accounts_read", "storage_slots_read", "code_read",
        "accounts_written", "storage_slots_written",
        "storage_slots_deleted", "code_written",
        "account_cache_hits", "account_cache_misses",
        "storage_cache_hits", "storage_cache_misses",
        "code_cache_hits", "code_cache_misses",
    ]

    all_data: dict[str, list[dict[str, Any]]] = defaultdict(list)
    with open(fpath, newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            run = int(r["run"])
            gas = float(r["gas_used"])
            if gas <= 500_000 or run <= 1:
                continue
            row: dict[str, Any] = dict(r)
            for c in float_cols:
                if c in row and row[c] != "":
                    row[c] = float(row[c])
            for c in int_cols:
                if c in row and row[c] != "":
                    row[c] = int(row[c])

            # Derived columns
            slots = row.get("storage_slots_read", 0)
            if slots and slots > 0:
                row["ms_per_slot_read"] = row["state_read_ms"] / slots
                row["ms_per_slot_hash"] = row["state_hash_ms"] / slots
                row["ms_per_slot_total"] = row["total_ms"] / slots
            else:
                row["ms_per_slot_read"] = None
                row["ms_per_slot_hash"] = None
                row["ms_per_slot_total"] = None

            misses = row.get("storage_cache_misses", 0)
            if misses and misses > 0:
                row["ms_per_cache_miss"] = row["state_read_ms"] / misses
            else:
                row["ms_per_cache_miss"] = None

            config = row["config"]
            all_data[config].append(row)

    for config, rows in all_data.items():
        print(f"  {config}: {len(rows)} rows loaded")
    return dict(all_data)


def filter_benchmark(all_data: dict[str, list[dict]], benchmark: str,
                     configs: list[str] | None = None) -> dict[str, list[dict]]:
    """Filter data for a specific benchmark, returning {config: [rows]}."""
    if configs is None:
        configs = CONFIGS
    result: dict[str, list[dict]] = {}
    for cfg in configs:
        if cfg not in all_data:
            continue
        matched = [r for r in all_data[cfg] if r["benchmark"] == benchmark]
        if matched:
            result[cfg] = matched
    return result


def col_values(rows: list[dict], col: str) -> list[float]:
    """Extract a column as list of floats, skipping None."""
    return [row[col] for row in rows if row.get(col) is not None]


def median_val(values: list[float]) -> float:
    if not values:
        return 0.0
    return statistics.median(values)


def cv_percent(values: list[float]) -> float:
    """Coefficient of variation as percentage."""
    if len(values) < 2:
        return 0.0
    m = statistics.mean(values)
    if m == 0:
        return 0.0
    s = statistics.stdev(values)
    return (s / m) * 100.0


def pearson_r(xs: list[float], ys: list[float]) -> float:
    """Compute Pearson correlation coefficient."""
    n = len(xs)
    if n < 3:
        return 0.0
    mx = statistics.mean(xs)
    my = statistics.mean(ys)
    sx = statistics.stdev(xs)
    sy = statistics.stdev(ys)
    if sx == 0 or sy == 0:
        return 0.0
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (n - 1)
    return cov / (sx * sy)


def linreg(xs: list[float], ys: list[float]) -> tuple[float, float]:
    """Simple linear regression, returns (slope, intercept)."""
    n = len(xs)
    if n < 2:
        return (0.0, 0.0)
    mx = statistics.mean(xs)
    my = statistics.mean(ys)
    ss_xx = sum((x - mx) ** 2 for x in xs)
    if ss_xx == 0:
        return (0.0, my)
    ss_xy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    slope = ss_xy / ss_xx
    intercept = my - slope * mx
    return (slope, intercept)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def cfg_label(config: str) -> str:
    return CONFIG_LABELS.get(config, config)


def save_fig(fig: plt.Figure, output_dir: Path, name: str, dpi: int) -> None:
    path = output_dir / name
    fig.savefig(path, dpi=dpi, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"  -> {path}")


def make_boxplot(ax: plt.Axes, data_list: list[list[float]], labels: list[str],
                 colors: list[str], theme: Theme, star_idx: int | None = None) -> None:
    """Draw styled boxplots with median annotations.

    star_idx: if set, add a star marker on that box (0-indexed).
    """
    if not data_list:
        return
    med_color = "white" if theme.name == "dark" else "black"
    bp = ax.boxplot(
        data_list, labels=labels, patch_artist=True,
        medianprops=dict(color=med_color, linewidth=1.5),
        whiskerprops=dict(color=theme.text, linewidth=0.8),
        capprops=dict(color=theme.text, linewidth=0.8),
        flierprops=dict(marker="o", markersize=3, alpha=0.4,
                        markerfacecolor=theme.text, markeredgecolor="none"),
    )
    for i, (patch, color) in enumerate(zip(bp["boxes"], colors)):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)
        patch.set_edgecolor(theme.text)

    # Annotate medians
    for i, d in enumerate(data_list):
        if not d:
            continue
        med = median_val(d)
        ax.text(i + 1, med, f"{med:.1f}", ha="center", va="bottom",
                fontsize=7, fontweight="bold", color=theme.text,
                bbox=dict(boxstyle="round,pad=0.15",
                          fc=theme.bg, alpha=0.7, edgecolor="none"))

    # Star annotation on winner
    if star_idx is not None and 0 <= star_idx < len(data_list):
        d = data_list[star_idx]
        if d:
            med = median_val(d)
            ax.plot(star_idx + 1, med * 1.15, marker="*", markersize=14,
                    color="#FFD700", zorder=10, markeredgecolor="black",
                    markeredgewidth=0.5)


# ---------------------------------------------------------------------------
# Graph generators
# ---------------------------------------------------------------------------

def g01_hero_time_breakdown(all_data: dict, theme: Theme,
                            output_dir: Path, dpi: int) -> None:
    """Side-by-side stacked horizontal bars for each benchmark."""
    fig, ax = plt.subplots(figsize=(12, 7))

    benchmarks = [b for b in BENCHMARKS]
    y_labels: list[str] = []
    y_positions: list[float] = []
    bar_height = 0.35
    gap = 1.0

    for bench_idx, bench in enumerate(benchmarks):
        by_cfg = filter_benchmark(all_data, bench)
        if not by_cfg:
            continue

        base_y = bench_idx * gap
        for cfg_idx, cfg in enumerate(CONFIGS):
            if cfg not in by_cfg:
                continue
            rows = by_cfg[cfg]
            y = base_y + (1 - cfg_idx) * (bar_height + 0.05)
            y_positions.append(y)
            y_labels.append(f"{BENCH_LABELS[bench]} / {cfg_label(cfg)}")

            left = 0.0
            for comp, label, color in zip(STACKED_COMPONENTS, STACKED_LABELS,
                                           STACKED_COLORS):
                val = median_val(col_values(rows, comp))
                ax.barh(y, val, bar_height, left=left, color=color,
                        alpha=0.85, edgecolor=theme.axes, linewidth=0.5,
                        label=label if bench_idx == 0 and cfg_idx == 0 else "")
                if val > 50:
                    text_color = "white" if theme.name == "dark" else "black"
                    ax.text(left + val / 2, y, f"{val:.0f}", ha="center",
                            va="center", fontsize=6, color=text_color,
                            fontweight="bold")
                left += val

            # Annotate total at end
            ax.text(left + 20, y, f"{left:.0f} ms", ha="left", va="center",
                    fontsize=7, fontweight="bold", color=theme.text)

            # Check for single-tx-block median difference
            single_tx = [r for r in rows if r["tx_count"] == 1]
            if single_tx and len(single_tx) != len(rows):
                single_total = median_val(col_values(single_tx, "total_ms"))
                if abs(single_total - left) / max(left, 1) > 0.05:
                    ax.annotate(
                        f"1-tx: {single_total:.0f}",
                        xy=(left + 10, y - bar_height * 0.4),
                        fontsize=5.5, color="#94A3B8", fontstyle="italic",
                    )

    ax.set_yticks(y_positions)
    ax.set_yticklabels(y_labels, fontsize=8)
    ax.set_xlabel("Median ms", fontsize=10)
    ax.set_title("Time Breakdown: UBT vs PBT", fontsize=13, fontweight="bold")
    ax.grid(axis="x", alpha=0.3)

    # Deduplicated legend
    handles = [mpatches.Patch(color=c, alpha=0.85, label=l)
               for c, l in zip(STACKED_COLORS, STACKED_LABELS)]
    ax.legend(handles=handles, fontsize=8, loc="lower right")
    ax.invert_yaxis()
    fig.tight_layout()
    save_fig(fig, output_dir, "g01_hero_time_breakdown.png", dpi)


def g02_throughput_boxplots(all_data: dict, theme: Theme,
                            output_dir: Path, dpi: int) -> None:
    """Three-panel figure: side-by-side boxplots of mgas_per_sec per benchmark."""
    active = [b for b in BENCHMARKS
              if any(cfg in filter_benchmark(all_data, b) for cfg in CONFIGS)]
    if not active:
        print("  SKIP g02_throughput_boxplots: no data")
        return

    fig, axes = plt.subplots(1, len(active), figsize=(5 * len(active), 6))
    if len(active) == 1:
        axes = [axes]

    for idx, bench in enumerate(active):
        ax = axes[idx]
        by_cfg = filter_benchmark(all_data, bench)
        data_list = []
        labels = []
        colors = []
        for cfg in CONFIGS:
            if cfg in by_cfg:
                vals = col_values(by_cfg[cfg], "mgas_per_sec")
                data_list.append(vals)
                labels.append(cfg_label(cfg))
                colors.append(COLORS[cfg])

        if not data_list:
            continue

        # Find winner (higher throughput)
        medians = [median_val(d) for d in data_list]
        star_idx = medians.index(max(medians)) if medians else None

        make_boxplot(ax, data_list, labels, colors, theme, star_idx=star_idx)

        # Add n= annotations
        for i, d in enumerate(data_list):
            ax.text(i + 1, ax.get_ylim()[0], f"n={len(d)}", ha="center",
                    va="bottom", fontsize=6, color="#94A3B8")

        ax.set_title(BENCH_LABELS[bench], fontsize=12, fontweight="bold")
        ax.set_ylabel("Mgas/s" if idx == 0 else "")
        ax.grid(axis="y", alpha=0.3)

        # Gas schedule caveat for approve and mixed panels
        if bench in ("scattered_sstore", "scattered_mixed"):
            ax.text(0.5, -0.10,
                    "\u26a0 Different gas schedules\n(EIP-4762 vs EIP-2929)",
                    ha="center", va="top", fontsize=6.5, color="#94A3B8",
                    transform=ax.transAxes, fontstyle="italic")

    fig.suptitle("Throughput: UBT vs PBT", fontsize=14, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    save_fig(fig, output_dir, "g02_throughput_boxplots.png", dpi)


def g03_evm_tax_scatter(all_data: dict, theme: Theme,
                        output_dir: Path, dpi: int) -> None:
    """Scatter: execution_ms vs state_read_ms, colored by config, with regression."""
    fig, ax = plt.subplots(figsize=FIGSIZE)

    for cfg in CONFIGS:
        if cfg not in all_data:
            continue
        rows = all_data[cfg]
        xs = col_values(rows, "state_read_ms")
        ys = col_values(rows, "execution_ms")
        if not xs:
            continue

        ax.scatter(xs, ys, color=COLORS[cfg], alpha=0.6, s=25,
                   edgecolors="none", label=cfg_label(cfg))

        # Linear regression line
        slope, intercept = linreg(xs, ys)
        r = pearson_r(xs, ys)
        x_min, x_max = min(xs), max(xs)
        x_line = [x_min, x_max]
        y_line = [slope * x + intercept for x in x_line]
        ax.plot(x_line, y_line, color=COLORS[cfg], linewidth=1.5,
                linestyle="--", alpha=0.8)

        # Annotate r value
        mid_x = (x_min + x_max) / 2
        mid_y = slope * mid_x + intercept
        ax.annotate(f"r = {r:.3f}", xy=(mid_x, mid_y),
                    fontsize=8, fontweight="bold", color=COLORS[cfg],
                    bbox=dict(boxstyle="round,pad=0.2", fc=theme.bg,
                              alpha=0.8, edgecolor="none"))

    ax.set_xlabel("state_read_ms", fontsize=10)
    ax.set_ylabel("execution_ms", fontsize=10)
    ax.set_title("EVM Tax: Execution vs State Read Time",
                 fontsize=13, fontweight="bold")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "g03_evm_tax_scatter.png", dpi)


def g04_cache_hit_panels(all_data: dict, theme: Theme,
                         output_dir: Path, dpi: int) -> None:
    """Two-panel: (A) cache hit rate per config per benchmark, (B) PBT scatter."""
    fig, (ax_a, ax_b) = plt.subplots(1, 2, figsize=(14, 6))

    # --- Panel A: Box+strip of storage_cache_hit_rate by config and benchmark ---
    active_benches = [b for b in BENCHMARKS
                      if any(cfg in filter_benchmark(all_data, b) for cfg in CONFIGS)]
    positions = []
    data_list = []
    colors_list = []
    tick_positions = []
    tick_labels_list = []
    pos = 1
    for bench in active_benches:
        by_cfg = filter_benchmark(all_data, bench)
        bench_center = pos + 0.5
        for cfg in CONFIGS:
            if cfg not in by_cfg:
                continue
            vals = col_values(by_cfg[cfg], "storage_cache_hit_rate")
            data_list.append(vals)
            colors_list.append(COLORS[cfg])
            positions.append(pos)
            pos += 1
        tick_positions.append(bench_center)
        tick_labels_list.append(BENCH_LABELS[bench])
        pos += 0.5  # gap between benchmarks

    if data_list:
        med_color = "white" if theme.name == "dark" else "black"
        bp = ax_a.boxplot(
            data_list, positions=positions, patch_artist=True, widths=0.6,
            medianprops=dict(color=med_color, linewidth=1.5),
            whiskerprops=dict(color=theme.text, linewidth=0.8),
            capprops=dict(color=theme.text, linewidth=0.8),
            flierprops=dict(marker="o", markersize=3, alpha=0.4,
                            markerfacecolor=theme.text, markeredgecolor="none"),
        )
        for patch, color in zip(bp["boxes"], colors_list):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
            patch.set_edgecolor(theme.text)

        # Strip overlay
        for i, (vals, p) in enumerate(zip(data_list, positions)):
            jitter = [p + (hash(str(v)) % 100 - 50) * 0.005 for v in vals]
            ax_a.scatter(jitter, vals, color=colors_list[i], s=8,
                         alpha=0.4, edgecolors="none", zorder=5)

        # Median annotations
        for i, vals in enumerate(data_list):
            if vals:
                med = median_val(vals)
                ax_a.text(positions[i], med + 1.5, f"{med:.1f}%",
                          ha="center", va="bottom", fontsize=6,
                          fontweight="bold", color=theme.text)

    ax_a.set_xticks(tick_positions)
    ax_a.set_xticklabels(tick_labels_list, fontsize=9)
    ax_a.set_ylabel("Storage Cache Hit Rate (%)")
    ax_a.set_title("A) Cache Hit Rate by Config", fontsize=11, fontweight="bold")
    ax_a.grid(axis="y", alpha=0.3)
    handles = [mpatches.Patch(color=COLORS[c], alpha=0.7, label=cfg_label(c))
               for c in CONFIGS]
    ax_a.legend(handles=handles, fontsize=8)

    # --- Panel B: PBT scatter: cache hit rate vs tx_count ---
    if "pbt" in all_data:
        bench_colors = {"scattered_sload": "#3B82F6", "scattered_sstore": "#EF4444",
                        "scattered_mixed": "#10B981"}
        for bench in BENCHMARKS:
            rows = [r for r in all_data["pbt"] if r["benchmark"] == bench]
            if not rows:
                continue
            xs = col_values(rows, "tx_count")
            ys = col_values(rows, "storage_cache_hit_rate")
            ax_b.scatter(xs, ys, color=bench_colors.get(bench, "#888"),
                         alpha=0.6, s=30, edgecolors="none",
                         label=BENCH_LABELS[bench])

    ax_b.set_xlabel("tx_count", fontsize=10)
    ax_b.set_ylabel("Storage Cache Hit Rate (%)")
    ax_b.set_title("B) PBT: Cache Rate vs Block Size",
                    fontsize=11, fontweight="bold")
    ax_b.grid(alpha=0.3)
    ax_b.legend(fontsize=8)

    fig.suptitle("Storage Cache Hit Rates", fontsize=14, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    save_fig(fig, output_dir, "g04_cache_hit_panels.png", dpi)


def g05_per_miss_read_cost(all_data: dict, theme: Theme,
                           output_dir: Path, dpi: int) -> None:
    """Boxplot of ms_per_cache_miss per benchmark, UBT vs PBT side by side."""
    active_benches = [b for b in BENCHMARKS
                      if any(cfg in filter_benchmark(all_data, b) for cfg in CONFIGS)]
    if not active_benches:
        print("  SKIP g05_per_miss_read_cost: no data")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)
    positions = []
    data_list = []
    colors_list = []
    tick_positions = []
    tick_labels_list = []
    pos = 1
    for bench in active_benches:
        by_cfg = filter_benchmark(all_data, bench)
        bench_center = pos + 0.5
        for cfg in CONFIGS:
            if cfg not in by_cfg:
                continue
            vals = col_values(by_cfg[cfg], "ms_per_cache_miss")
            data_list.append(vals)
            colors_list.append(COLORS[cfg])
            positions.append(pos)
            pos += 1
        tick_positions.append(bench_center)
        tick_labels_list.append(BENCH_LABELS[bench])
        # Ratio labels are added after the boxplot is drawn (see below), so the
        # y-position can use the real data extent rather than the default ylim.
        pos += 0.5

    if data_list:
        med_color = "white" if theme.name == "dark" else "black"
        bp = ax.boxplot(
            data_list, positions=positions, patch_artist=True, widths=0.6,
            medianprops=dict(color=med_color, linewidth=1.5),
            whiskerprops=dict(color=theme.text, linewidth=0.8),
            capprops=dict(color=theme.text, linewidth=0.8),
            flierprops=dict(marker="o", markersize=3, alpha=0.4,
                            markerfacecolor=theme.text, markeredgecolor="none"),
        )
        for patch, color in zip(bp["boxes"], colors_list):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
            patch.set_edgecolor(theme.text)

        # Median annotations
        for i, vals in enumerate(data_list):
            if vals:
                med = median_val(vals)
                ax.text(positions[i], med, f"{med:.3f}", ha="center",
                        va="bottom", fontsize=7, fontweight="bold",
                        color=theme.text,
                        bbox=dict(boxstyle="round,pad=0.15",
                                  fc=theme.bg, alpha=0.7, edgecolor="none"))

        # Re-annotate ratios after y-limits are set
        pos = 1
        for bench in active_benches:
            by_cfg = filter_benchmark(all_data, bench)
            bench_center = pos + 0.5
            medians_for_bench = {}
            for cfg in CONFIGS:
                if cfg not in by_cfg:
                    continue
                vals = col_values(by_cfg[cfg], "ms_per_cache_miss")
                medians_for_bench[cfg] = median_val(vals) if vals else 0.0
                pos += 1
            if len(medians_for_bench) == 2:
                m_ubt = medians_for_bench.get("ubt", 0)
                m_pbt = medians_for_bench.get("pbt", 0)
                if m_ubt > 0 and m_pbt > 0:
                    ratio = m_pbt / m_ubt
                    y_top = max(m_ubt, m_pbt) * 1.25
                    ax.text(bench_center, y_top,
                            f"PBT/UBT: {ratio:.2f}x", ha="center",
                            va="bottom", fontsize=7, color="#94A3B8",
                            fontstyle="italic")
            pos += 0.5

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels_list, fontsize=9)
    ax.set_ylabel("ms per cache miss", fontsize=10)
    ax.set_title("Per-Miss Read Cost (state_read_ms / storage_cache_misses)",
                 fontsize=13, fontweight="bold")
    ax.set_xlabel("Benchmark")
    ax.grid(axis="y", alpha=0.3)
    handles = [mpatches.Patch(color=COLORS[c], alpha=0.7, label=cfg_label(c))
               for c in CONFIGS]
    ax.legend(handles=handles, fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "g05_per_miss_read_cost.png", dpi)


def g06_cold_tail_effect(all_data: dict, theme: Theme,
                         output_dir: Path, dpi: int) -> None:
    """PBT approve: scatter tx_count vs ms_per_cache_miss with trend."""
    if "pbt" not in all_data:
        print("  SKIP g06_cold_tail_effect: no pbt data")
        return

    rows = [r for r in all_data["pbt"]
            if r["benchmark"] == "scattered_sstore" and r.get("ms_per_cache_miss") is not None]
    if not rows:
        print("  SKIP g06_cold_tail_effect: no approve data with cache misses")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)

    xs = [r["tx_count"] for r in rows]
    ys = [r["ms_per_cache_miss"] for r in rows]

    ax.scatter(xs, ys, color=COLORS["pbt"], alpha=0.6, s=40,
               edgecolors="none", zorder=5)

    # Connected medians per tx_count
    by_tx: dict[int, list[float]] = defaultdict(list)
    for r in rows:
        by_tx[r["tx_count"]].append(r["ms_per_cache_miss"])

    sorted_tx = sorted(by_tx.keys())
    if len(sorted_tx) >= 2:
        median_xs = sorted_tx
        median_ys = [median_val(by_tx[t]) for t in sorted_tx]
        ax.plot(median_xs, median_ys, color=COLORS["pbt"],
                linewidth=2, alpha=0.9, marker="D", markersize=6,
                markeredgecolor="white", markeredgewidth=0.5,
                label="Median per tx_count", zorder=6)

        # Annotate escalation
        y_min = median_ys[0]
        y_max = max(median_ys)
        if y_min > 0:
            escalation = y_max / y_min
            tx_max = median_xs[median_ys.index(y_max)]
            ax.annotate(
                f"{escalation:.1f}x escalation\n(tx=1 to tx={tx_max})",
                xy=(tx_max, y_max),
                xytext=(tx_max + 0.5, y_max * 1.1),
                fontsize=9, fontweight="bold", color=COLORS["pbt"],
                arrowprops=dict(arrowstyle="->", color=COLORS["pbt"],
                                lw=1.5),
                bbox=dict(boxstyle="round,pad=0.3", fc=theme.bg,
                          alpha=0.8, edgecolor=COLORS["pbt"]),
            )

    ax.set_xlabel("tx_count (transactions per block)", fontsize=10)
    ax.set_ylabel("ms per cache miss", fontsize=10)
    ax.set_title("Cold-Tail Effect: PBT approve",
                 fontsize=13, fontweight="bold")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "g06_cold_tail_effect.png", dpi)


def g07_per_slot_total_time(all_data: dict, theme: Theme,
                            output_dir: Path, dpi: int) -> None:
    """Grouped bar chart: median per-slot total time (total_ms / storage_slots_read)."""
    active_benches = [b for b in BENCHMARKS
                      if any(cfg in filter_benchmark(all_data, b) for cfg in CONFIGS)]
    if not active_benches:
        print("  SKIP g07_per_slot_total_time: no data")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)

    x_indices = range(len(active_benches))
    bar_width = 0.32
    offsets = {"ubt": -bar_width / 2, "pbt": bar_width / 2}

    medians_by_bench: dict[str, dict[str, float]] = {}

    for bench_idx, bench in enumerate(active_benches):
        by_cfg = filter_benchmark(all_data, bench)
        medians_by_bench[bench] = {}
        for cfg in CONFIGS:
            if cfg not in by_cfg:
                continue
            vals = col_values(by_cfg[cfg], "ms_per_slot_total")
            med = median_val(vals)
            medians_by_bench[bench][cfg] = med
            x = bench_idx + offsets[cfg]
            bar = ax.bar(x, med, bar_width, color=COLORS[cfg], alpha=0.85,
                         edgecolor=theme.axes, linewidth=0.5,
                         label=cfg_label(cfg) if bench_idx == 0 else "")
            # Value annotation on top of bar
            ax.text(x, med + med * 0.03, f"{med:.2f} ms/slot",
                    ha="center", va="bottom", fontsize=7, fontweight="bold",
                    color=theme.text)

    # Ratio annotations between each pair
    for bench_idx, bench in enumerate(active_benches):
        m = medians_by_bench.get(bench, {})
        m_ubt = m.get("ubt", 0)
        m_pbt = m.get("pbt", 0)
        if m_ubt > 0 and m_pbt > 0:
            ratio = m_pbt / m_ubt
            y_top = max(m_ubt, m_pbt) * 1.18
            ax.text(bench_idx, y_top, f"{ratio:.1f}\u00d7",
                    ha="center", va="bottom", fontsize=9, fontweight="bold",
                    color="#EF4444",
                    bbox=dict(boxstyle="round,pad=0.2", fc=theme.bg,
                              alpha=0.8, edgecolor="#EF4444", linewidth=0.5))

    ax.set_xticks(list(x_indices))
    ax.set_xticklabels([BENCH_LABELS[b] for b in active_benches], fontsize=10)
    ax.set_ylabel("ms per storage slot", fontsize=10)

    ax.grid(axis="y", alpha=0.3)
    handles = [mpatches.Patch(color=COLORS[c], alpha=0.85, label=cfg_label(c))
               for c in CONFIGS]
    ax.legend(handles=handles, fontsize=9)

    # Subtitle below the main title, with room so they don't overlap
    fig.suptitle("Per-Slot Total Processing Time", fontsize=13, fontweight="bold", y=0.98)
    ax.set_title("total_ms / storage_slots_read \u2014 normalized for workload size",
                 fontsize=8, color="#94A3B8", fontstyle="italic", pad=12)
    fig.subplots_adjust(top=0.88)
    save_fig(fig, output_dir, "g07_per_slot_total_time.png", dpi)


def g08_per_slot_write_cost(all_data: dict, theme: Theme,
                            output_dir: Path, dpi: int) -> None:
    """Boxplot of ms_per_slot_hash for approve, UBT vs PBT."""
    write_benches = ["scattered_sstore"]
    active = [b for b in write_benches
              if any(cfg in filter_benchmark(all_data, b) for cfg in CONFIGS)]
    if not active:
        print("  SKIP g08_per_slot_write_cost: no data")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)
    positions = []
    data_list = []
    colors_list = []
    tick_positions = []
    tick_labels_list = []
    pos = 1
    for bench in active:
        by_cfg = filter_benchmark(all_data, bench)
        bench_center = pos + 0.5
        medians_for_bench: dict[str, float] = {}
        for cfg in CONFIGS:
            if cfg not in by_cfg:
                continue
            vals = col_values(by_cfg[cfg], "ms_per_slot_hash")
            data_list.append(vals)
            colors_list.append(COLORS[cfg])
            positions.append(pos)
            medians_for_bench[cfg] = median_val(vals) if vals else 0.0
            pos += 1
        tick_positions.append(bench_center)
        tick_labels_list.append(BENCH_LABELS[bench])
        pos += 0.5

    if data_list:
        med_color = "white" if theme.name == "dark" else "black"
        bp = ax.boxplot(
            data_list, positions=positions, patch_artist=True, widths=0.6,
            medianprops=dict(color=med_color, linewidth=1.5),
            whiskerprops=dict(color=theme.text, linewidth=0.8),
            capprops=dict(color=theme.text, linewidth=0.8),
            flierprops=dict(marker="o", markersize=3, alpha=0.4,
                            markerfacecolor=theme.text, markeredgecolor="none"),
        )
        for patch, color in zip(bp["boxes"], colors_list):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
            patch.set_edgecolor(theme.text)

        # Median annotations + ratio
        for i, vals in enumerate(data_list):
            if vals:
                med = median_val(vals)
                ax.text(positions[i], med, f"{med:.4f}", ha="center",
                        va="bottom", fontsize=7, fontweight="bold",
                        color=theme.text,
                        bbox=dict(boxstyle="round,pad=0.15",
                                  fc=theme.bg, alpha=0.7, edgecolor="none"))

        # Ratio annotations
        pos = 1
        for bench in active:
            by_cfg = filter_benchmark(all_data, bench)
            bench_center = pos + 0.5
            medians_for_bench = {}
            for cfg in CONFIGS:
                if cfg not in by_cfg:
                    continue
                vals = col_values(by_cfg[cfg], "ms_per_slot_hash")
                medians_for_bench[cfg] = median_val(vals) if vals else 0.0
                pos += 1
            if len(medians_for_bench) == 2:
                m_ubt = medians_for_bench.get("ubt", 0)
                m_pbt = medians_for_bench.get("pbt", 0)
                if m_ubt > 0 and m_pbt > 0:
                    ratio = m_pbt / m_ubt
                    y_top = max(m_ubt, m_pbt) * 1.2
                    ax.text(bench_center, y_top,
                            f"PBT/UBT: {ratio:.2f}x", ha="center",
                            va="bottom", fontsize=7, color="#94A3B8",
                            fontstyle="italic")
            pos += 0.5

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels_list, fontsize=9)
    ax.set_ylabel("ms per slot (state_hash_ms / storage_slots_read)", fontsize=9)
    ax.set_title("Per-Slot Write Cost (Trie Update)", fontsize=13, fontweight="bold")
    ax.set_xlabel("Benchmark")

    # Subtitle note
    ax.text(0.5, -0.12,
            "Note: storage_slots_written may be 0 (broken counter); using slots_read as proxy",
            ha="center", va="top", fontsize=7, color="#94A3B8",
            transform=ax.transAxes, fontstyle="italic")

    ax.grid(axis="y", alpha=0.3)
    handles = [mpatches.Patch(color=COLORS[c], alpha=0.7, label=cfg_label(c))
               for c in CONFIGS]
    ax.legend(handles=handles, fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "g08_per_slot_write_cost.png", dpi)


# ---------------------------------------------------------------------------
# Registry & Main
# ---------------------------------------------------------------------------

ALL_GENERATORS = [
    g01_hero_time_breakdown,
    g02_throughput_boxplots,
    g03_evm_tax_scatter,
    g04_cache_hit_panels,
    g05_per_miss_read_cost,
    g06_cold_tail_effect,
    g07_per_slot_total_time,
    g08_per_slot_write_cost,
]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate benchmark graphs for UBT vs PBT comparison")
    parser.add_argument("--theme", choices=["dark", "light"], default="dark",
                        help="Color theme (default: dark)")
    parser.add_argument("--output-dir", default="graphs",
                        help="Directory for output PNGs (default: graphs)")
    parser.add_argument("--data-dir", default="data",
                        help="Directory containing CSV data files (default: data)")
    parser.add_argument("--dpi", type=int, default=150,
                        help="DPI for output PNGs (default: 150)")
    args = parser.parse_args()

    theme = THEMES[args.theme]
    theme.apply()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    data_dir = Path(args.data_dir)

    print(f"Loading data from {data_dir} ...")
    all_data = load_data(data_dir)

    total_rows = sum(len(v) for v in all_data.values())
    print(f"  Total: {total_rows} rows across {len(all_data)} configs "
          f"(after filtering gas_used > 500k, run > 1)")

    if not all_data:
        print("ERROR: No data loaded. Check --data-dir path.", file=sys.stderr)
        sys.exit(1)

    # Summary of benchmarks per config
    for cfg in CONFIGS:
        if cfg not in all_data:
            continue
        benchmarks = sorted({r["benchmark"] for r in all_data[cfg]})
        counts = {b: sum(1 for r in all_data[cfg] if r["benchmark"] == b)
                  for b in benchmarks}
        parts = [f"{b}={counts[b]}" for b in benchmarks]
        print(f"  {cfg}: {', '.join(parts)}")

    print(f"\nGenerating {len(ALL_GENERATORS)} graphs (theme={args.theme}, "
          f"dpi={args.dpi}) ...")
    generated: list[str] = []
    for gen_func in ALL_GENERATORS:
        name = gen_func.__name__
        print(f"  [{name}]")
        try:
            gen_func(all_data, theme, output_dir, args.dpi)
            generated.append(name)
        except Exception as exc:
            print(f"  ERROR in {name}: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()

    print(f"\nDone. Generated {len(generated)}/{len(ALL_GENERATORS)} graphs "
          f"in {output_dir}/")


if __name__ == "__main__":
    main()
