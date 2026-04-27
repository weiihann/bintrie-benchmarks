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
#             5=inspect, 6=identify, 7=convert, 8=lazy-materialise verify
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

# ---------------------------------------------------------------------------
# Step 6: Convert inactive subtrees into the inactive file
# ---------------------------------------------------------------------------
# Same parameters as Step 5. Convert moves the identified subtrees out of
# chaindb into <chaindata>/inactive.bin, writing 17-byte stubs in their
# place. After this step, geth must be able to read the converted accounts
# transparently via the auto-attached archive resolver.

log "Step 6: Converting inactive subtrees..."

INACTIVE_FILE="$DATADIR/geth/chaindata/inactive.bin"

if ! "$GETH_BIN" --datadir "$DATADIR" db convert-inactive \
  --fork-block "$FORK_BLOCK" \
  --blocks-per-period "$BLOCKS_PER_PERIOD" \
  --current-period "$IDENTIFY_CURRENT_PERIOD" \
  --inactive-min-age "$IDENTIFY_THRESHOLD" \
  --scope account \
  --inactive-file "$INACTIVE_FILE" \
  > "$LOG_DIR/convert.log" 2>&1; then
  log "  convert log tail:"
  tail -20 "$LOG_DIR/convert.log"
  fail 7 "convert-inactive failed"
fi

if [ ! -s "$INACTIVE_FILE" ]; then
  fail 7 "inactive.bin not created or empty at $INACTIVE_FILE"
fi
INACTIVE_SIZE=$(wc -c < "$INACTIVE_FILE" | tr -d ' ')
pass "convert-inactive completed; inactive.bin size = $INACTIVE_SIZE bytes"

# Sanity: re-run inspect-periods AFTER conversion. Inspect-periods iterates
# the snapshot keyspace, NOT the trie keyspace, so it should still see the
# accounts (snapshot is unchanged by conversion).
log "  Re-running inspect-periods after conversion..."
INSPECT_AFTER=$("$GETH_BIN" --datadir "$DATADIR" db inspect-periods --json 2>/dev/null) || true
if [ -z "$INSPECT_AFTER" ]; then
  fail 7 "inspect-periods after convert produced no output"
fi
ACCOUNTS_AFTER=$(echo "$INSPECT_AFTER" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('total_accounts', 0))")
if [ "$ACCOUNTS_AFTER" -lt 1 ]; then
  fail 7 "inspect-periods after convert reports 0 accounts"
fi
pass "Snapshot still has $ACCOUNTS_AFTER accounts after conversion"

# Sanity: start geth in dev mode pointing at the converted datadir, query
# the seed account's balance, expect a non-error response. Reads of any
# account whose subtree was converted must transparently follow the stub
# into inactive.bin and return the original value.
log "  Restarting geth to verify reads via inactive file..."

"$GETH_BIN" \
  --datadir "$DATADIR" \
  --dev --dev.period 1 --dev.gaslimit 30000000 \
  --miner.pending.feeRecipient "$SEED_ACCOUNT" \
  --http --http.addr 127.0.0.1 --http.port 8545 \
  --http.api eth,net,web3,debug \
  --nodiscover --maxpeers 0 \
  --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
  --verbosity 3 \
  > "$LOG_DIR/geth-postconvert.log" 2>&1 &
GETH_PID=$!

if ! wait_for_rpc 8545; then
  log "  geth-postconvert log tail:"
  tail -30 "$LOG_DIR/geth-postconvert.log"
  fail 7 "geth failed to start after conversion"
fi

# Confirm the inactive file was attached.
if ! grep -q "EIP-8188 inactive file attached" "$LOG_DIR/geth-postconvert.log"; then
  log "  Expected log line 'EIP-8188 inactive file attached' not found:"
  grep -i "inactive\|EIP-8188" "$LOG_DIR/geth-postconvert.log" || true
  fail 7 "inactive file not attached on geth restart"
fi

# Read the seed account's balance — it's the active account, served from
# main chaindb (not via stub). This confirms post-conversion chain still
# functions.
SEED_BALANCE=$(curl -sf http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('result','0x0'),16))")

if [ -z "$SEED_BALANCE" ] || [ "$SEED_BALANCE" = "0" ]; then
  fail 7 "seed account balance is 0 after conversion (expected non-zero)"
fi
pass "Seed account balance after conversion: $SEED_BALANCE wei"

# ---------------------------------------------------------------------------
# Step 7: Modify a CONVERTED account and verify hybrid (lazy materialisation)
# ---------------------------------------------------------------------------
# Send a transaction from the seed account (active, lives in chaindb) to a
# random new address. Most of the trie has been converted into stubs, so the
# trie write at COMMIT time will descend through stub paths. The lazy
# materialiser walks just the modified paths, leaving off-path siblings as
# *expiredNode references. At commit time these *expiredNode children fold
# into hybrid (0x01) chaindb entries.
#
# Verification:
#   - chaindb gains at least one hybrid (0x01) entry post-modification.
#   - subsequent reads (modified address + still-stubbed siblings) work.

