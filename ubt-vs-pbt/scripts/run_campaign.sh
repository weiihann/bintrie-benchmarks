#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# UBT vs PBT campaign — top-level driver.
#
# Runs four stages:
#   1. generate_dbs.sh   — build both DBs (state-actor + spamoor)
#   2. run_benchmarks.sh — run the benchmark suite against each DB
#   3. extract_csv.py    — per-config slow-block logs → CSV
#   4. consolidation + analyze_data.py — merge + statistical comparison
#
# Defaults are tuned for a local smoke test at 1GB / 1 run. For a production
# campaign on a benchmark machine override via env:
#
#   NUM_RUNS=10 TARGET_SIZE=400GB COLD_CACHE=1 bash run_campaign.sh
#
# See README.md for the full env-var catalog.
# =============================================================================

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$CAMPAIGN_DIR/scripts"
RESULTS_DIR="${RESULTS_DIR:-$CAMPAIGN_DIR/data}"

# Shared by the sub-scripts (re-exported so generate_dbs.sh + run_benchmarks.sh see them)
export GETH_UBT_BIN="${GETH_UBT_BIN:-/tmp/bench-bins/geth-ubt}"
export GETH_PBT_BIN="${GETH_PBT_BIN:-/tmp/bench-bins/geth-pbt}"
export STATE_ACTOR_UBT_BIN="${STATE_ACTOR_UBT_BIN:-/tmp/bench-bins/state-actor-ubt}"
export STATE_ACTOR_PBT_BIN="${STATE_ACTOR_PBT_BIN:-/tmp/bench-bins/state-actor-pbt}"
export SPAMOOR_BIN="${SPAMOOR_BIN:-/Users/han/Documents/Codes/spamoor/bin/spamoor}"
export EXEC_SPECS="${EXEC_SPECS:-/Users/han/Documents/Codes/execution-specs}"
export UV="${UV:-$(command -v uv 2>/dev/null || echo /Users/han/.local/bin/uv)}"
export NUM_RUNS="${NUM_RUNS:-1}"
export TARGET_SIZE="${TARGET_SIZE:-1GB}"
export SPAMOOR_TARGET_GB="${SPAMOOR_TARGET_GB:-0.1}"
export GROUP_DEPTH="${GROUP_DEPTH:-8}"
export COLD_CACHE="${COLD_CACHE:-0}"
export BENCHMARKS="${BENCHMARKS:-erc20_balanceof erc20_approve mixed_sload_sstore}"
export RESULTS_DIR
export DB_BASE="${DB_BASE:-/tmp/ubt-vs-pbt-dbs}"

# state-actor scaling flags (opt-in; only used if set). Required for ≥10GB
# scale runs — without them state-actor's defaults cap the base DB ~1MB.
export SA_ACCOUNTS="${SA_ACCOUNTS:-}"
export SA_CONTRACTS="${SA_CONTRACTS:-}"
export SA_MIN_SLOTS="${SA_MIN_SLOTS:-}"
export SA_MAX_SLOTS="${SA_MAX_SLOTS:-}"
export SA_DISTRIBUTION="${SA_DISTRIBUTION:-}"

# Path to extract_csv.py — reused from group-depth-benchmarks (no modification)
EXTRACT_CSV="$CAMPAIGN_DIR/../group-depth-benchmarks/scripts/extract_csv.py"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage: $0 [--help]

UBT vs PBT end-to-end campaign. All knobs via env vars (see README.md):

  NUM_RUNS         (default $NUM_RUNS)        runs per benchmark per config
  TARGET_SIZE      (default $TARGET_SIZE)     state-actor DB target size
  SPAMOOR_TARGET_GB (default $SPAMOOR_TARGET_GB) ERC20 bloat target
  GROUP_DEPTH      (default $GROUP_DEPTH)     bintrie group depth
  COLD_CACHE       (default $COLD_CACHE)      drop OS+pebble caches (Linux + sudo)
  BENCHMARKS       (default "$BENCHMARKS")
  RESULTS_DIR      (default $RESULTS_DIR)
  DB_BASE          (default $DB_BASE)
  GETH_UBT_BIN     (default $GETH_UBT_BIN)
  GETH_PBT_BIN     (default $GETH_PBT_BIN)
  STATE_ACTOR_UBT_BIN (default $STATE_ACTOR_UBT_BIN)
  STATE_ACTOR_PBT_BIN (default $STATE_ACTOR_PBT_BIN)
  SPAMOOR_BIN      (default $SPAMOOR_BIN)
  EXEC_SPECS       (default $EXEC_SPECS)

