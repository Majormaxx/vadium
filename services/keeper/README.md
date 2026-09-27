# Vadium keeper

A long-running bot that pays the Vadium hook's per-pool LP insurance reserve out to the pool's in-range LPs.

When a bonded searcher is caught sandwiching, the hook slashes its bond. Part of the slash refunds the victim and the rest lands in that pool's `insuranceReserve`. The reserve does not move on its own: the hook's `drainFlagged(poolId, searchers, maxAmount)` donates it to LPs, and only the address set as `keeper()` may call it. Every searcher passed to `drainFlagged` must still have an active flag (`flaggedUntil(searcher) > block.number`) or the call reverts with `NotFlagged`. This service is that keeper.

## What it does

1. On start it loads the hook address, deploy block and default pool id for `CHAIN_ID` from `generated/deployments.json`, checks that the RPC really is that chain, and reads `keeper()` on the hook. If `keeper()` is not the signer derived from `KEEPER_PRIVATE_KEY`, it logs both addresses and exits with code 1.
2. It scans `Sandwiched` and `Flagged` events from the last checkpoint (or the deploy block on a fresh state file) in `BACKFILL_STEP` block ranges, keeping only each searcher address and its `flaggedUntil`. It then polls the chain head every two seconds and folds in new logs the same way. The state file records the last block whose logs have been folded in, so a restart resumes from there (minus a 64-block margin).
3. Every `DRAIN_INTERVAL_S` seconds it runs a drain tick. The tick reads `paused()`; if the hook is paused it logs that and does nothing else. Otherwise, for every pool in `POOL_IDS`, it reads `insuranceReserve(poolId)`, takes the known flagged addresses whose flag is still active, and if the reserve is at least `MIN_DRAIN` and at least one flag is active it calls `simulateContract` for `drainFlagged(poolId, active, min(reserve, DRAIN_CAP))` and, if the simulation passes, submits it with `writeContract`. The transaction hash, amount and searcher list are logged.
4. It serves Prometheus metrics, a JSON status page and a health endpoint on `METRICS_PORT`.

Flags apply to the whole hook, so the same active set is used for every pool in one tick. Addresses whose flag would expire within three blocks of the tick are left out, so a transaction mined a few blocks after the simulation cannot revert on an expired flag.

## Requirements

Node 24 and pnpm. The hook ABI and deployment records are generated from the Foundry build, so from the repo root run:

```
forge build
node scripts/export-artifacts.mjs
```

That writes `services/keeper/generated/VadiumHook.abi.json` and `services/keeper/generated/deployments.json`. `generated/` is git-ignored; re-run the export after every deploy or hook change. The keeper checks at startup that the functions and events it uses are present in the generated ABI with the expected signatures and refuses to start otherwise.

## Running

```
cd services/keeper
pnpm install
cp .env.example .env     # fill in KEEPER_PRIVATE_KEY
pnpm dev                 # runs src/main.ts with tsx
```

For a production process:

```
pnpm build
pnpm start               # node dist/main.js
```

or under pm2, which restarts the process if it exits:

```
pnpm build
pm2 start ecosystem.config.cjs
pm2 logs vadium-keeper
pm2 stop vadium-keeper
```

The process reads `./.env` itself (variables already set in the environment win), so pm2 needs no env block. Stopping with SIGINT or SIGTERM waits for an in-flight tick, writes the state file and closes the metrics server.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `KEEPER_PRIVATE_KEY` | none, required | 0x-prefixed 32-byte hex key of the address set as `keeper()` on the hook. |
| `CHAIN_ID` | `1301` | `1301` Unichain Sepolia or `130` Unichain mainnet. A deployment record for the chain must exist in `generated/deployments.json`. |
| `RPC_URL` | the chain's public RPC | `https://sepolia.unichain.org` for 1301, `https://mainnet.unichain.org` for 130. |
| `POOL_IDS` | the `poolId` from the deployment record | Comma-separated bytes32 pool ids to drain. |
| `DRAIN_INTERVAL_S` | `3600` | Seconds between drain ticks. The first tick runs at startup. |
| `DRAIN_CAP` | `1000000000` | Largest amount paid out per pool per tick, in bond-token raw units (six decimals, so 1000 tokens). |
| `MIN_DRAIN` | `1000000` | Reserve below this is left alone (one token). Must not exceed `DRAIN_CAP`. |
| `METRICS_PORT` | `9464` | Port for `/metrics`, `/status` and `/healthz`. |
| `STATE_FILE` | `./state.json` | Where flagged addresses and the scan checkpoint are persisted. |
| `START_BLOCK` | the deploy block | First block scanned when there is no usable state file. |
| `BACKFILL_STEP` | `2000` | Blocks per `eth_getLogs` call. Raise it if your RPC allows larger ranges. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. |

