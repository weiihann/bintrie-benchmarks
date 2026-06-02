#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Run the scattered storage benchmark suite against the ubt and pbt DBs.
#
# Three benchmarks × NUM_RUNS × 2 configs. Optionally drops OS + Pebble caches
# between runs (COLD_CACHE=1, Linux + sudo only).
#
# Prerequisites:
#   - DBs built and contracts.json populated by generate_dbs.sh.
#   - geth binaries at GETH_UBT_BIN / GETH_PBT_BIN.
#   - execution-specs checkout at EXEC_SPECS with benchmark tests.
# =============================================================================

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GETH_UBT_BIN="${GETH_UBT_BIN:-/tmp/bench-bins/geth-ubt}"
GETH_PBT_BIN="${GETH_PBT_BIN:-/tmp/bench-bins/geth-pbt}"
EXEC_SPECS="${EXEC_SPECS:-/Users/han/Documents/Codes/execution-specs}"
UV="${UV:-$(command -v uv 2>/dev/null || echo /Users/han/.local/bin/uv)}"

RESULTS_DIR="${RESULTS_DIR:-$CAMPAIGN_DIR/data}"
DB_BASE="${DB_BASE:-/tmp/ubt-vs-pbt-dbs}"

NUM_RUNS="${NUM_RUNS:-1}"
GROUP_DEPTH="${GROUP_DEPTH:-5}"
COLD_CACHE="${COLD_CACHE:-0}"
# Total gas per benchmark invocation, in millions. T_TOUCHES=256 stem fetches
# at ~22 k gas each ≈ ~6 M; this fits one tx (Osaka cap ≈ 16.7 M) in a 20 M-gas
# block, so each invocation is one cold 1-tx block — apples-to-apples Mgas/s.
GAS_BENCHMARK_VALUE="${GAS_BENCHMARK_VALUE:-16}"
# K-sweep values per zone. T=700, K_max=T (full scatter), K_min=1 (max clustering).
K_VALUES_STORAGE="${K_VALUES_STORAGE:-1 10 100 400 700}"
K_VALUES_ACCOUNT="${K_VALUES_ACCOUNT:-10 256}"
# The locality sweep interleaves K contracts × T/K stems each inside the EVM
# (attack walks a calldata address+sequence table), so there is no harness-side
# visit schedule — each (benchmark, K, run) is one invocation. The access
# sequence is a pure function of (T, K, target set), identical across configs.

SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

export RPC_ENDPOINT="http://localhost:8545"
export RPC_SEED_KEY="0x${SEED_KEY}"
export RPC_CHAIN_ID="1337"

# Configs: name | geth binary
CONFIGS=(
  "ubt|$GETH_UBT_BIN"
  "pbt|$GETH_PBT_BIN"
)

# Benchmark name | execution-specs test path | stub source | K values
declare -a BENCH_NAMES=()
declare -a BENCH_TESTS=()
declare -a BENCH_STUB_SOURCES=()   # "contracts" or "accounts"
declare -a BENCH_K_LISTS=()        # space-separated K values per bench
DEFAULT_BENCHMARKS="storage_sload storage_sstore storage_mixed"
read -ra _BENCH_OVERRIDES <<< "${BENCHMARKS:-$DEFAULT_BENCHMARKS}"
for name in "${_BENCH_OVERRIDES[@]}"; do
  case "$name" in
    storage_sload)
      BENCH_NAMES+=("storage_sload"); BENCH_STUB_SOURCES+=("contracts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_locality_sweep.py::test_storage_sload")
      BENCH_K_LISTS+=("$K_VALUES_STORAGE") ;;
    storage_sstore)
      BENCH_NAMES+=("storage_sstore"); BENCH_STUB_SOURCES+=("contracts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_locality_sweep.py::test_storage_sstore")
      BENCH_K_LISTS+=("$K_VALUES_STORAGE") ;;
    storage_mixed)
      BENCH_NAMES+=("storage_mixed"); BENCH_STUB_SOURCES+=("contracts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_locality_sweep.py::test_storage_mixed")
      BENCH_K_LISTS+=("$K_VALUES_STORAGE") ;;
    account_balance_read)
      BENCH_NAMES+=("account_balance_read"); BENCH_STUB_SOURCES+=("accounts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_account_locality.py::test_account_balance_read")
      BENCH_K_LISTS+=("$K_VALUES_ACCOUNT") ;;
    account_transfer)
      BENCH_NAMES+=("account_transfer"); BENCH_STUB_SOURCES+=("accounts")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_account_locality.py::test_account_transfer")
      BENCH_K_LISTS+=("$K_VALUES_ACCOUNT") ;;
    *)
      echo "ERROR: unknown benchmark '$name' (valid: storage_{sload,sstore,mixed}, account_{balance_read,transfer})" >&2
      exit 1 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