Outputs:
  $RESULTS_DIR/{ubt,pbt}/*.csv     per-config benchmark CSVs
  $RESULTS_DIR/ubt_vs_pbt_consolidated.csv
  $RESULTS_DIR/analysis_results.json
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ ! -f "$EXTRACT_CSV" ]; then
  log "ERROR: extract_csv.py not found at $EXTRACT_CSV"
  exit 1
fi

mkdir -p "$RESULTS_DIR/ubt" "$RESULTS_DIR/pbt"

log "╔══════════════════════════════════════════════════════════════════╗"
log "║  UBT vs PBT campaign"
log "║  NUM_RUNS=$NUM_RUNS  TARGET_SIZE=$TARGET_SIZE  GD=$GROUP_DEPTH  COLD_CACHE=$COLD_CACHE"
log "╚══════════════════════════════════════════════════════════════════╝"

# =============================================================================
# Stage 1: Generate DBs
# =============================================================================
log ""
log "── Stage 1: generate_dbs.sh ──"
bash "$SCRIPTS_DIR/generate_dbs.sh"

# =============================================================================
# Stage 2: Run benchmarks
# =============================================================================
log ""
log "── Stage 2: run_benchmarks.sh ──"
bash "$SCRIPTS_DIR/run_benchmarks.sh"

# =============================================================================
# Stage 3: Extract per-config CSVs
# =============================================================================
log ""
log "── Stage 3: extract_csv.py per config ──"

for name in ubt pbt; do
  cfg_dir="$RESULTS_DIR/$name"
  log "  extracting $name from $cfg_dir"
  python3 "$EXTRACT_CSV" "$cfg_dir" \
    --config "$name" \
    --trie-type "bintrie" \
    --group-depth "$GROUP_DEPTH" \
    --pebble-block-size-kb 4
done

# =============================================================================
# Stage 4: Consolidate + analyze
# =============================================================================
log ""
log "── Stage 4: consolidate + analyze ──"

# Build consolidated CSV by concatenating per-config all_benchmarks CSVs.
# extract_csv.py writes them under $cfg_dir/csv/<config>_all_benchmarks.csv.
CONSOLIDATED="$RESULTS_DIR/ubt_vs_pbt_consolidated.csv"
UBT_CSV="$RESULTS_DIR/ubt/csv/ubt_all_benchmarks.csv"
PBT_CSV="$RESULTS_DIR/pbt/csv/pbt_all_benchmarks.csv"

if [ ! -f "$UBT_CSV" ] || [ ! -f "$PBT_CSV" ]; then
  log "ERROR: expected per-config CSVs missing"
  log "  ubt: $UBT_CSV ($([ -f "$UBT_CSV" ] && echo exists || echo MISSING))"
  log "  pbt: $PBT_CSV ($([ -f "$PBT_CSV" ] && echo exists || echo MISSING))"
  exit 1
fi

# Header from one, then rows from both (skipping the second header)
head -1 "$UBT_CSV" > "$CONSOLIDATED"
tail -n +2 "$UBT_CSV" >> "$CONSOLIDATED"
tail -n +2 "$PBT_CSV" >> "$CONSOLIDATED"
log "  consolidated: $CONSOLIDATED ($(wc -l < "$CONSOLIDATED") lines)"

# Run analysis (degrades gracefully when NUM_RUNS=1: medians only, no CIs)
log "  analyzing..."
python3 "$SCRIPTS_DIR/analyze_data.py" \
  --data-dir "$RESULTS_DIR" \
  --output "$RESULTS_DIR/analysis_results.json" \
  || log "  WARN: analyze_data.py exited non-zero (likely scipy missing or N=1) — JSON medians still useful"

log ""
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  Campaign complete"
log "╠══════════════════════════════════════════════════════════════════╣"
log "║  Consolidated CSV : $CONSOLIDATED"
log "║  Analysis JSON    : $RESULTS_DIR/analysis_results.json"
log "║  Per-config dirs  : $RESULTS_DIR/{ubt,pbt}/"
log "╚══════════════════════════════════════════════════════════════════╝"
