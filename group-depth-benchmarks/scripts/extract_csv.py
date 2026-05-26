#!/usr/bin/env python3
"""
Extract benchmark block data from Geth logs into per-benchmark CSV files.

Modes:
  1. Per-config extraction (default):
     ./extract_csv.py /path/to/results --config bt-gd4 --trie-type bintrie \
       --group-depth 4 --pebble-block-size-kb 4

  2. Consolidation (merge all per-config CSVs):
     ./extract_csv.py --consolidate --consolidate-dir /path/to/results \
       --output-dir /path/to/output

Produces:
  Per-config: sstore_variants.csv, sload_benchmark.csv, sload_same_key.csv,
              cache_validation.csv, all_benchmarks.csv
  Consolidated: page_size_benchmarks_consolidated.csv
"""

import argparse
import csv
import json
import re
import sys
from pathlib import Path

BENCHMARKS = [
    "sstore_variants",
    "sload_benchmark",
    "sload_same_key",
    "erc20_balanceof",
    "erc20_approve",
    "mixed_sload_sstore",
]

# CSV columns — config metadata prepended to block-level data.
# "contract" is the contract index for multi-contract runs (ubt-vs-pbt); it is
# empty for single-contract logs (group-depth-benchmarks naming).
BLOCK_COLUMNS = [
    "config", "trie_type", "group_depth", "pebble_block_size_kb",
    "benchmark", "run", "contract", "block_number", "gas_used", "tx_count",
    "execution_ms", "state_read_ms", "state_hash_ms", "commit_ms", "total_ms",
    "mgas_per_sec",
    "accounts_read", "storage_slots_read", "code_read", "code_bytes_read",
    "accounts_written", "accounts_deleted", "storage_slots_written",
    "storage_slots_deleted", "code_written", "code_bytes_written",
    "account_cache_hits", "account_cache_misses", "account_cache_hit_rate",
    "storage_cache_hits", "storage_cache_misses", "storage_cache_hit_rate",
    "code_cache_hits", "code_cache_misses", "code_cache_hit_rate",
    "code_cache_hit_bytes", "code_cache_miss_bytes",
]

CACHE_COLUMNS = [
    "config", "trie_type", "group_depth", "pebble_block_size_kb",
    "benchmark", "run", "contract",
    "num_blocks", "total_gas",
    "total_acct_hits", "total_acct_misses", "acct_cache_rate",
    "total_slot_hits", "total_slot_misses", "slot_cache_rate",
    "total_code_hits", "total_code_misses", "code_cache_rate",
    "avg_execution_ms", "avg_state_read_ms", "avg_state_hash_ms",
    "avg_commit_ms", "avg_total_ms", "avg_mgas_per_sec",
]


def parse_geth_log(filepath):
    """Parse Slow block JSON entries from a Geth log file.

    Geth outputs one JSON object per line with msg="Slow block" when
    --debug.logslowblock=0 is set. Each line is prefixed by geth's
    log handler; we find the first '{' and parse from there.
    """
    blocks = []
    with open(filepath) as f:
        for line in f:
            if '"Slow block"' not in line:
                continue
            try:
                start = line.index("{")
                data = json.loads(line[start:])
                if data.get("msg") != "Slow block":
                    continue
                blocks.append(data)
            except (ValueError, json.JSONDecodeError):
                continue
    return blocks


def block_to_row(config_meta, benchmark, run, data, contract=""):
    """Convert a parsed Slow block JSON to a CSV row dict."""
    b = data["block"]
    t = data["timing"]
    sr = data["state_reads"]
    sw = data["state_writes"]
    c = data["cache"]
    row = {
        **config_meta,
        "benchmark": benchmark,
        "run": run,
        "contract": contract,
        "block_number": b["number"],
        "gas_used": b["gas_used"],
        "tx_count": b["tx_count"],
        "execution_ms": round(t["execution_ms"], 4),
        "state_read_ms": round(t["state_read_ms"], 4),
        "state_hash_ms": round(t["state_hash_ms"], 4),
        "commit_ms": round(t["commit_ms"], 4),
        "total_ms": round(t["total_ms"], 4),
        "mgas_per_sec": round(data["throughput"]["mgas_per_sec"], 4),
        "accounts_read": sr["accounts"],
        "storage_slots_read": sr["storage_slots"],
        "code_read": sr["code"],
        "code_bytes_read": sr["code_bytes"],
        "accounts_written": sw["accounts"],
        "accounts_deleted": sw["accounts_deleted"],
        "storage_slots_written": sw["storage_slots"],
        "storage_slots_deleted": sw["storage_slots_deleted"],
        "code_written": sw["code"],
        "code_bytes_written": sw["code_bytes"],
        "account_cache_hits": c["account"]["hits"],
        "account_cache_misses": c["account"]["misses"],
        "account_cache_hit_rate": round(c["account"]["hit_rate"], 2),
        "storage_cache_hits": c["storage"]["hits"],
        "storage_cache_misses": c["storage"]["misses"],
        "storage_cache_hit_rate": round(c["storage"]["hit_rate"], 2),
        "code_cache_hits": c["code"]["hits"],
        "code_cache_misses": c["code"]["misses"],
        "code_cache_hit_rate": round(c["code"]["hit_rate"], 2),
        "code_cache_hit_bytes": c["code"]["hit_bytes"],
        "code_cache_miss_bytes": c["code"]["miss_bytes"],
    }
    return row


