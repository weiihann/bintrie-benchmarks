#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Integration test for the binary trie benchmark pipeline.
#
# Mirrors the production workflow (generate_dbs.sh + run_erc20_benchmarks.sh)
# at 1GB scale to validate that state-actor, geth, and spamoor work together
# after code changes.
#
# Usage:
#   bash integration-test/run.sh            # auto-detect and build binaries
#   bash integration-test/run.sh --keep     # preserve test directory on success
#   GROUP_DEPTH=6 bash integration-test/run.sh
#
# Exit codes: 0=pass, 1=preflight, 2=DB generation, 3=geth/spamoor, 4=restart
# =============================================================================

# ---------------------------------------------------------------------------
# Section 1: Configuration
# ---------------------------------------------------------------------------

GROUP_DEPTH="${GROUP_DEPTH:-5}"
TARGET_SIZE="${TARGET_SIZE:-1GB}"
SPAMOOR_TARGET_GB="${SPAMOOR_TARGET_GB:-0.01}"

SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PRIVKEY="0x${SEED_KEY}"
STATE_ACTOR_SEED=25519
SPAMOOR_SEED="bintrie-integration"

KEEP=false
if [ "${1:-}" = "--keep" ] || [ "${KEEP:-}" = "true" ]; then
  KEEP=true
fi

# ---------------------------------------------------------------------------
# Section 2: Path resolution
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODES_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

GETH_DIR="$CODES_ROOT/go-ethereum"
STATE_ACTOR_DIR="$CODES_ROOT/state-actor"
SPAMOOR_DIR="$CODES_ROOT/spamoor"

# Use env vars if set, otherwise default to sibling repos
GETH_BIN="${GETH_BIN:-$GETH_DIR/build/bin/geth}"
STATE_ACTOR_BIN="${STATE_ACTOR:-$STATE_ACTOR_DIR/state-actor}"
SPAMOOR_BIN="${SPAMOOR_BIN:-$SPAMOOR_DIR/bin/spamoor}"
GENESIS="${GENESIS:-$STATE_ACTOR_DIR/genesis.json}"

# ---------------------------------------------------------------------------
# Section 3: Utility functions
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { log "  PASS: $*"; }
fail() { log "  FAIL: $*"; }

GETH_PID=""
TEST_PASSED=false
EXIT_CODE=0

rpc_call() {
  curl -sf http://localhost:8545 \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
}

get_balance() {
  rpc_call "eth_getBalance" "[\"$1\",\"latest\"]" \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))"
}

get_code_length() {
  rpc_call "eth_getCode" "[\"$1\",\"latest\"]" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)"
}

get_state_root() {
  rpc_call "eth_getBlockByNumber" "[\"latest\",false]" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['stateRoot'])"
}

# ---------------------------------------------------------------------------
# Section 4: Cleanup trap
# ---------------------------------------------------------------------------

