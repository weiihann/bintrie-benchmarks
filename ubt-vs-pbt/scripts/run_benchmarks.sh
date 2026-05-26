#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Run the ERC20 benchmark suite against the ubt and pbt DBs.
#
# Three benchmarks × NUM_RUNS × 2 configs. Optionally drops OS + Pebble caches
# between runs (COLD_CACHE=1, Linux + sudo only).
#
# Prerequisites:
#   - DBs built and stubs.json populated by generate_dbs.sh.
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
# Fixed seed for the contract-visit order. The permutation is a pure function of
# this seed + the contract count, so it is identical across configs, benchmarks,
# and runs — the apples-to-apples guarantee for the UBT-vs-PBT comparison.
CONTRACT_ORDER_SEED="${CONTRACT_ORDER_SEED:-ubt-vs-pbt-contract-order}"

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

# Benchmark name | execution-specs test path
declare -a BENCH_NAMES=()
declare -a BENCH_TESTS=()
DEFAULT_BENCHMARKS="erc20_balanceof erc20_approve mixed_sload_sstore"
read -ra _BENCH_OVERRIDES <<< "${BENCHMARKS:-$DEFAULT_BENCHMARKS}"
for name in "${_BENCH_OVERRIDES[@]}"; do
  case "$name" in
    erc20_balanceof)
      BENCH_NAMES+=("erc20_balanceof")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sload_erc20_generic") ;;
    erc20_approve)
      BENCH_NAMES+=("erc20_approve")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sstore_erc20_generic") ;;
    mixed_sload_sstore)
      BENCH_NAMES+=("mixed_sload_sstore")
      BENCH_TESTS+=("tests/benchmark/stateful/bloatnet/test_multi_opcode.py::test_mixed_sload_sstore") ;;
    *)
      echo "ERROR: unknown benchmark '$name' (valid: erc20_balanceof erc20_approve mixed_sload_sstore)" >&2
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

  # cold-cache mode: --cache=0 disables pebble cache. Hot mode: leave default.
  local cache_flag=()
  if [ "$COLD_CACHE" = "1" ]; then
    cache_flag=(--cache 0)
  else
    cache_flag=(--cache 4096)
  fi

  log "  [geth] Starting ($config_id, gd=$GROUP_DEPTH, cold=$COLD_CACHE, dev.period=1)"
  "$geth_bin" \
    --datadir "$datadir" \
    --dev --dev.period 1 --dev.gaslimit 110000000 \
    --miner.etherbase "$SEED_ACCOUNT" \
    "${cache_flag[@]}" \
    --debug.logslowblock=0 \
    --http --http.addr 127.0.0.1 --http.port 8545 \
    --http.api eth,net,web3,debug,miner,txpool,admin,personal \
    --ws --ws.addr 127.0.0.1 --ws.port 8546 \
    --ws.api eth,net,web3,debug,miner,txpool \
    --nodiscover --maxpeers 0 \
    --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
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
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x5F5E100"],"id":1}' \
    > /dev/null
}

# =============================================================================
# Preflight
# =============================================================================
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  run_benchmarks.sh"
log "║  ${#BENCH_NAMES[@]} benchmarks × $NUM_RUNS runs × ${#CONFIGS[@]} configs × N contracts (seeded order)"
log "║  COLD_CACHE=$COLD_CACHE  GROUP_DEPTH=$GROUP_DEPTH  ORDER_SEED=$CONTRACT_ORDER_SEED"
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

# write_stub_file <addr>: point all three benchmark labels at one contract.
write_stub_file() {
  local addr="$1"
  cat > "$STUBS_FILE" <<EOF
{
  "test_sload_empty_erc20_balanceof_SMALL": {"addr": "$addr"},
  "test_sstore_erc20_approve_SMALL": {"addr": "$addr"},
  "test_mixed_sload_sstore_SMALL": {"addr": "$addr"}
}
EOF
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

  # Load the contract addresses and compute the visit order. The permutation
  # depends only on CONTRACT_ORDER_SEED + the contract count, so it is identical
  # across configs, benchmarks, and runs. (read loop, not mapfile — macOS ships
  # bash 3.2 where mapfile is absent.)
  CONTRACTS=()
  while IFS= read -r _addr; do CONTRACTS+=("$_addr"); done < <(
    python3 -c "import json,sys; [print(a) for a in json.load(open(sys.argv[1]))]" "$contracts_file")
  ORDER=()
  while IFS= read -r _idx; do ORDER+=("$_idx"); done < <(
    python3 -c "import random,sys; n=int(sys.argv[1]); random.seed(sys.argv[2]); l=list(range(n)); random.shuffle(l); print('\n'.join(map(str,l)))" "${#CONTRACTS[@]}" "$CONTRACT_ORDER_SEED")
  log "  ${#CONTRACTS[@]} contracts, visit order: ${ORDER[*]}"

  # Clear old per-run logs for idempotency
  for bench_name in "${BENCH_NAMES[@]}"; do
    for run in $(seq 1 "$NUM_RUNS"); do
      rm -f "$cfg_dir/${bench_name}_run${run}_c"*_geth.log
      rm -f "$cfg_dir/${bench_name}_run${run}_c"*_test.log
    done
  done
  rm -rf "$cfg_dir/csv"

  for bench_idx in "${!BENCH_NAMES[@]}"; do
    bench_name="${BENCH_NAMES[$bench_idx]}"
    bench_test="${BENCH_TESTS[$bench_idx]}"

    log ""
    log "  ── BENCHMARK: $bench_name"

    for run in $(seq 1 "$NUM_RUNS"); do
      for idx in "${ORDER[@]}"; do
        caddr="${CONTRACTS[$idx]}"
        log ""
        log "  --- $bench_name run $run/$NUM_RUNS contract $idx ($caddr) ($name) ---"

        write_stub_file "$caddr"
        start_geth_for_bench "$geth_bin" "$db_path" "$name" "$cfg_dir/geth_current.log"

        log "  [bench] Running execute remote..."
        cd "$EXEC_SPECS"
        set +e
        # NOTE: -m stateful was dropped because the bloatnet tests no longer
        # carry that marker (PR #2430 removed it). The test path under
        # tests/benchmark/stateful/bloatnet/ already scopes selection.
        "$UV" run execute remote \
          --fork Osaka \
          --tx-wait-timeout 600 \
          --gas-benchmark-values 100 \
          --address-stubs "$STUBS_FILE" \
          "$bench_test" \
          -v > "$cfg_dir/${bench_name}_run${run}_c${idx}_test.log" 2>&1
        test_exit=$?
        set -e

        # Save geth log for extract_csv.py
        cp "$cfg_dir/geth_current.log" "$cfg_dir/${bench_name}_run${run}_c${idx}_geth.log"

        passed=$(grep -c " PASSED" "$cfg_dir/${bench_name}_run${run}_c${idx}_test.log" 2>/dev/null || echo "0")
        failed=$(grep -c " FAILED" "$cfg_dir/${bench_name}_run${run}_c${idx}_test.log" 2>/dev/null || echo "0")
        errors=$(grep -c "missing trie node" "$cfg_dir/${bench_name}_run${run}_c${idx}_geth.log" 2>/dev/null || echo "0")
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
