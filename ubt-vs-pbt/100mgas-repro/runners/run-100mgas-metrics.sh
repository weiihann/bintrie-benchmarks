#!/usr/bin/env bash
# 100M-gas locality campaign WITH metrics instrumentation. UBT vs PBT-v2 (zoned).
# Per-cell geth prometheus scrape (physical IO / pebble / pathdb / snapshot) +
# state-actor build-phase metrics dump. Fresh ~100GB DBs, NUM_RUNS=10, cold cache.
# New results dir — overwrites nothing.
set -euo pipefail
source /home/ethereum/work/env.sh
CAMPAIGN=/home/ethereum/repos/bintrie-benchmarks/ubt-vs-pbt
STAMP=$(date +%Y%m%d-%H%M%S)

NUM_RUNS=10 \
TARGET_SIZE=500GB \
COLD_CACHE=1 \
GROUP_DEPTH=5 \
HETERO_GETTERS=1 \
SKIP_ACCOUNTS=1 \
METRICS_SCRAPE=1 \
METRICS_PORT=6061 \
T_TOUCHES=5000 \
NUM_STEMS=5000 \
NUM_CONTRACTS=4500 \
GAS_BENCHMARK_VALUE=100 \
K_VALUES_STORAGE="1 10 100 1000 4500" \
BENCHMARKS="storage_sload storage_sstore storage_mixed" \
SA_ACCOUNTS=125000 \
SA_CONTRACTS=16400000 \
SA_MIN_SLOTS=1 \
SA_MAX_SLOTS=100000 \
SA_DISTRIBUTION=power-law \
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
DB_BASE="$WORK/dbs/100mgas" \
RESULTS_DIR="$WORK/results/100mgas-metrics" \
bash "$CAMPAIGN/scripts/run_campaign.sh" 2>&1 | tee "$WORK/results/100mgas-metrics/campaign-${STAMP}.log"
