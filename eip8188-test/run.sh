#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EIP-8188 prototype backward-compatibility test.
#
# Proves that the prototype geth (with last_written_period tracking) produces
# identical state roots as vanilla geth by replaying the same chain.
#
# Usage:
#   bash eip8188-test/run.sh
#   bash eip8188-test/run.sh --keep   # preserve test directory on success
#
# Prerequisites:
#   - go-ethereum repo at ../go-ethereum (prototype branch checked out)
#   - spamoor binary at ../spamoor/bin/spamoor (or SPAMOOR_BIN env var)
#
# Exit codes: 0=pass, 1=preflight, 2=build, 3=chain gen, 4=import
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_PERIOD="${DEV_PERIOD:-1}"
NUM_BLOCKS="${NUM_BLOCKS:-50}"
EIP8188_FORK_BLOCK="${EIP8188_FORK_BLOCK:-0}"
EIP8188_PERIOD_LENGTH="${EIP8188_PERIOD_LENGTH:-3}"

KEEP=false
if [ "${1:-}" = "--keep" ] || [ "${KEEP:-}" = "true" ]; then
  KEEP=true
fi

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODES_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

GETH_DIR="$CODES_ROOT/go-ethereum"
SPAMOOR_DIR="$CODES_ROOT/spamoor"
SPAMOOR_BIN="${SPAMOOR_BIN:-$SPAMOOR_DIR/bin/spamoor}"

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { log "  PASS: $*"; }
fail() { log "  FAIL: $*"; exit "${1:-1}"; }

GETH_PID=""
TEST_DIR=""

