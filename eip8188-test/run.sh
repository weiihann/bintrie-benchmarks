#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# EIP-8188 prototype end-to-end test (inject + inspect + identify-inactive).
#
# This branch's workflow:
#   1. Sync a chain in dev mode (no period stamping at commit time)
#   2. Backfill periods via `geth db inject-periods` from a JSONL fixture
#   3. Verify periods with `geth db inspect-periods`
#   4. Walk the trie with `geth db identify-inactive`, asserting that the
#      output reflects the configured threshold
#
# Usage:
#   bash eip8188-test/run.sh
#   bash eip8188-test/run.sh --keep   # preserve test directory on success
#
# Prerequisites:
#   - go-ethereum repo at ../go-ethereum (this branch checked out)
#   - spamoor binary at ../spamoor/bin/spamoor (or SPAMOOR_BIN env var)
#
# Exit codes: 0=pass, 1=preflight, 2=build, 3=chain gen, 4=inject,
#             5=inspect, 6=identify
# =============================================================================

# Configuration
SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_PERIOD="${DEV_PERIOD:-1}"
MIN_BLOCKS="${MIN_BLOCKS:-10}"
FORK_BLOCK="${FORK_BLOCK:-0}"
BLOCKS_PER_PERIOD="${BLOCKS_PER_PERIOD:-3}"

# The fixture marks the seed account as written at FIXTURE_BLOCK. With
# BLOCKS_PER_PERIOD=3, block 9 → period 3. Choose any block <= MIN_BLOCKS.
FIXTURE_BLOCK="${FIXTURE_BLOCK:-9}"

# When running identify, current_period is derived from the chain head. We
# also override it to a deterministic value so the test outcome doesn't
# depend on exactly how many blocks were produced.
IDENTIFY_CURRENT_PERIOD="${IDENTIFY_CURRENT_PERIOD:-3}"
# threshold=3: seed (period=3, age=0) is ACTIVE; everyone else (period=0,
# age=3) is INACTIVE. Trie root is MIXED → expect non-empty subtree output
# but NOT the root.
IDENTIFY_THRESHOLD="${IDENTIFY_THRESHOLD:-3}"

KEEP=false
if [ "${1:-}" = "--keep" ] || [ "${KEEP:-}" = "true" ]; then
  KEEP=true
fi

# Path resolution
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODES_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
GETH_DIR="$CODES_ROOT/go-ethereum"
SPAMOOR_DIR="$CODES_ROOT/spamoor"
SPAMOOR_BIN="${SPAMOOR_BIN:-$SPAMOOR_DIR/bin/spamoor}"

# Logging
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
    [ "$retries" -le 0 ] && fail 3 "RPC not available after 60s"
    sleep 1
  done
}

get_block_number() {
  curl -sf "http://localhost:8545" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))"
}

# Preflight
log "=== EIP-8188 Inject + Identify End-to-End Test ==="

[ -f "$SPAMOOR_BIN" ] || fail 1 "spamoor not found at $SPAMOOR_BIN"
[ -d "$GETH_DIR" ] || fail 1 "go-ethereum not found at $GETH_DIR"

# Step 1: build geth from this branch
log "Step 1: Building geth..."
CURRENT_BRANCH=$(cd "$GETH_DIR" && git rev-parse --abbrev-ref HEAD)
(cd "$GETH_DIR" && go build -o build/bin/geth-prototype ./cmd/geth)
GETH_BIN="$GETH_DIR/build/bin/geth-prototype"
pass "Geth built (branch=$CURRENT_BRANCH)"

# Step 2: dev chain with spamoor traffic
TEST_DIR=$(mktemp -d "/tmp/eip8188-test-XXXXXX")
DATADIR="$TEST_DIR/datadir"
LOG_DIR="$TEST_DIR/logs"
FIXTURE="$TEST_DIR/fixture.jsonl"
mkdir -p "$LOG_DIR"

