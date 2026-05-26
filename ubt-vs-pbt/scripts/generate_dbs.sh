#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Generate binary trie DBs for ubt and pbt configs.
#
# Phase 1: state-actor produces $TARGET_SIZE DBs (deterministic seed).
# Phase 2: For each DB: start geth → spamoor erc20_bloater → stubs.json → stop.
#
# Both configs share state-actor seed and spamoor seed so the EVM-level
# workload is byte-identical. Only the trie representation differs.
# =============================================================================

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Binary paths (overridable via env)
GETH_UBT_BIN="${GETH_UBT_BIN:-/tmp/bench-bins/geth-ubt}"
GETH_PBT_BIN="${GETH_PBT_BIN:-/tmp/bench-bins/geth-pbt}"
STATE_ACTOR_UBT_BIN="${STATE_ACTOR_UBT_BIN:-/tmp/bench-bins/state-actor-ubt}"
STATE_ACTOR_PBT_BIN="${STATE_ACTOR_PBT_BIN:-/tmp/bench-bins/state-actor-pbt}"
SPAMOOR_BIN="${SPAMOOR_BIN:-/Users/han/Documents/Codes/spamoor/bin/spamoor}"

# Output paths
RESULTS_DIR="${RESULTS_DIR:-$CAMPAIGN_DIR/data}"
DB_BASE="${DB_BASE:-/tmp/ubt-vs-pbt-dbs}"

# Workload knobs
TARGET_SIZE="${TARGET_SIZE:-1GB}"
GROUP_DEPTH="${GROUP_DEPTH:-5}"
STATE_ACTOR_SEED="${STATE_ACTOR_SEED:-25519}"
SPAMOOR_SEED="${SPAMOOR_SEED:-ubt-vs-pbt-smoke}"
SPAMOOR_TARGET_GB="${SPAMOOR_TARGET_GB:-0.1}"
# Number of ERC20 contracts to deploy and bloat. The total SPAMOOR_TARGET_GB is
# split evenly across them; each gets its own deterministic deployer seed
# (${SPAMOOR_SEED}-cN), so the resulting addresses are identical across configs.
NUM_CONTRACTS="${NUM_CONTRACTS:-10}"

# state-actor direct scaling flags (opt-in; only passed when set).
# Without these, state-actor falls back to its defaults (1000 accounts /
# 100 contracts / 1-10000 slots ≈ 1MB base), and -target-size acts as a
# stop condition only — it won't grow the workload past the defaults.
# For prod-scale runs (≥10GB) set these explicitly.
SA_ACCOUNTS="${SA_ACCOUNTS:-}"
SA_CONTRACTS="${SA_CONTRACTS:-}"
SA_MIN_SLOTS="${SA_MIN_SLOTS:-}"
SA_MAX_SLOTS="${SA_MAX_SLOTS:-}"
SA_DISTRIBUTION="${SA_DISTRIBUTION:-}"

# Hardhat default account #0 (state-actor pre-funds via -inject-accounts)
SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PRIVKEY="0x${SEED_KEY}"