kill_geth() {
  local pids
  pids=$(pgrep -f "geth.*--dev" 2>/dev/null || true)
  if [ -z "$pids" ]; then
    return
  fi
  log "  [geth] Stopping (SIGTERM, waiting up to 120s for clean exit): $pids"
  echo "$pids" | xargs kill -TERM 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 120 ]; do
    local alive=""
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        alive="$alive $pid"
      fi
    done
    if [ -z "$alive" ]; then
      log "  [geth] exited cleanly after ${waited}s"
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "  [geth] WARN: did not exit within 120s — SIGKILL"
  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 2
}

drop_caches() {
  # Only drops on Linux when COLD_CACHE=1 AND sudo -n succeeds.
  # On Mac or without sudo, this is a no-op (warned once).
  sync
  if [ "$COLD_CACHE" != "1" ]; then
    return
  fi
  case "$(uname -s)" in
    Linux)
      if sudo -n /usr/sbin/sysctl -w vm.drop_caches=3 >/dev/null 2>&1; then
        log "  [cache] OS page cache dropped"
      else
        log "  [cache] ERROR: sudo drop_caches failed — check NOPASSWD sudoers rule for sysctl"
        exit 1
      fi ;;
    *)
      log "  [cache] WARN: COLD_CACHE=1 but not Linux; skipping drop_caches" ;;
  esac
}

start_geth_for_bench() {
  local geth_bin="$1"
  local datadir="$2"
  local config_id="$3"
  local geth_log="$4"

  kill_geth
  rm -f "$datadir/geth/chaindata/LOCK" 2>/dev/null || true
  drop_caches

  # Import seed key (idempotent)
  echo "$SEED_KEY" > /tmp/seed_key.hex
  echo "" | "$geth_bin" --datadir "$datadir" account import --password /dev/stdin /tmp/seed_key.hex 2>/dev/null || true
  rm -f /tmp/seed_key.hex

  # Cache configuration: OS page cache drop between runs (sysctl drop_caches=3
  # in drop_caches()) gives us cold inter-run state; within a block we let
  # Pebble use its default block cache so consecutive reads of nearby keys
  # (PBT clustering) can hit the cache instead of going to disk for every fetch.
  # This is the realistic production geth setup. To force fully-cold within-block
  # reads (Pebble cache disabled), pass --cache 0 manually.
  local cache_flag=()
  if [ "$COLD_CACHE" = "1" ]; then
    cache_flag=()                # let geth pick default
  else
    cache_flag=(--cache 4096)
  fi

  # One tx per block: the dev block gas limit (20M) caps to one benchmark tx
  # (the test builds one ~6M-gas tx per invocation), so both configs produce
  # identical 1-tx blocks of equal gas — no block-packing asymmetry, throughput
  # is apples-to-apples (mirrors the mpt-vs-bintrie methodology). dev.period 1
  # seals as soon as the tx is in the mempool — no idle wait.
  log "  [geth] Starting ($config_id, gd=$GROUP_DEPTH, cold=$COLD_CACHE, dev.period=1, 1tx/block)"
  "$geth_bin" \
    --datadir "$datadir" \
    --dev --dev.period 1 --dev.gaslimit 20000000 \
    --miner.etherbase "$SEED_ACCOUNT" \
    "${cache_flag[@]}" \
    --debug.logslowblock=0 \
    --http --http.addr 127.0.0.1 --http.port 8545 \
    --http.api eth,net,web3,debug,miner,txpool,admin,personal \
    --ws --ws.addr 127.0.0.1 --ws.port 8546 \
    --ws.api eth,net,web3,debug,miner,txpool \
    --nodiscover --maxpeers 0 \
    --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
    --rpc.batch-request-limit 100000 --rpc.batch-response-max-size 1000000000 \
    --verbosity 3 \
    --override.ubt=0 \
    --bintrie.groupdepth "$GROUP_DEPTH" \
    > "$geth_log" 2>&1 &

  log "  [geth] Waiting for RPC..."
  for i in $(seq 1 120); do
    if curl -s -X POST http://localhost:8545 \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
      2>/dev/null | grep -q "result"; then
      log "  [geth] RPC ready after ${i}s"
      break
    fi
    sleep 1
    if [ "$i" -eq 120 ]; then
      log "  [geth] ERROR: RPC not ready after 120s"
      tail -20 "$geth_log"
      return 1
    fi
  done

  curl -s -X POST http://localhost:8545 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x1312D00"],"id":1}' \
    > /dev/null
}