log "Step 2: Generating dev chain (need >= $MIN_BLOCKS blocks)..."
log "  Test dir: $TEST_DIR"

# --miner.pending.feeRecipient pins the dev faucet to our SEED_ACCOUNT so
# the privkey used by spamoor matches the funded account. Without this flag
# geth dev generates its own random developer key and the seed account has
# zero ETH. (The flag was renamed from --miner.etherbase in newer geth.)
"$GETH_BIN" \
  --datadir "$DATADIR" \
  --dev --dev.period "$DEV_PERIOD" --dev.gaslimit 30000000 \
  --miner.pending.feeRecipient "$SEED_ACCOUNT" \
  --http --http.addr 127.0.0.1 --http.port 8545 \
  --http.api eth,net,web3,debug,miner,txpool,admin,personal \
  --nodiscover --maxpeers 0 \
  --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
  --verbosity 3 \
  > "$LOG_DIR/geth.log" 2>&1 &
GETH_PID=$!

log "  Geth started (pid=$GETH_PID), waiting for RPC..."
wait_for_rpc 8545
pass "RPC ready"

log "  Sending transactions via spamoor..."
"$SPAMOOR_BIN" eoatx \
  --rpchost "http://localhost:8545" \
  --privkey "0x$SEED_KEY" \
  --count 50 \
  --throughput 20 \
  --max-pending 10 \
  --random-target \
  --amount 1000 \
  > "$LOG_DIR/spamoor.log" 2>&1 || true

# Wait for chain to reach MIN_BLOCKS.
sleep 3
BLOCK_NUM=$(get_block_number)
while [ "$BLOCK_NUM" -lt "$MIN_BLOCKS" ]; do
  log "  Chain at block $BLOCK_NUM, waiting for $MIN_BLOCKS..."
  sleep 2
  BLOCK_NUM=$(get_block_number)
done
pass "Chain at block $BLOCK_NUM"

# Stop geth so the chaindb can be opened by `db inject-periods`.
log "  Stopping geth gracefully..."
kill -TERM "$GETH_PID" 2>/dev/null || true
sleep 5
if kill -0 "$GETH_PID" 2>/dev/null; then
  kill -9 "$GETH_PID" 2>/dev/null || true
  sleep 1
fi
wait "$GETH_PID" 2>/dev/null || true
GETH_PID=""
rm -f "$DATADIR/geth/chaindata/LOCK" 2>/dev/null || true
pass "Geth stopped"

# Step 3: inject periods from a JSONL fixture
# Fixture: seed account written at FIXTURE_BLOCK. With FORK_BLOCK=0 and
# BLOCKS_PER_PERIOD=3, that puts the seed at period FIXTURE_BLOCK/3.
log "Step 3: Injecting periods from fixture..."
cat > "$FIXTURE" <<EOF
{"kind":"account","block":$FIXTURE_BLOCK,"address":"$SEED_ACCOUNT"}
EOF
log "  Fixture: $(cat "$FIXTURE")"

if ! "$GETH_BIN" --datadir "$DATADIR" db inject-periods \
  --fork-block "$FORK_BLOCK" \
  --blocks-per-period "$BLOCKS_PER_PERIOD" \
  --source "file://$FIXTURE" \
  > "$LOG_DIR/inject.log" 2>&1; then
  log "  Inject log tail:"
  tail -20 "$LOG_DIR/inject.log"
  fail 4 "inject-periods failed"
fi
pass "Inject completed"

# Step 4: inspect periods to verify the seed account was updated
log "Step 4: Verifying injected period..."
if ! INSPECT_JSON=$("$GETH_BIN" --datadir "$DATADIR" db inspect-periods --json 2>/dev/null); then
  fail 5 "inspect-periods failed"
fi
echo "$INSPECT_JSON" > "$LOG_DIR/inspect.json"
log "  Inspect report: $INSPECT_JSON"