The hook address is never configured by hand. It comes from the deployment record for `CHAIN_ID`, so a redeploy only needs a fresh `node scripts/export-artifacts.mjs` and a restart. A state file written for a different hook or chain is ignored and the scan starts over from `START_BLOCK`.

## State file

`STATE_FILE` is JSON: chain id, hook address, `lastBlock` (last block whose logs are folded in) and a map of lowercase searcher address to `flaggedUntil`. It is written to `<file>.tmp` and renamed over the target, so a crash mid-write leaves the previous file intact. Expired flags are pruned on each tick. Deleting the file forces a rescan from `START_BLOCK`; a corrupt file makes the process exit with a message saying so.

## Metrics

`GET /metrics` returns Prometheus text.

| Metric | Type | Meaning |
|---|---|---|
| `vadium_reserve{pool}` | gauge | `insuranceReserve(pool)` at the last tick, bond-token raw units. |
| `vadium_flagged_active{pool}` | gauge | Number of known addresses whose flag was active at the last tick. Same value for every pool since flags are hook-wide. |
| `vadium_drains_total` | counter | `drainFlagged` transactions submitted since the process started. |
| `vadium_drained_total{pool}` | counter | Bond-token raw units paid out since start, using the amount returned by the simulation. |
| `vadium_last_drain_block` | gauge | Block number of the tick that submitted the last drain. |
| `vadium_keeper_balance_wei` | gauge | Native balance of the signer, refreshed each tick. Alert on this before the keeper runs out of gas. |
| `vadium_rpc_errors_total` | counter | Chain calls that failed: reads, head polls, log fetches, simulations and submissions. |
| `vadium_drain_errors_total` | counter | Subset of the above where a `drainFlagged` simulation or submission failed. |
| `vadium_paused` | gauge | 1 while `paused()` on the hook is true. |

Counters reset when the process restarts.

`GET /status` returns JSON with the chain id, hook, signer, pool ids, head block, last scanned block, the full known flag map, the last tick's result (block, paused, active count, drains, errors), totals and the effective drain settings. Big numbers are strings.

`GET /healthz` returns 200 when the process has had a successful chain call within the last two minutes, otherwise 503.

## Logs

One JSON object per line on stdout with `ts`, `level`, `msg` and context fields. Notable messages: `refusing to start` (keeper or chain mismatch), `hook is paused, skipping drain tick`, `nothing to drain`, `drain submitted` (with `hash`), `drain failed`, `flag recorded`, `watch poll failed, will retry`.

## Testing

```
pnpm typecheck
pnpm test
```

The tests are deterministic and make no network calls. They cover `selectDrain` (below min, no active flags, cap applied, reserve smaller than cap), `activeFlagged` block filtering, state round-trip and the temp-file-then-rename write order, exact metrics text, the HTTP routes on an ephemeral port, config parsing and validation, ABI pinning, backfill range bounding and retry, the live poller's coverage tracking and retry, and `runDrainTick` with a fake dependency object: it simulates before writing, skips while paused, skips when nothing is active, records the hash and counters, and counts an RPC error without throwing. When `generated/VadiumHook.abi.json` exists the suite also checks that the compiled ABI still matches the pinned interface.

## Design notes

The live watcher is a small explicit poller on top of `eth_getLogs` instead of viem's `watchContractEvent`. The latter prefers `eth_newFilter` when the RPC accepts it, and public RPCs drop filters; a dropped filter that does not surface as the one error viem recovers from leaves the watcher polling a dead filter while the head moves on. The poller keeps a coverage pointer that only advances after the logs for a range were fetched, so a failed poll delays ingestion but never skips a block, and the pointer is what gets persisted.

The drain amount recorded in metrics is the value `drainFlagged` returns in simulation, which is `min(maxAmount, reserve)` at that moment. The transaction is not awaited in the tick; the next tick's reserve read reflects the outcome, and the hash is in the log line and in `/status`.
