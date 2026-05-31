#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Generate binary trie DBs for ubt and pbt configs.
#
# Phase 1: state-actor produces $TARGET_SIZE DBs (deterministic seed).
# Phase 2: For each DB: start geth → factorydeploytx (CREATE2 getters) → contracts.json → stop.
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
UV="${UV:-$(command -v uv 2>/dev/null || echo uv)}"
# Number of scattered target (getter) contracts to deploy via the CREATE2
# factory. Addresses are deterministic (salts 0..N-1), identical across configs.
# A matching count of empty-code "account" contracts is also deployed at salts
# NUM_CONTRACTS..2*NUM_CONTRACTS-1 for the account-zone benchmarks.
NUM_CONTRACTS="${NUM_CONTRACTS:-10}"
# Number of stems the getter constructor pre-populates (one slot 0 SSTORE per
# stem at stride 256). T_TOUCHES in the locality_sweep test must be ≤ NUM_STEMS
# so K=1 sloads always hit populated slots.
NUM_STEMS="${NUM_STEMS:-256}"
# Initcodes (hex 0x...) are generated at runtime from build_initcode.py so the
# bytecode and the per-stem SSTORE count stay in lockstep.
GETTER_INITCODE=$(python3 "$CAMPAIGN_DIR/scripts/build_initcode.py" getter "$NUM_STEMS")
ACCOUNT_INITCODE=$(python3 "$CAMPAIGN_DIR/scripts/build_initcode.py" empty)
# spamoor factorydeploytx default --gaslimit is 4M, which underfunds the
# getter constructor at NUM_STEMS≥256 (~5.7M needed). Size both deploys for
# the worst case + headroom; empty-account deploy stays well under either way.
GETTER_DEPLOY_GAS="${GETTER_DEPLOY_GAS:-$(( NUM_STEMS * 23000 + 200000 ))}"
ACCOUNT_DEPLOY_GAS="${ACCOUNT_DEPLOY_GAS:-200000}"

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

  accounts_file="$config_results/accounts.json"

  # ── Deploy 1: getter contracts (storage benchmarks) ──────────────────────
  # NUM_CONTRACTS getters via CREATE2 (salts 0..N-1). Each getter's runtime
  # accepts [slot,value,isWrite]; its constructor pre-populates NUM_STEMS stems
  # (slot=stem_idx*256 ← 1) so cold SLOADs always hit populated slots.
  getter_log="$config_results/factorydeploy_getter.log"
  log "  [phase2] Deploying $NUM_CONTRACTS getter contracts (NUM_STEMS=$NUM_STEMS pre-populated stems, gas=$GETTER_DEPLOY_GAS)"
  "$SPAMOOR_BIN" factorydeploytx \
    --rpchost="http://localhost:8545" \
    --privkey="$PRIVKEY" \
    --count="$NUM_CONTRACTS" \
    --init-code="$GETTER_INITCODE" \
    --start-salt=0 \
    --gaslimit="$GETTER_DEPLOY_GAS" \
    -v > "$getter_log" 2>&1

  FACTORY=$(grep -oE "CREATE2 factory at: 0x[0-9a-fA-F]{40}" "$getter_log" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}")
  if [ -z "$FACTORY" ]; then
    log "    ERROR: getter deploy: could not extract CREATE2 factory address"
    tail -20 "$getter_log"
    kill_geth
    exit 1
  fi
  log "    factory=$FACTORY — computing $NUM_CONTRACTS getter CREATE2 addresses"
  "$UV" run --with "eth-hash[pycryptodome]" python \
    "$CAMPAIGN_DIR/scripts/compute_create2_addresses.py" \
    "$FACTORY" "$GETTER_INITCODE" "$NUM_CONTRACTS" "$contracts_file" 0 2>&1 | tee -a "$getter_log"

  sample=$(python3 -c "import json; print(json.load(open('$contracts_file'))[0])")
  code_len=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$sample\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)")
  if [ "$code_len" -eq 0 ] 2>/dev/null; then
    log "    ERROR: sample getter $sample has no code (deploy/address mismatch)"
    kill_geth
    exit 1
  fi
  log "    [getter] $NUM_CONTRACTS deployed, sample $sample (${code_len} bytes)"

  # ── Deploy 2: empty-code accounts (account-zone benchmarks) ──────────────
  # Same CREATE2 factory + 5-byte init code that returns a 0-byte runtime → the
  # deployed address exists in basic-data with no code/storage. Used as targets
  # for BALANCE and value-transfer benchmarks so the touch lands purely in the
  # account zone. Salts start at NUM_CONTRACTS to avoid colliding with the
  # getter address set.
  account_log="$config_results/factorydeploy_account.log"
  ACCOUNT_START_SALT="$NUM_CONTRACTS"
  log "  [phase2] Deploying $NUM_CONTRACTS empty-code accounts (start salt=$ACCOUNT_START_SALT, gas=$ACCOUNT_DEPLOY_GAS)"
  "$SPAMOOR_BIN" factorydeploytx \
    --rpchost="http://localhost:8545" \
    --privkey="$PRIVKEY" \
    --count="$NUM_CONTRACTS" \
    --init-code="$ACCOUNT_INITCODE" \
    --start-salt="$ACCOUNT_START_SALT" \
    --gaslimit="$ACCOUNT_DEPLOY_GAS" \
    -v > "$account_log" 2>&1

  ACCOUNT_FACTORY=$(grep -oE "CREATE2 factory at: 0x[0-9a-fA-F]{40}" "$account_log" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}")
  if [ -z "$ACCOUNT_FACTORY" ]; then
    log "    ERROR: account deploy: could not extract CREATE2 factory address"
    tail -20 "$account_log"
    kill_geth
    exit 1
  fi
  "$UV" run --with "eth-hash[pycryptodome]" python \
    "$CAMPAIGN_DIR/scripts/compute_create2_addresses.py" \
    "$ACCOUNT_FACTORY" "$ACCOUNT_INITCODE" "$NUM_CONTRACTS" "$accounts_file" "$ACCOUNT_START_SALT" \
    2>&1 | tee -a "$account_log"

  sample_account=$(python3 -c "import json; print(json.load(open('$accounts_file'))[0])")
  # Empty-account: code length should be EXACTLY 1 byte (a single STOP). 1 byte is
  # the minimum that satisfies execution-specs' address-stubs validator (which
  # rejects zero-code stubs unless they're EOAs); a STOP runtime adds at most one
  # code-chunk read per CALL — equally paid by UBT and PBT.
  acode_len=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$sample_account\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)")
  if [ "$acode_len" -ne 1 ] 2>/dev/null; then
    log "    ERROR: sample account $sample_account has ${acode_len}B code (expected 1)"
    kill_geth
    exit 1
  fi
  ncontracts=$(python3 -c "import json; print(len(json.load(open('$contracts_file'))))")
  naccounts=$(python3 -c "import json; print(len(json.load(open('$accounts_file'))))")
  log "  [phase2] both sets written: $ncontracts getters + $naccounts empty accounts"

  # Graceful geth shutdown to flush PathDB journal
  kill_geth
  log "  [done] $name DB + getters ready"
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
if [ -f "$RESULTS_DIR/ubt/accounts.json" ] && [ -f "$RESULTS_DIR/pbt/accounts.json" ]; then
  if diff -q "$RESULTS_DIR/ubt/accounts.json" "$RESULTS_DIR/pbt/accounts.json" >/dev/null; then
    log "  OK: ubt and pbt accounts.json are identical"
  else
    log "  WARN: ubt and pbt accounts.json DIFFER — account benchmarks would diverge"
  fi
fi