def compute_cache_summary(config_meta, benchmark, run, blocks, contract=""):
    """Compute aggregate cache metrics for a run (blocks with gas > 500K)."""
    big_blocks = [b for b in blocks if b["block"]["gas_used"] > 500000]
    if not big_blocks:
        return None

    total_acct_h = sum(b["cache"]["account"]["hits"] for b in big_blocks)
    total_acct_m = sum(b["cache"]["account"]["misses"] for b in big_blocks)
    total_slot_h = sum(b["cache"]["storage"]["hits"] for b in big_blocks)
    total_slot_m = sum(b["cache"]["storage"]["misses"] for b in big_blocks)
    total_code_h = sum(b["cache"]["code"]["hits"] for b in big_blocks)
    total_code_m = sum(b["cache"]["code"]["misses"] for b in big_blocks)

    n = len(big_blocks)
    return {
        **config_meta,
        "benchmark": benchmark,
        "run": run,
        "contract": contract,
        "num_blocks": n,
        "total_gas": sum(b["block"]["gas_used"] for b in big_blocks),
        "total_acct_hits": total_acct_h,
        "total_acct_misses": total_acct_m,
        "acct_cache_rate": round(
            100 * total_acct_h / (total_acct_h + total_acct_m), 2
        )
        if (total_acct_h + total_acct_m) > 0
        else 0,
        "total_slot_hits": total_slot_h,
        "total_slot_misses": total_slot_m,
        "slot_cache_rate": round(
            100 * total_slot_h / (total_slot_h + total_slot_m), 2
        )
        if (total_slot_h + total_slot_m) > 0
        else 0,
        "total_code_hits": total_code_h,
        "total_code_misses": total_code_m,
        "code_cache_rate": round(
            100 * total_code_h / (total_code_h + total_code_m), 2
        )
        if (total_code_h + total_code_m) > 0
        else 0,
        "avg_execution_ms": round(
            sum(b["timing"]["execution_ms"] for b in big_blocks) / n, 2
        ),
        "avg_state_read_ms": round(
            sum(b["timing"]["state_read_ms"] for b in big_blocks) / n, 2
        ),
        "avg_state_hash_ms": round(
            sum(b["timing"]["state_hash_ms"] for b in big_blocks) / n, 2
        ),
        "avg_commit_ms": round(
            sum(b["timing"]["commit_ms"] for b in big_blocks) / n, 2
        ),
        "avg_total_ms": round(
            sum(b["timing"]["total_ms"] for b in big_blocks) / n, 2
        ),
        "avg_mgas_per_sec": round(
            sum(b["throughput"]["mgas_per_sec"] for b in big_blocks) / n, 2
        ),
    }