cleanup() {
  local exit_code=$?
  set +e

  if [ -n "$GETH_PID" ] && kill -0 "$GETH_PID" 2>/dev/null; then
    log "Stopping geth (PID $GETH_PID)..."
    kill -TERM "$GETH_PID" 2>/dev/null || true
    sleep 3
    if kill -0 "$GETH_PID" 2>/dev/null; then
      kill -9 "$GETH_PID" 2>/dev/null || true
    fi
  fi

  if [ "$KEEP" = true ]; then
    log "Test directory preserved (--keep): $TEST_DIR"
  elif [ "$TEST_PASSED" = true ]; then
    log "Cleaning up test directory..."
    rm -rf "$TEST_DIR"
  else
    log ""
    log "Test FAILED. Directory preserved for debugging:"
    log "  DB:             $TEST_DIR/datadir/"
    log "  state-actor:    $TEST_DIR/state-actor.log"
    log "  geth (deploy):  $TEST_DIR/geth-deploy.log"
    log "  geth (restart): $TEST_DIR/geth-restart.log"
    log "  spamoor:        $TEST_DIR/spamoor.log"
  fi

  exit "$exit_code"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Section 5: Preflight checks — build binaries if missing
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Section 6: Logging setup — tee all output to a persistent log file
# ---------------------------------------------------------------------------

LOGS_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/$(date '+%Y%m%d-%H%M%S')-gd${GROUP_DEPTH}-${TARGET_SIZE}.log"

# Redirect all stdout/stderr through tee to persist the log
exec > >(tee -a "$LOG_FILE") 2>&1

log "================================================================"
log "  Binary Trie Integration Test"
log "  Group depth: GD-$GROUP_DEPTH | Target: $TARGET_SIZE"
log "  Log file:    $LOG_FILE"
log "================================================================"
log ""
log "Preflight checks..."

# Check genesis
if [ ! -f "$GENESIS" ]; then
  fail "genesis.json not found: $GENESIS"
  exit 1
fi
log "  GENESIS: $GENESIS"

# Build or find geth
if [ ! -x "$GETH_BIN" ]; then
  if [ -d "$GETH_DIR" ]; then
    log "  Building geth..."
    (cd "$GETH_DIR" && make geth)
    if [ ! -x "$GETH_BIN" ]; then
      fail "geth build failed: $GETH_BIN not found after build"
      exit 1
    fi
  else
    fail "geth not found at $GETH_BIN and source repo missing at $GETH_DIR"
    exit 1
  fi
fi
log "  GETH_BIN: $GETH_BIN"

# Build or find state-actor
if [ ! -x "$STATE_ACTOR_BIN" ]; then
  if [ -d "$STATE_ACTOR_DIR" ]; then
    log "  Building state-actor..."
    (cd "$STATE_ACTOR_DIR" && go build -o state-actor .)
    if [ ! -x "$STATE_ACTOR_BIN" ]; then
      fail "state-actor build failed: $STATE_ACTOR_BIN not found after build"
      exit 1
    fi
  else
    fail "state-actor not found at $STATE_ACTOR_BIN and source repo missing at $STATE_ACTOR_DIR"
    exit 1
  fi
fi
log "  STATE_ACTOR: $STATE_ACTOR_BIN"

# Build or find spamoor
if [ ! -x "$SPAMOOR_BIN" ]; then
  if [ -d "$SPAMOOR_DIR" ]; then
    log "  Building spamoor..."
    (cd "$SPAMOOR_DIR" && make build)
    if [ ! -x "$SPAMOOR_BIN" ]; then
      fail "spamoor build failed: $SPAMOOR_BIN not found after build"
      exit 1
    fi
  else
    fail "spamoor not found at $SPAMOOR_BIN and source repo missing at $SPAMOOR_DIR"
    exit 1
  fi
fi
log "  SPAMOOR: $SPAMOOR_BIN"

# Check port 8545 is free
if lsof -i :8545 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Port 8545 already in use"
  exit 1
fi
log "  Port 8545: free"

log "  All preflight checks passed."

# ---------------------------------------------------------------------------
# Create test directory
# ---------------------------------------------------------------------------

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bintrie-integration-XXXXXX")
DATADIR="$TEST_DIR/datadir"
mkdir -p "$DATADIR"
log "  Test directory: $TEST_DIR"

# ---------------------------------------------------------------------------
# kill_geth / start_geth
# ---------------------------------------------------------------------------

kill_geth() {
  if [ -n "$GETH_PID" ] && kill -0 "$GETH_PID" 2>/dev/null; then
    log "  [geth] Stopping (PID $GETH_PID)..."
    kill -TERM "$GETH_PID" 2>/dev/null || true
    sleep 5
    if kill -0 "$GETH_PID" 2>/dev/null; then
      log "  [geth] Force killing..."
      kill -9 "$GETH_PID" 2>/dev/null || true
      sleep 1
    fi
    GETH_PID=""
  fi
  rm -f "$DATADIR/geth/chaindata/LOCK" 2>/dev/null || true
}

start_geth() {
  local log_file="$1"
  local cache="${2:-4096}"

  kill_geth

  # Import seed key (idempotent)
  local keyfile
  keyfile=$(mktemp)
  echo "$SEED_KEY" > "$keyfile"
  echo "" | "$GETH_BIN" --datadir "$DATADIR" account import \
    --password /dev/stdin "$keyfile" >/dev/null 2>&1 || true
  rm -f "$keyfile"

  log "  [geth] Starting (gd=$GROUP_DEPTH, cache=$cache)..."
  "$GETH_BIN" \
    --datadir "$DATADIR" \
    --dev --dev.period 3 --dev.gaslimit 100000000 \
    --miner.etherbase "$SEED_ACCOUNT" \
    --cache "$cache" \
    --debug.logslowblock=0 \
    --bintrie.groupdepth "$GROUP_DEPTH" \
    --http --http.addr 127.0.0.1 --http.port 8545 \
    --http.api eth,net,web3,debug,miner,txpool,admin,personal \
    --ws --ws.addr 127.0.0.1 --ws.port 8546 \
    --ws.api eth,net,web3,debug,miner,txpool \
    --nodiscover --maxpeers 0 \
    --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
    --verbosity 3 \
    --override.ubt=0 \
    > "$log_file" 2>&1 &
  GETH_PID=$!
  disown "$GETH_PID" 2>/dev/null || true

  log "  [geth] Waiting for RPC (PID $GETH_PID)..."
  for i in $(seq 1 60); do
    if rpc_call "eth_chainId" "[]" >/dev/null 2>&1; then
      log "  [geth] RPC ready after ${i}s"
      return 0
    fi
    # Check if process died
    if ! kill -0 "$GETH_PID" 2>/dev/null; then
      fail "geth process died during startup"
      log "  Last 30 lines of geth log:"
      tail -30 "$log_file" || true
      return 1
    fi
    sleep 1
  done

  fail "geth RPC not ready after 60s"
  tail -30 "$log_file" || true
  return 1
}

# =============================================================================
# STAGE 1: DB Generation via state-actor
# =============================================================================

log ""
log "================================================================"
log "  STAGE 1: Generate binary trie DB ($TARGET_SIZE, GD-$GROUP_DEPTH)"
log "================================================================"

"$STATE_ACTOR_BIN" \
  -db "$DATADIR/geth/chaindata" \
  -binary-trie \
  -group-depth "$GROUP_DEPTH" \
  -target-size "$TARGET_SIZE" \
  -inject-accounts "$SEED_ACCOUNT" \
  -seed "$STATE_ACTOR_SEED" \
  -benchmark \
  -verbose \
  2>&1 | tee "$TEST_DIR/state-actor.log"

# Validate: DB exists with non-trivial size
DB_SIZE_KB=$(du -sk "$DATADIR/geth/chaindata" 2>/dev/null | cut -f1 || echo "0")
if [ "$DB_SIZE_KB" -lt 256 ]; then
  fail "DB too small: ${DB_SIZE_KB}KB"
  exit 2
fi
pass "DB size: $(du -sh "$DATADIR/geth/chaindata" | cut -f1)"

# Validate: state root is non-zero
STATE_ROOT=$(grep -o "State root.*: 0x[0-9a-fA-F]*" "$TEST_DIR/state-actor.log" \
  | tail -1 | grep -o "0x[0-9a-fA-F]*" || echo "")
if [ -z "$STATE_ROOT" ]; then
  fail "Could not extract state root from state-actor log"
  exit 2
fi
ZERO_ROOT="0x0000000000000000000000000000000000000000000000000000000000000000"
if [ "$STATE_ROOT" = "$ZERO_ROOT" ]; then
  fail "State root is zero"
  exit 2
fi
pass "State root: $STATE_ROOT"

# =============================================================================
# STAGE 2: Geth startup + ERC20 deployment via spamoor
# =============================================================================

log ""
log "================================================================"
log "  STAGE 2: Start geth + deploy ERC20 via spamoor"
log "================================================================"

# Start geth with cache for deployment
start_geth "$TEST_DIR/geth-deploy.log" 4096
sleep 2

# Set gas limit to 100M (non-fatal if method doesn't exist)
curl -sf http://localhost:8545 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x5F5E100"],"id":1}' > /dev/null 2>&1 || true

# Validate: seed account has balance
BALANCE=$(get_balance "$SEED_ACCOUNT")
if [ "$BALANCE" -eq 0 ] 2>/dev/null; then
  fail "Seed account has zero balance"
  exit 3
fi
pass "Seed balance: $(python3 -c "print($BALANCE / 1e18)") ETH"

# Deploy ERC20 via spamoor
log "  [spamoor] Deploying ERC20 (target=${SPAMOOR_TARGET_GB}GB)..."
"$SPAMOOR_BIN" erc20_bloater \
  --rpchost="http://localhost:8545" \
  --privkey="$PRIVKEY" \
  --seed="$SPAMOOR_SEED" \
  --target-gb="$SPAMOOR_TARGET_GB" \
  --target-gas-ratio=0.8 \
  --wallet-count=200 \
  -v > "$TEST_DIR/spamoor.log" 2>&1

# Extract contract address (portable, no grep -oP)
CONTRACT_ADDR=$(grep -o 'contract: 0x[0-9a-fA-F]*' "$TEST_DIR/spamoor.log" \
  | head -1 | sed 's/contract: //' || echo "")
if [ -z "$CONTRACT_ADDR" ]; then
  # Try alternate format
  CONTRACT_ADDR=$(grep -o 'deployed contract: 0x[0-9a-fA-F]*' "$TEST_DIR/spamoor.log" \
    | head -1 | sed 's/deployed contract: //' || echo "")
fi
if [ -z "$CONTRACT_ADDR" ]; then
  fail "Could not extract contract address from spamoor log"
  log "  Last 30 lines of spamoor log:"
  tail -30 "$TEST_DIR/spamoor.log"
  exit 3
fi
pass "ERC20 deployed: $CONTRACT_ADDR"

# Validate: contract has code on-chain
CODE_LEN=$(get_code_length "$CONTRACT_ADDR")
if [ "$CODE_LEN" -eq 0 ] 2>/dev/null; then
  fail "Contract has no code on-chain"
  exit 3
fi
pass "Contract code: ${CODE_LEN} bytes"

# Write stubs.json (same format as production)
cat > "$TEST_DIR/stubs.json" << STUBS_EOF
{
  "test_sload_empty_erc20_balanceof_SMALL": "$CONTRACT_ADDR",
  "test_sstore_erc20_approve_SMALL": "$CONTRACT_ADDR",
  "test_mixed_sload_sstore_SMALL": "$CONTRACT_ADDR"
}
STUBS_EOF
pass "stubs.json written"

# Graceful shutdown
kill_geth
sleep 2
pass "Geth shut down gracefully"

# =============================================================================
# STAGE 3: Restart validation (corruption check)
# =============================================================================

log ""
log "================================================================"
log "  STAGE 3: Restart validation (corruption check)"
log "================================================================"

start_geth "$TEST_DIR/geth-restart.log" 4096

# Validate: seed account still has balance
BALANCE_2=$(get_balance "$SEED_ACCOUNT")
if [ "$BALANCE_2" -eq 0 ] 2>/dev/null; then
  fail "Seed account lost balance after restart"
  exit 4
fi
pass "Seed balance after restart: $(python3 -c "print($BALANCE_2 / 1e18)") ETH"

# Validate: contract code persisted
CODE_LEN_2=$(get_code_length "$CONTRACT_ADDR")
if [ "$CODE_LEN_2" -eq 0 ] 2>/dev/null; then
  fail "Contract code missing after restart (DB corruption?)"
  exit 4
fi
pass "Contract code persisted: ${CODE_LEN_2} bytes"

# Validate: state root non-zero
RESTART_ROOT=$(get_state_root)
if [ -z "$RESTART_ROOT" ] || [ "$RESTART_ROOT" = "$ZERO_ROOT" ]; then
  fail "Zero state root after restart"
  exit 4
fi
pass "State root after restart: $RESTART_ROOT"

kill_geth

# =============================================================================
# STAGE 4: Database inspection
# =============================================================================

log ""
log "================================================================"
log "  STAGE 4: Database inspection (geth db inspect)"
log "================================================================"

"$GETH_BIN" db inspect \
  --datadir "$DATADIR" \
  2>&1 | tee "$TEST_DIR/db-inspect.log"

pass "Database inspection complete"

# =============================================================================
# Summary
# =============================================================================

TEST_PASSED=true

log ""
log "================================================================"
log "  ALL INTEGRATION TESTS PASSED"
log "================================================================"
log "  Group depth:    GD-$GROUP_DEPTH"
log "  DB size:        $(du -sh "$DATADIR/geth/chaindata" | cut -f1)"
log "  State root:     $STATE_ROOT"
log "  ERC20 contract: $CONTRACT_ADDR"
log "  Stubs:          $TEST_DIR/stubs.json"
log "  Log file:       $LOG_FILE"
log "================================================================"