# Configs: name | geth | state-actor
CONFIGS=(
  "ubt|$GETH_UBT_BIN|$STATE_ACTOR_UBT_BIN"
  "pbt|$GETH_PBT_BIN|$STATE_ACTOR_PBT_BIN"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

kill_geth() {
  local pids
  pids=$(pgrep -f "geth.*--dev" 2>/dev/null || true)
  if [ -z "$pids" ]; then
    return
  fi
  log "  Killing geth (SIGTERM, waiting up to 120s for journal flush): $pids"
  echo "$pids" | xargs kill -TERM 2>/dev/null || true
  # Poll for clean exit — geth needs to flush the PathDB journal on shutdown,
  # which can take several seconds at 1GB+ scale. SIGKILL too early corrupts
  # the DB. Bound at 120s as a hard fallback.
  local waited=0
  while [ "$waited" -lt 120 ]; do
    local alive=""
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        alive="$alive $pid"
      fi
    done
    if [ -z "$alive" ]; then
      log "  geth exited cleanly after ${waited}s"
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "  WARN: geth did not exit within 120s — sending SIGKILL (journal may be incomplete)"
  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 2
}

# start_geth_for_deploy: cache=4096 for faster ERC20 deployment
start_geth_for_deploy() {
  local geth_bin="$1"
  local datadir="$2"
  local log_file="$3"

  kill_geth
  rm -f "$datadir/geth/chaindata/LOCK" 2>/dev/null || true

  # Import seed key (idempotent — needed so geth's miner can sign deploy txs)
  echo "$SEED_KEY" > /tmp/seed_key.hex
  echo "" | "$geth_bin" --datadir "$datadir" account import --password /dev/stdin /tmp/seed_key.hex 2>/dev/null || true
  rm -f /tmp/seed_key.hex

  log "  [geth] Starting for deployment (cache=4096, dev.period=1)"
  "$geth_bin" \
    --datadir "$datadir" \
    --dev --dev.period 1 --dev.gaslimit 100000000 \
    --miner.etherbase "$SEED_ACCOUNT" \
    --cache 4096 \
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
    > "$log_file" 2>&1 &

  log "  [geth] Waiting for RPC..."
  for i in $(seq 1 120); do
    if curl -s http://localhost:8545 -H "Content-Type: application/json" \
       -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null | grep -q "result"; then
      log "  [geth] RPC ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  log "  [geth] ERROR: RPC not ready after 120s"
  tail -20 "$log_file"
  return 1
}

# =============================================================================
# Preflight
# =============================================================================
log "╔══════════════════════════════════════════════════════════════╗"
log "║  generate_dbs.sh — preflight"
log "╚══════════════════════════════════════════════════════════════╝"

for spec in "${CONFIGS[@]}"; do
  IFS='|' read -r name geth_bin sa_bin <<< "$spec"
  if [ ! -x "$geth_bin" ]; then
    log "ERROR: $geth_bin not found or not executable (config=$name)"
    exit 1
  fi
  if [ ! -x "$sa_bin" ]; then
    log "ERROR: $sa_bin not found or not executable (config=$name)"
    exit 1
  fi
  log "  $name: geth=$geth_bin state-actor=$sa_bin"
done

if [ ! -x "$SPAMOOR_BIN" ]; then
  log "ERROR: spamoor not found at $SPAMOOR_BIN"
  exit 1
fi
log "  spamoor: $SPAMOOR_BIN"

# Free port 8545
if lsof -nP -iTCP:8545 -sTCP:LISTEN >/dev/null 2>&1; then
  log "ERROR: port 8545 in use"
  exit 1
fi

mkdir -p "$DB_BASE" "$RESULTS_DIR/ubt" "$RESULTS_DIR/pbt"

# =============================================================================
# Per-config: generate DB + deploy ERC20 + capture stubs.json
# =============================================================================
for spec in "${CONFIGS[@]}"; do
  IFS='|' read -r name geth_bin sa_bin <<< "$spec"
  db_path="$DB_BASE/$name"
  config_results="$RESULTS_DIR/$name"
  contracts_file="$config_results/contracts.json"
  gen_log="$config_results/state-actor.log"
  deploy_log="$config_results/geth_deploy.log"

  log ""
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Config $name — DB generation + ERC20 deployment"
  log "╚══════════════════════════════════════════════════════════════╝"

  # Skip if contracts already captured (resumable)
  if [ -f "$contracts_file" ]; then
    log "  $contracts_file already exists — skipping (delete to re-run)"
    continue
  fi

  # Phase 1: state-actor builds the base DB
  if [ -d "$db_path" ]; then
    log "  WARN: $db_path exists (incomplete prior run) — removing"
    rm -rf "$db_path"
  fi
  mkdir -p "$db_path"

  # Build state-actor argv, appending opt-in scaling flags only if set
  sa_args=(
    -db "$db_path/geth/chaindata"
    -binary-trie
    -group-depth "$GROUP_DEPTH"
    -target-size "$TARGET_SIZE"
    -inject-accounts "$SEED_ACCOUNT"
    -seed "$STATE_ACTOR_SEED"
    -benchmark
    -verbose
  )
  [ -n "$SA_ACCOUNTS" ]     && sa_args+=(-accounts "$SA_ACCOUNTS")
  [ -n "$SA_CONTRACTS" ]    && sa_args+=(-contracts "$SA_CONTRACTS")
  [ -n "$SA_MIN_SLOTS" ]    && sa_args+=(-min-slots "$SA_MIN_SLOTS")
  [ -n "$SA_MAX_SLOTS" ]    && sa_args+=(-max-slots "$SA_MAX_SLOTS")
  [ -n "$SA_DISTRIBUTION" ] && sa_args+=(-distribution "$SA_DISTRIBUTION")

  log "  [phase1] state-actor: target=$TARGET_SIZE seed=$STATE_ACTOR_SEED gd=$GROUP_DEPTH accounts=${SA_ACCOUNTS:-default} contracts=${SA_CONTRACTS:-default} slots=${SA_MIN_SLOTS:-default}..${SA_MAX_SLOTS:-default}"
  "$sa_bin" "${sa_args[@]}" 2>&1 | tee "$gen_log"

  DB_SIZE=$(du -sh "$db_path/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  STATE_ROOT=$(grep -oE "State root.*0x[0-9a-fA-F]+" "$gen_log" | tail -1 | grep -oE "0x[0-9a-fA-F]+")
  log "  [phase1] DB built: size=$DB_SIZE root=$STATE_ROOT"

  # Phase 2: deploy ERC20 + bloat
  start_geth_for_deploy "$geth_bin" "$db_path" "$deploy_log"

  # Set gas limit and verify seed balance
  curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x5F5E100"],"id":1}' > /dev/null

  BALANCE=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0")
  log "  [phase2] Seed balance: $(python3 -c "print($BALANCE / 1e18)") ETH"
  if [ "$BALANCE" -eq 0 ] 2>/dev/null; then
    log "  ERROR: seed account has no funds on $name"
    kill_geth
    exit 1
  fi

  # Deploy + bloat NUM_CONTRACTS ERC20 contracts. Each spamoor invocation uses a
  # distinct deployer seed (${SPAMOOR_SEED}-cN) → distinct deployer wallet →
  # distinct contract, carrying SPAMOOR_TARGET_GB / NUM_CONTRACTS of the bloat.
  # All run sequentially against this one running geth. The deployer address
  # depends only on (privkey, seed), not the trie backend, so contract N lands
  # at the same address under both configs.
  per_contract_gb=$(python3 -c "print($SPAMOOR_TARGET_GB / $NUM_CONTRACTS)")
  log "  [phase2] Deploying $NUM_CONTRACTS contract(s), ${per_contract_gb}GB each (total ${SPAMOOR_TARGET_GB}GB)"
  declare -a contract_addrs=()
  for c in $(seq 1 "$NUM_CONTRACTS"); do
    c_seed="${SPAMOOR_SEED}-c${c}"
    c_log="$config_results/spamoor_c${c}.log"
    log "    [contract $c/$NUM_CONTRACTS] erc20_bloater (target=${per_contract_gb}GB seed=$c_seed)..."
    "$SPAMOOR_BIN" erc20_bloater \
      --rpchost="http://localhost:8545" \
      --privkey="$PRIVKEY" \
      --seed="$c_seed" \
      --target-gb="$per_contract_gb" \
      --target-gas-ratio=0.8 \
      --wallet-count=200 \
      -v > "$c_log" 2>&1

    addr=$(grep -oE 'contract: 0x[0-9a-fA-F]+' "$c_log" | tail -1 | awk '{print $2}')
    if [ -z "$addr" ]; then
      log "    ERROR: could not extract contract address (contract $c)"
      tail -20 "$c_log"
      kill_geth
      exit 1
    fi

    code_len=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" \
      | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)")
    if [ "$code_len" -eq 0 ] 2>/dev/null; then
      log "    ERROR: contract $c ($addr) has no code"
      kill_geth
      exit 1
    fi
    log "    [contract $c/$NUM_CONTRACTS] deployed at $addr (${code_len} bytes)"
    contract_addrs+=("$addr")
  done

  # Write contracts.json — a JSON array of the N deployed addresses. The
  # benchmark phase selects among these in a fixed seeded order; the stub file
  # execution-specs consumes is built per-contract at benchmark time.
  python3 - "$contracts_file" "${contract_addrs[@]}" <<'PY'
import json, sys
out, addrs = sys.argv[1], sys.argv[2:]
with open(out, "w") as f:
    json.dump(addrs, f, indent=2)
PY
  log "  [phase2] contracts.json written: $contracts_file (${#contract_addrs[@]} contracts)"

  # Graceful geth shutdown to flush PathDB journal
  kill_geth
  log "  [done] $name DB + ERC20 ready"
done

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  generate_dbs.sh — complete"
log "╚══════════════════════════════════════════════════════════════╝"
for spec in "${CONFIGS[@]}"; do
  IFS='|' read -r name _ _ <<< "$spec"
  db_path="$DB_BASE/$name"
  contracts_file="$RESULTS_DIR/$name/contracts.json"
  size=$(du -sh "$db_path/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  ncontracts=$(python3 -c "import json; print(len(json.load(open('$contracts_file'))))" 2>/dev/null || echo "?")
  log "  $name: db=$size contracts=$ncontracts"
done

# Sanity: both configs must derive the identical contract address set, since
# the benchmark replays the same seeded order against both.
if [ -f "$RESULTS_DIR/ubt/contracts.json" ] && [ -f "$RESULTS_DIR/pbt/contracts.json" ]; then
  if diff -q "$RESULTS_DIR/ubt/contracts.json" "$RESULTS_DIR/pbt/contracts.json" >/dev/null; then
    log "  OK: ubt and pbt contracts.json are identical"
  else
    log "  WARN: ubt and pbt contracts.json DIFFER — comparison will not be apples-to-apples"
  fi
fi