def extract_config(args):
    """Extract CSVs for a single config from its results directory."""
    results_dir = Path(args.results_dir)
    output_dir = Path(args.output_dir) if args.output_dir else results_dir / "csv"
    output_dir.mkdir(parents=True, exist_ok=True)

    config_meta = {
        "config": args.config,
        "trie_type": args.trie_type,
        "group_depth": args.group_depth,
        "pebble_block_size_kb": args.pebble_block_size_kb,
    }

    print(f"Extracting CSVs for config: {args.config}")
    print(f"  Results dir: {results_dir}")
    print(f"  Output dir: {output_dir}")

    cache_rows = []
    all_block_rows = []

    for bench in BENCHMARKS:
        block_rows = []
        print(f"\n--- {bench} ---")

        # Match both single-contract logs ({bench}_run{run}_geth.log) and
        # multi-contract logs ({bench}_run{run}_c{idx}_geth.log).
        pattern = re.compile(
            rf"^{re.escape(bench)}_run(\d+)(?:_c(\d+))?_geth\.log$"
        )
        logs = sorted(
            p for p in results_dir.glob(f"{bench}_run*_geth.log")
            if pattern.match(p.name)
        )
        if not logs:
            print(f"  No logs for {bench}")
        for geth_log in logs:
            m = pattern.match(geth_log.name)
            run = int(m.group(1))
            contract = m.group(2) if m.group(2) is not None else ""

            blocks = parse_geth_log(geth_log)
            label = f"run {run}" + (f" c{contract}" if contract != "" else "")
            print(
                f"  {label}: {len(blocks)} total blocks, "
                f"{sum(1 for b in blocks if b['block']['gas_used'] > 500000)} benchmark blocks"
            )

            for b in blocks:
                block_rows.append(block_to_row(config_meta, bench, run, b, contract))

            cache_summary = compute_cache_summary(
                config_meta, bench, run, blocks, contract
            )
            if cache_summary:
                cache_rows.append(cache_summary)

        # Write per-benchmark CSV (config in filename for self-identification)
        csv_path = output_dir / f"{args.config}_{bench}.csv"
        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=BLOCK_COLUMNS)
            writer.writeheader()
            writer.writerows(block_rows)
        print(f"  -> Written {len(block_rows)} rows to {csv_path.name}")
        all_block_rows.extend(block_rows)

    # Write cache validation CSV
    cache_path = output_dir / f"{args.config}_cache_validation.csv"
    with open(cache_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CACHE_COLUMNS)
        writer.writeheader()
        writer.writerows(cache_rows)
    print(f"\n-> Cache validation: {len(cache_rows)} rows to {cache_path.name}")

    # Write all-benchmarks consolidated CSV for this config
    all_path = output_dir / f"{args.config}_all_benchmarks.csv"
    with open(all_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=BLOCK_COLUMNS)
        writer.writeheader()
        writer.writerows(all_block_rows)
    print(f"-> All benchmarks: {len(all_block_rows)} rows to {all_path.name}")

    # Print cache validation summary
    print("\n" + "=" * 80)
    print("  CACHE VALIDATION SUMMARY")
    print("=" * 80)
    for bench in BENCHMARKS:
        bench_rows = [r for r in cache_rows if r["benchmark"] == bench]
        if not bench_rows:
            continue
        avg_slot = sum(r["slot_cache_rate"] for r in bench_rows) / len(bench_rows)
        avg_acct = sum(r["acct_cache_rate"] for r in bench_rows) / len(bench_rows)
        min_slot = min(r["slot_cache_rate"] for r in bench_rows)
        max_slot = max(r["slot_cache_rate"] for r in bench_rows)
        print(f"\n  {bench}:")
        print(f"    Runs: {len(bench_rows)}")
        print(f"    Account cache: avg={avg_acct:.1f}%")
        print(
            f"    Storage cache: avg={avg_slot:.1f}%, "
            f"min={min_slot:.1f}%, max={max_slot:.1f}%"
        )
        if avg_slot > 80:
            print("    WARNING: High storage cache rate — results may not reflect cold access!")
        elif avg_slot < 60:
            print("    OK: Storage cache rates look reasonable for cold-start benchmarks")
        else:
            print("    MODERATE: Storage cache rate is borderline — inspect individual blocks")


def consolidate(args):
    """Merge all per-config all_benchmarks.csv files into one consolidated CSV."""
    consolidate_dir = Path(args.consolidate_dir)
    output_dir = Path(args.output_dir) if args.output_dir else consolidate_dir

    all_rows = []
    config_dirs = sorted(consolidate_dir.iterdir())

    for config_path in config_dirs:
        if not config_path.is_dir():
            continue
        csv_dir = config_path / "csv"
        if not csv_dir.is_dir():
            continue
        # Find the config-named all_benchmarks CSV
        matches = list(csv_dir.glob("*_all_benchmarks.csv"))
        if not matches:
            continue
        csv_file = matches[0]
        with open(csv_file, newline="") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            print(f"  {config_path.name}: {len(rows)} rows from {csv_file.name}")
            all_rows.extend(rows)

    if not all_rows:
        print("ERROR: No per-config CSVs found.")
        sys.exit(1)

    output_path = output_dir / "page_size_benchmarks_consolidated.csv"
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=BLOCK_COLUMNS)
        writer.writeheader()
        writer.writerows(all_rows)
    print(f"\n-> Consolidated: {len(all_rows)} rows to {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Extract benchmark CSV from Geth slow-block logs."
    )
    parser.add_argument(
        "results_dir", nargs="?",
        help="Path to config results directory (for per-config extraction)",
    )
    parser.add_argument("--config", help="Config ID (e.g., bt-gd4)")
    parser.add_argument(
        "--trie-type", choices=["bintrie", "mpt"], help="Trie type"
    )
    parser.add_argument("--group-depth", type=int, default=8)
    parser.add_argument("--pebble-block-size-kb", type=int, default=4)
    parser.add_argument("--output-dir", default=None, help="Output CSV directory")

    # Consolidation mode
    parser.add_argument(
        "--consolidate", action="store_true",
        help="Merge all per-config CSVs into one consolidated CSV",
    )
    parser.add_argument(
        "--consolidate-dir",
        help="Directory containing per-config result dirs",
    )

    args = parser.parse_args()

    if args.consolidate:
        if not args.consolidate_dir:
            parser.error("--consolidate requires --consolidate-dir")
        consolidate(args)
    else:
        if not args.results_dir or not args.config or not args.trie_type:
            parser.error(
                "Per-config mode requires: results_dir, --config, --trie-type"
            )
        extract_config(args)


if __name__ == "__main__":
    main()
