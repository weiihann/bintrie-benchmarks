#!/usr/bin/env bash
# Fast 1GB smoke validating the METRICS pipeline end-to-end:
#  - geth runs with --metrics; per-cell prometheus scrape -> *_metrics.prom
#  - state-actor (-m binaries) writes build metrics -> state-actor_metrics.prom
#  - parse_metrics.py flattens all to metrics_consolidated.csv (1 row/cell)
# Same fast 100M params as the prior smoke (200 hetero getters, K={1,200}, GBV=80).
set -euo pipefail
source /home/ethereum/work/env.sh
CAMPAIGN=/home/ethereum/repos/bintrie-benchmarks/ubt-vs-pbt

NUM_RUNS=1 \
TARGET_SIZE=1GB \
COLD_CACHE=0 \
GROUP_DEPTH=5 \
HETERO_GETTERS=1 \
SKIP_ACCOUNTS=1 \
METRICS_SCRAPE=1 \
METRICS_PORT=6061 \
T_TOUCHES=4000 \
NUM_STEMS=4000 \
NUM_CONTRACTS=200 \
GAS_BENCHMARK_VALUE=80 \
K_VALUES_STORAGE="1 200" \
BENCHMARKS="storage_sload storage_sstore storage_mixed" \
SA_GAS_LIMIT=200000000 \
DEPLOY_DEV_GASLIMIT=200000000 \
BENCH_DEV_GASLIMIT=200000000 \
GETH_UBT_BIN="$BENCH_BINS/geth-ubt-100m" \
GETH_PBT_BIN="$BENCH_BINS/geth-pbt-100m" \
STATE_ACTOR_UBT_BIN="$BENCH_BINS/state-actor-ubt-m" \
STATE_ACTOR_PBT_BIN="$BENCH_BINS/state-actor-pbt-m" \
SPAMOOR_BIN="$SPAMOOR_BIN" \
EXEC_SPECS="$EXEC_SPECS" \
UV="$(command -v uv)" \
DB_BASE="$WORK/dbs/smoke-100m-metrics" \
RESULTS_DIR="$WORK/results/smoke-100m-metrics" \
bash "$CAMPAIGN/scripts/run_campaign.sh"