# =============================================================================
# Preflight
# =============================================================================
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  run_benchmarks.sh"
log "║  ${#BENCH_NAMES[@]} benchmarks × variable K-list × $NUM_RUNS runs × ${#CONFIGS[@]} configs"
log "║  COLD_CACHE=$COLD_CACHE  GROUP_DEPTH=$GROUP_DEPTH"
log "╚══════════════════════════════════════════════════════════════════╝"

if [ ! -x "$UV" ]; then
  log "ERROR: uv not found at $UV"
  exit 1
fi
if [ ! -d "$EXEC_SPECS/tests/benchmark/stateful/bloatnet" ]; then
  log "ERROR: execution-specs benchmark dir not found at $EXEC_SPECS/tests/benchmark/stateful/bloatnet"
  exit 1
fi

ALL_OK=true
for spec in "${CONFIGS[@]}"; do
  IFS='|' read -r name geth_bin <<< "$spec"
  db_path="$DB_BASE/$name"
  contracts="$RESULTS_DIR/$name/contracts.json"
  accounts="$RESULTS_DIR/$name/accounts.json"
  if [ ! -x "$geth_bin" ]; then
    log "  FAIL: geth binary missing: $geth_bin (config=$name)"
    ALL_OK=false
  fi
  if [ ! -d "$db_path/geth/chaindata" ]; then
    log "  FAIL: DB missing: $db_path/geth/chaindata (config=$name) — run generate_dbs.sh first"
    ALL_OK=false
  fi
  if [ ! -f "$contracts" ]; then
    log "  FAIL: contracts.json missing: $contracts (config=$name) — run generate_dbs.sh first"
    ALL_OK=false
  fi
  if [ ! -f "$accounts" ]; then
    log "  FAIL: accounts.json missing: $accounts (config=$name) — run generate_dbs.sh first"
    ALL_OK=false
  fi
  log "  $name: ok"
done

if [ "$COLD_CACHE" = "1" ] && [ "$(uname -s)" = "Linux" ]; then
  # Test the exact command drop_caches() runs, not a proxy — a narrow
  # NOPASSWD rule for sysctl won't satisfy `sudo -n true`.
  if ! sudo -n /usr/sbin/sysctl -w vm.drop_caches=3 >/dev/null 2>&1; then
    log "ERROR: COLD_CACHE=1 needs passwordless sudo for: /usr/sbin/sysctl -w vm.drop_caches=3"
    ALL_OK=false
  fi
fi

if [ "$ALL_OK" = false ]; then
  exit 1
fi

if lsof -nP -iTCP:8545 -sTCP:LISTEN >/dev/null 2>&1; then
  log "ERROR: port 8545 in use"
  exit 1
fi

# =============================================================================
# Run benchmark suite per config
# =============================================================================
STUBS_FILE="$EXEC_SPECS/tests/benchmark/stateful/bloatnet/stubs_bloatnet.json"

# write_stub_file <addr_json> <prefix>: expose every address from the given JSON
# array under the stub labels "<prefix>_<i>", so the test's address_stubs lookup
# resolves them to the pre-deployed addresses.
write_stub_file() {
  local addr_json="$1"
  local prefix="$2"
  python3 - "$addr_json" "$STUBS_FILE" "$prefix" <<'PY'
import json, sys
addrs = json.load(open(sys.argv[1]))
prefix = sys.argv[3]
stubs = {f"{prefix}_{i}": {"addr": a} for i, a in enumerate(addrs)}
json.dump(stubs, open(sys.argv[2], "w"), indent=2)
PY
}

