# Integration Test

Validates the binary trie benchmark pipeline at 1GB scale (vs 400GB in production). Mirrors `generate_dbs.sh` + `run_erc20_benchmarks.sh` in a temp directory with automatic cleanup.

## Quick start

```bash
bash integration-test/run.sh
```

Missing binaries are built automatically from sibling repos.

## What it tests

| Stage | What | Validates |
|:------|:-----|:----------|
| 1 | state-actor generates 1GB binary trie DB | Non-zero state root, DB has reasonable size |
| 2 | geth opens DB, spamoor deploys ERC20 | RPC responds, seed account funded, contract deployed with code |
| 3 | geth restarts on same DB | No corruption: balance, contract code, and state root persist |

## Configuration

| Variable | Default | Purpose |
|:---------|:--------|:--------|
| `GROUP_DEPTH` | `5` | Binary trie group depth |
| `TARGET_SIZE` | `1GB` | state-actor DB size target |
| `SPAMOOR_TARGET_GB` | `0.01` | ERC20 bloater storage target |
| `GETH_BIN` | auto-detect | Path to geth binary |
| `STATE_ACTOR` | auto-detect | Path to state-actor binary |
| `SPAMOOR_BIN` | auto-detect | Path to spamoor binary |
| `GENESIS` | auto-detect | Path to genesis.json |

```bash
GROUP_DEPTH=6 bash integration-test/run.sh
bash integration-test/run.sh --keep    # preserve test dir on success
```

## Prerequisites

The script expects sibling repos at `../go-ethereum`, `../state-actor`, `../spamoor` (relative to `bintrie-benchmarks/`). It builds missing binaries automatically.

Required branches:
- go-ethereum: `binary/pbt`
- state-actor: `pbt`
- spamoor: `master`

## Debugging failures

On failure, the test directory is preserved. Check:
- `state-actor.log` -- DB generation output and state root
- `geth-deploy.log` -- geth logs during ERC20 deployment
- `geth-restart.log` -- geth logs during restart validation
- `spamoor.log` -- ERC20 deployer output and contract address

## Exit codes

| Code | Meaning |
|:-----|:--------|
| 0 | All stages passed |
| 1 | Preflight failure (binary not found, genesis missing, port in use) |
| 2 | Stage 1: DB generation failed |
| 3 | Stage 2: geth startup or ERC20 deployment failed |
| 4 | Stage 3: restart validation failed (possible DB corruption) |