ACCT_WITH_PERIOD=$(echo "$INSPECT_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('accounts_with_period', 0))")
MAX_ACCT_PERIOD=$(echo "$INSPECT_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('max_account_period', 0))")
EXPECTED_PERIOD=$((FIXTURE_BLOCK / BLOCKS_PER_PERIOD))

if [ "$ACCT_WITH_PERIOD" -lt 1 ]; then
  fail 5 "expected >=1 account_with_period, got $ACCT_WITH_PERIOD"
fi
if [ "$MAX_ACCT_PERIOD" -ne "$EXPECTED_PERIOD" ]; then
  fail 5 "expected max_account_period=$EXPECTED_PERIOD, got $MAX_ACCT_PERIOD"
fi
pass "Seed account has period $MAX_ACCT_PERIOD ($ACCT_WITH_PERIOD account(s) injected)"

# Step 5: identify inactive subtrees
# With current_period=$IDENTIFY_CURRENT_PERIOD and threshold=$IDENTIFY_THRESHOLD:
#   - Seed account has period=$EXPECTED_PERIOD, age=0 → ACTIVE
#   - All other accounts have period=0 (default), age=3 → INACTIVE
#   - Trie root is MIXED → expect non-empty subtree output, but NEVER root path
log "Step 5: Identifying inactive subtrees..."
IDENTIFY_OUT="$LOG_DIR/identify.jsonl"
if ! "$GETH_BIN" --datadir "$DATADIR" db identify-inactive \
  --fork-block "$FORK_BLOCK" \
  --blocks-per-period "$BLOCKS_PER_PERIOD" \
  --current-period "$IDENTIFY_CURRENT_PERIOD" \
  --inactive-min-age "$IDENTIFY_THRESHOLD" \
  --scope account \
  --output "$IDENTIFY_OUT" \
  > "$LOG_DIR/identify.log" 2>&1; then
  log "  identify log tail:"
  tail -20 "$LOG_DIR/identify.log"
  fail 6 "identify-inactive failed"
fi

if [ ! -s "$IDENTIFY_OUT" ]; then
  fail 6 "identify-inactive produced no output"
fi

NUM_SUBTREES=$(wc -l < "$IDENTIFY_OUT" | tr -d ' ')
log "  Emitted $NUM_SUBTREES inactive subtree root(s):"
head -5 "$IDENTIFY_OUT"

# Sanity: the trie root path is "" (empty string). Since seed account is
# active, root must NOT be emitted — every line must have a non-empty path.
ROOT_EMITTED=$(python3 -c "
import json,sys
n = 0
for line in open('$IDENTIFY_OUT'):
    line = line.strip()
    if not line: continue
    s = json.loads(line)
    if s.get('path','') == '':
        n += 1
print(n)")
if [ "$ROOT_EMITTED" -ne 0 ]; then
  fail 6 "expected NO root subtree (seed account is active), got $ROOT_EMITTED root entries"
fi

if [ "$NUM_SUBTREES" -lt 1 ]; then
  fail 6 "expected >=1 inactive subtree, got $NUM_SUBTREES"
fi
pass "Identified $NUM_SUBTREES inactive subtree root(s); trie root correctly NOT emitted"

# Summary
log ""
log "=== TEST PASSED ==="
log "  Geth branch:        $CURRENT_BRANCH"
log "  Chain head:         block $BLOCK_NUM"
log "  Fork block:         $FORK_BLOCK"
log "  Blocks/period:      $BLOCKS_PER_PERIOD"
log "  Seed period:        $MAX_ACCT_PERIOD (from fixture block $FIXTURE_BLOCK)"
log "  Identify threshold: $IDENTIFY_THRESHOLD (current=$IDENTIFY_CURRENT_PERIOD)"
log "  Inactive subtrees:  $NUM_SUBTREES"
log "  Test directory:     $TEST_DIR"

if [ "$KEEP" = true ]; then
  log "  (Keeping test directory per --keep flag)"
fi