for spec in "${CONFIGS[@]}"; do
  IFS='|' read -r name geth_bin <<< "$spec"
  db_path="$DB_BASE/$name"
  cfg_dir="$RESULTS_DIR/$name"
  contracts_file="$cfg_dir/contracts.json"

  log ""
  log "╔══════════════════════════════════════════════════════════════════╗"
  log "║  CONFIG: $name"
  log "╚══════════════════════════════════════════════════════════════════╝"

  rm -rf "$cfg_dir/csv"

  for bench_idx in "${!BENCH_NAMES[@]}"; do
    bench_name="${BENCH_NAMES[$bench_idx]}"
    bench_test="${BENCH_TESTS[$bench_idx]}"
    stub_source="${BENCH_STUB_SOURCES[$bench_idx]}"
    k_list="${BENCH_K_LISTS[$bench_idx]}"

    # Pick the right address source + stub prefix for this benchmark.
    # test_locality_sweep.py reads "scattered_target_<i>"; test_account_locality.py
    # reads "account_target_<i>".
    if [ "$stub_source" = "contracts" ]; then
      addr_json="$cfg_dir/contracts.json"
      stub_prefix="scattered_target"
    else
      addr_json="$cfg_dir/accounts.json"
      stub_prefix="account_target"
    fi

    if [ ! -f "$addr_json" ]; then
      log "  ERROR: $addr_json missing for $bench_name — re-run generate_dbs.sh"
      exit 1
    fi
    NCONTRACTS=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$addr_json")
    write_stub_file "$addr_json" "$stub_prefix"

    for K in $k_list; do
      log ""
      log "  ── BENCHMARK: ${bench_name}_k${K} (pool=${NCONTRACTS} ${stub_source}; effective K=$K)"

      # Clear stale per-cell logs for idempotency
      for run in $(seq 1 "$NUM_RUNS"); do
        rm -f "$cfg_dir/${bench_name}_k${K}_run${run}_geth.log" \
              "$cfg_dir/${bench_name}_k${K}_run${run}_test.log"
      done

      for run in $(seq 1 "$NUM_RUNS"); do
        stem="${bench_name}_k${K}_run${run}"
        # Per-run write offset: each run's writes start at a fresh, never-used slot
        # range (stride 100M >> ops/run), so SSTOREs are cold inserts, not warm
        # re-writes. Identical across configs (same run number) → same-state holds.
        # TEMPORARY (Phase T rerun, 2026-06-01): shifted by +300 to write into
        # slot ranges never touched by the prior campaigns on this DB
        # (original 100M..2B; Phase L 10.1G..12G; Phase O/P 20.1G..22G).
        # Fresh cold-init range 30.1G..32G.
        # REVERT to `run * 100000000` before any future campaign that builds
        # fresh DBs.
        export SCATTERED_WRITE_OFFSET=$(( (run + 300) * 100000000 ))
        export LOCALITY_K="$K"
        log ""
        log "  --- $stem ($name) write-offset=$SCATTERED_WRITE_OFFSET K=$K ---"

        start_geth_for_bench "$geth_bin" "$db_path" "$name" "$cfg_dir/geth_current.log"

        log "  [bench] Running execute remote..."
        cd "$EXEC_SPECS"
        set +e
        "$UV" run execute remote \
          --fork Osaka \
          --tx-wait-timeout 600 \
          --gas-benchmark-values "$GAS_BENCHMARK_VALUE" \
          --address-stubs "$STUBS_FILE" \
          "$bench_test" \
          -v > "$cfg_dir/${stem}_test.log" 2>&1
        test_exit=$?
        set -e

        cp "$cfg_dir/geth_current.log" "$cfg_dir/${stem}_geth.log"

        passed=$(grep -c " PASSED" "$cfg_dir/${stem}_test.log" 2>/dev/null || echo "0")
        failed=$(grep -c " FAILED" "$cfg_dir/${stem}_test.log" 2>/dev/null || echo "0")
        errors=$(grep -c "missing trie node" "$cfg_dir/${stem}_geth.log" 2>/dev/null || echo "0")
        log "  [bench] exit=$test_exit passed=$passed failed=$failed missing_trie_node=$errors"
      done
    done
  done

  kill_geth
done

log ""
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  All benchmark runs complete"
log "╚══════════════════════════════════════════════════════════════════╝"