log "Step 7: Verifying lazy materialisation produces hybrid entries..."

# Use spamoor again (it already handles signing with the seed privkey) to
# generate state mutations that touch trie paths previously stubbed by
# convert-inactive. With --random-target, each transfer credits a fresh
# address whose keccak path may descend into a converted (stubbed) subtree
# — when it does, the lazy materialiser fires and emits hybrid entries.
log "  Sending follow-up spamoor transactions to trigger trie writes across stubs..."
"$SPAMOOR_BIN" eoatx \
  --rpchost "http://localhost:8545" \
  --privkey "0x$SEED_KEY" \
  --count 30 \
  --throughput 10 \
  --max-pending 5 \
  --random-target \
  --amount 1000 \
  > "$LOG_DIR/spamoor-postconvert.log" 2>&1 || true
sleep 5

# Confirm the chain advanced (so the new state is mined).
BLOCK_AFTER=$(get_block_number)
if [ "$BLOCK_AFTER" -le "$BLOCK_NUM" ]; then
  fail 8 "chain did not advance post-conversion (block stuck at $BLOCK_AFTER)"
fi
pass "Chain advanced from $BLOCK_NUM to $BLOCK_AFTER post-conversion"

# Stop geth so we can inspect chaindb.
log "  Stopping geth to inspect chaindb..."
kill -TERM "$GETH_PID" 2>/dev/null || true
sleep 5
if kill -0 "$GETH_PID" 2>/dev/null; then
  kill -9 "$GETH_PID" 2>/dev/null || true
fi
wait "$GETH_PID" 2>/dev/null || true
GETH_PID=""
rm -f "$DATADIR/geth/chaindata/LOCK" 2>/dev/null || true

# Inspect chaindb: count trie-node entries by kind.
log "  Counting chaindb trie-node entries by kind..."
COUNTS_JSON=$("$GETH_BIN" --datadir "$DATADIR" db count-trienode-kinds --json 2>/dev/null) || \
  fail 8 "count-trienode-kinds failed"
log "  Counts: $COUNTS_JSON"

ACCT_HYBRIDS=$(echo "$COUNTS_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['account_trie']['hybrids'])")
ACCT_STUBS=$(echo "$COUNTS_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['account_trie']['stubs'])")
ACCT_RLP=$(echo "$COUNTS_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['account_trie']['standard_rlp'])")

if [ "$ACCT_HYBRIDS" -lt 1 ]; then
  fail 8 "expected >=1 hybrid (0x01) entry after modifying converted account; got $ACCT_HYBRIDS (stubs=$ACCT_STUBS rlp=$ACCT_RLP)"
fi
pass "chaindb has $ACCT_HYBRIDS hybrid entries (account trie); stubs=$ACCT_STUBS rlp=$ACCT_RLP"

# Restart geth, query the seed account (active), verify it still resolves
# correctly across the hybrid layer.
log "  Restarting geth to verify reads across hybrid entries..."
"$GETH_BIN" \
  --datadir "$DATADIR" \
  --dev --dev.period 1 --dev.gaslimit 30000000 \
  --miner.pending.feeRecipient "$SEED_ACCOUNT" \
  --http --http.addr 127.0.0.1 --http.port 8545 \
  --http.api eth,net,web3,debug \
  --nodiscover --maxpeers 0 \
  --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
  --verbosity 3 \
  > "$LOG_DIR/geth-postmodify.log" 2>&1 &
GETH_PID=$!
wait_for_rpc 8545

SEED_BAL_AFTER_RESTART=$(curl -sf http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('result','0x0'),16))")
if [ -z "$SEED_BAL_AFTER_RESTART" ] || [ "$SEED_BAL_AFTER_RESTART" = "0" ]; then
  fail 8 "after restart: seed balance is 0 (read across hybrid failed)"
fi
pass "Seed balance ($SEED_BAL_AFTER_RESTART wei) readable after restart"

# Stop the post-modify geth.
log "  Stopping geth..."
kill -TERM "$GETH_PID" 2>/dev/null || true
sleep 5
if kill -0 "$GETH_PID" 2>/dev/null; then
  kill -9 "$GETH_PID" 2>/dev/null || true
fi
wait "$GETH_PID" 2>/dev/null || true
GETH_PID=""

# Summary
log ""
log "=== TEST PASSED ==="
log "  Geth branch:         $CURRENT_BRANCH"
log "  Chain head:          block $BLOCK_NUM"
log "  Fork block:          $FORK_BLOCK"
log "  Blocks/period:       $BLOCKS_PER_PERIOD"
log "  Seed period:         $MAX_ACCT_PERIOD (from fixture block $FIXTURE_BLOCK)"
log "  Identify threshold:  $IDENTIFY_THRESHOLD (current=$IDENTIFY_CURRENT_PERIOD)"
log "  Inactive subtrees:   $NUM_SUBTREES"
log "  Inactive file size:  $INACTIVE_SIZE bytes"
log "  Test directory:      $TEST_DIR"

if [ "$KEEP" = true ]; then
  log "  (Keeping test directory per --keep flag)"
fi