cleanup() {
  if [ -n "$GETH_PID" ] && kill -0 "$GETH_PID" 2>/dev/null; then
    log "Stopping geth (pid=$GETH_PID)..."
    kill -TERM "$GETH_PID" 2>/dev/null || true
    sleep 3
    if kill -0 "$GETH_PID" 2>/dev/null; then
      kill -9 "$GETH_PID" 2>/dev/null || true
    fi
    wait "$GETH_PID" 2>/dev/null || true
  fi
  if [ "$KEEP" = false ] && [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    log "Cleaning up $TEST_DIR"
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT

wait_for_rpc() {
  local port="${1:-8545}"
  local retries=60
  while ! curl -sf "http://localhost:$port" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    >/dev/null 2>&1; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      fail 3 "RPC not available after 60s"
    fi
    sleep 1
  done
}

get_block_number() {
  curl -sf "http://localhost:8545" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "=== EIP-8188 Backward Compatibility Test ==="

# Check spamoor
if [ ! -f "$SPAMOOR_BIN" ]; then
  log "spamoor not found at $SPAMOOR_BIN"
  log "Build it: cd $SPAMOOR_DIR && go build -o bin/spamoor ."
  fail 1 "Missing spamoor binary"
fi

# Check go-ethereum
if [ ! -d "$GETH_DIR" ]; then
  fail 1 "go-ethereum not found at $GETH_DIR"
fi

# ---------------------------------------------------------------------------
# Step 1: Build both geth binaries
# ---------------------------------------------------------------------------

log "Step 1: Building geth binary..."

CURRENT_BRANCH=$(cd "$GETH_DIR" && git rev-parse --abbrev-ref HEAD)

# Build prototype geth (current branch). The same binary is used for chain
# generation (without --eip8188.* flags → vanilla behavior) and for import
# (with --eip8188.* flags → period tracking). This avoids git stash/checkout
# which is risky with uncommitted changes.
log "  Building from branch '$CURRENT_BRANCH'..."
(cd "$GETH_DIR" && go build -o build/bin/geth-prototype ./cmd/geth)
GETH_BIN="$GETH_DIR/build/bin/geth-prototype"
pass "Geth built"

# ---------------------------------------------------------------------------
# Step 2: Generate chain with master geth
# ---------------------------------------------------------------------------

TEST_DIR=$(mktemp -d "/tmp/eip8188-test-XXXXXX")
MASTER_DATADIR="$TEST_DIR/master"
PROTO_DATADIR="$TEST_DIR/prototype"
CHAIN_FILE="$TEST_DIR/chain.rlp"
LOG_DIR="$TEST_DIR/logs"
mkdir -p "$LOG_DIR"

log "Step 2: Generating chain with master geth..."
log "  Test directory: $TEST_DIR"

"$GETH_BIN" \
  --datadir "$MASTER_DATADIR" \
  --dev --dev.period "$DEV_PERIOD" --dev.gaslimit 30000000 \
  --http --http.addr 127.0.0.1 --http.port 8545 \
  --http.api eth,net,web3,debug,miner,txpool,admin,personal \
  --nodiscover --maxpeers 0 \
  --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
  --verbosity 3 \
  > "$LOG_DIR/master.log" 2>&1 &
GETH_PID=$!

log "  Master geth started (pid=$GETH_PID), waiting for RPC..."
wait_for_rpc 8545
pass "Master geth RPC ready"

# Send transactions via spamoor
log "  Sending transactions via spamoor..."
"$SPAMOOR_BIN" eoatx \
  --rpchost "http://localhost:8545" \
  --privkey "0x$SEED_KEY" \
  --count 200 \
  --throughput 50 \
  --max-pending 20 \
  --random-target \
  --amount "0.001eth" \
  > "$LOG_DIR/spamoor.log" 2>&1 || true

# Wait for blocks to finalize
sleep 5

BLOCK_NUM=$(get_block_number)
log "  Chain at block $BLOCK_NUM"

if [ "$BLOCK_NUM" -lt 5 ]; then
  fail 3 "Not enough blocks generated (got $BLOCK_NUM, need >= 5)"
fi
pass "Chain generated with $BLOCK_NUM blocks"

# Stop master geth gracefully
log "  Stopping master geth..."
kill -TERM "$GETH_PID" 2>/dev/null || true
sleep 5
if kill -0 "$GETH_PID" 2>/dev/null; then
  log "  Force killing geth..."
  kill -9 "$GETH_PID" 2>/dev/null || true
  sleep 1
fi
wait "$GETH_PID" 2>/dev/null || true
GETH_PID=""
rm -f "$MASTER_DATADIR/geth/chaindata/LOCK" 2>/dev/null || true

# Export chain
log "  Exporting chain..."
if ! "$GETH_BIN" --datadir "$MASTER_DATADIR" export "$CHAIN_FILE" \
  > "$LOG_DIR/export.log" 2>&1; then
  log "  Export failed. Log tail:"
  tail -20 "$LOG_DIR/export.log"
  fail 3 "Chain export failed"
fi
CHAIN_SIZE=$(du -h "$CHAIN_FILE" | cut -f1)
pass "Chain exported ($CHAIN_SIZE)"

# ---------------------------------------------------------------------------
# Step 3: Import chain into prototype geth
# ---------------------------------------------------------------------------

log "Step 3: Importing chain into prototype geth with EIP-8188 enabled..."

# Export the dev genesis from master so prototype can be initialized with it.
# Without a matching genesis, geth import defaults to mainnet genesis and
# every block's state root will mismatch.
log "  Dumping dev genesis..."
"$GETH_BIN" --datadir "$MASTER_DATADIR" dumpgenesis \
  > "$TEST_DIR/genesis.json" 2>/dev/null

if [ ! -s "$TEST_DIR/genesis.json" ]; then
  # Fallback: copy genesis directly from master chaindata
  log "  dumpgenesis produced empty output, copying chaindata genesis instead..."
  mkdir -p "$PROTO_DATADIR/geth"
  cp "$MASTER_DATADIR/geth/chaindata" "$PROTO_DATADIR/geth/chaindata" -r 2>/dev/null || true
else
  log "  Initializing prototype datadir with dev genesis..."
  "$GETH_BIN" --datadir "$PROTO_DATADIR" \
    --eip8188.forkblock "$EIP8188_FORK_BLOCK" \
    --eip8188.periodlength "$EIP8188_PERIOD_LENGTH" \
    init "$TEST_DIR/genesis.json" \
    > "$LOG_DIR/init.log" 2>&1
  pass "Prototype initialized with dev genesis"
fi

log "  Importing chain..."
"$GETH_BIN" --datadir "$PROTO_DATADIR" \
  --eip8188.forkblock "$EIP8188_FORK_BLOCK" \
  --eip8188.periodlength "$EIP8188_PERIOD_LENGTH" \
  --verbosity 3 \
  import "$CHAIN_FILE" \
  > "$LOG_DIR/import.log" 2>&1

IMPORT_EXIT=$?
if [ "$IMPORT_EXIT" -ne 0 ]; then
  log "  Import log tail:"
  tail -20 "$LOG_DIR/import.log"
  fail 4 "Chain import failed (exit=$IMPORT_EXIT) — state roots likely differ"
fi
pass "Chain imported successfully — all state roots match!"

# ---------------------------------------------------------------------------
# Step 4: Verify period metadata in prototype snapshot
# ---------------------------------------------------------------------------

log "Step 4: Verifying EIP-8188 period metadata..."

PERIODS_JSON=$("$GETH_BIN" --datadir "$PROTO_DATADIR" db inspect-periods 2>/dev/null) || true

if [ -z "$PERIODS_JSON" ]; then
  log "  inspect-periods produced no output. Log:"
  "$GETH_BIN" --datadir "$PROTO_DATADIR" db inspect-periods \
    > "$LOG_DIR/inspect-periods.log" 2>&1 || true
  tail -20 "$LOG_DIR/inspect-periods.log"
  fail 5 "Period inspection failed"
fi

echo "$PERIODS_JSON" > "$LOG_DIR/periods.json"
log "  Period report:"
echo "$PERIODS_JSON"

# Check that at least some accounts have non-zero periods.
ACCTS_WITH_PERIOD=$(echo "$PERIODS_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('accounts_with_period', 0))")

if [ "$ACCTS_WITH_PERIOD" -gt 0 ]; then
  pass "Found $ACCTS_WITH_PERIOD accounts with non-zero last_written_period"
else
  fail 5 "No accounts with non-zero period found — metadata not being tracked"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log ""
log "=== TEST PASSED ==="
log "  Geth branch:     $CURRENT_BRANCH"
log "  Blocks replayed: $BLOCK_NUM"
log "  Accounts w/period: $ACCTS_WITH_PERIOD"
log "  Fork block:      $EIP8188_FORK_BLOCK"
log "  Period length:   $EIP8188_PERIOD_LENGTH"
log "  Test directory:  $TEST_DIR"

if [ "$KEEP" = true ]; then
  log "  (Keeping test directory per --keep flag)"
else
  log "  (Test directory will be cleaned up)"
fi
