# Vadium indexer

A Ponder app that indexes the Vadium hook on Unichain Sepolia (chain 1301) or Unichain mainnet (130) and serves the numbers the frontend dashboard reads over plain HTTP.

## What it indexes

Hook events, from the deploy block in `generated/deployments.json`: `PoolRegistered`, `Bonded`, `BondWithdrawn`, `Sandwiched`, `VictimRefundCredited`, `RefundClaimed`, `UnclaimedSwept`, `Flagged`, `CoverageClaimed`, `Checkpointed`, `ClampWithheld`, `WithheldFlushed`. From the PoolManager it reads `Swap`, filtered by pool id to the deployment's pool plus any ids in `POOL_IDS`; swaps for pools the hook never registered are dropped.

Tables (`ponder.schema.ts`): `pool` with running counters (reserve, slashed pledged, withdrawn, sandwiches, refunds credited and claimed, withheld per currency, last checkpoint), `bond` per searcher (amount, strikes, banned until, flagged until), and one row per event in `slash`, `refund`, `flag`, `drain`, `withheld`, `flush`, `checkpoint`, `swap`. `block_price` holds, per pool and block, the block-start sqrt price from `Checkpointed` and the end sqrt price from the last `Swap` in that block; the staleness metric is computed from it.

Counter rules follow the contract: a sandwich credits `slashed - refunded` to the pool reserve; a watchtower flag with a slash credits the whole slash; `CoverageClaimed` sets the reserve to `remainingReserve` and adds to `withdrawn`; `UnclaimedSwept` credits the target pool. A strike is counted on every `Sandwiched` and on every `Flagged` with `slashed > 0`. A repeat sandwich bans the searcher until `flaggedUntil`. `RefundClaimed` marks every open refund row for the victim as claimed and adds each row's amount to its pool's `refundsClaimed`; a sweep marks them swept instead, so `claimed` stays false.

The event to row mapping is pure code in `src/mappers.ts`; `src/index.ts` only wires it to Ponder. `src/staleness.ts` holds the percentile and price math.

## Run

Requires Node 22 or later and pnpm. From the repo root, build the contracts and export the artifacts once (again after any redeploy):

```
forge build
node scripts/export-artifacts.mjs
```

That writes `services/indexer/generated/VadiumHook.abi.json` and `deployments.json`. The hook address, PoolManager address, pool id and start block all come from that file; nothing is hardcoded. Then:

```
cd services/indexer
pnpm install
pnpm dev
```

`pnpm dev` starts Ponder with hot reload, `pnpm start` runs it for production, `pnpm codegen` refreshes `ponder-env.d.ts`, `pnpm typecheck` runs `tsc --noEmit`, `pnpm test` runs the vitest suites. `dev`, `start` and `codegen` first run `scripts/abi.mjs`, which turns `generated/VadiumHook.abi.json` into `generated/VadiumHook.abi.ts` (the `as const` copy of the ABI that `ponder.config.ts` imports), so a fresh export is always picked up. `pnpm abi` runs that step alone.

The database is the embedded PGlite under `.ponder/` unless `DATABASE_URL` is set. The HTTP server listens on port 42069 by default and moves to the next free port when that one is taken (the log line `Created HTTP server port=...` says which).

## Environment

Copy `.env.example` to `.env.local`.

| Variable | Default | Meaning |
|---|---|---|
| `CHAIN_ID` | `1301` | Active chain, 1301 or 130. Needs a record in `generated/deployments.json`. |
| `PONDER_RPC_URL_1301` | `https://sepolia.unichain.org` | Unichain Sepolia RPC. |
| `PONDER_RPC_URL_130` | `https://mainnet.unichain.org` | Unichain mainnet RPC. |
| `POOL_IDS` | empty | Extra pool ids (comma separated) whose PoolManager swaps are fetched, beyond the deployment's pool. |
| `DATABASE_URL` | unset | Postgres connection string. Unset means PGlite. |
| `PORT` | `42069` | HTTP port. |

The public RPCs work for development but their load-balanced nodes sometimes answer `BlockNotFoundError` for the newest block; Ponder retries and continues. Use a dedicated endpoint for anything that runs unattended.

## API

All uint256 values are decimal strings. Block numbers and timestamps are JSON numbers. Addresses and pool ids are lower-case hex. Every response carries `Access-Control-Allow-Origin: *`. Unknown pool ids answer `404 {"error":"pool not found"}`; a malformed searcher address answers `400 {"error":"invalid address"}`. `limit` and `window` fall back to their defaults on junk input and are capped at 500 and 10000.

`GET /pools` returns every registered pool.

```
{"pools":[{"poolId":"0x3f02e4e1ac6b345b44b5c816aee451d7a632ffc58d76cbefbdcc348cdc31feb1","chainId":1301,"currency0":"0x0000000000000000000000000000000000000000","currency1":"0x31d0220469e10c4e71834a79b1f276d740d3768f","fee":3000,"tickSpacing":10,"reserve":"0","slashedPledged":"0","withdrawn":"0","sandwiches":0,"refundsCredited":"0","refundsClaimed":"0","withheld0":"0","withheld1":"0","lastCheckpoint":null,"bondedCount":0}]}
```

`lastCheckpoint` is `{blockNumber, sqrtPriceX96, liquidity}` once the pool has seen a `Checkpointed` event. `bondedCount` is the number of addresses with a live bond; bonds are hook-wide, so it is the same for every pool.

`GET /pools/:id` returns the same summary plus `staleness` over the default window of 1000.

```
{"poolId":"0x3f02...feb1","chainId":1301, ...same fields..., "bondedCount":0,"staleness":{"window":1000,"count":0,"p50":null,"p95":null,"mean":null,"series":[]}}
```

`GET /pools/:id/slashes?limit=50` returns slashes, newest first.

```
{"items":[{"txHash":"0x...","blockNumber":63625900,"timestamp":1790478300,"searcher":"0x...","slashed":"500000000","isRepeat":false,"remaining":"500000000","flaggedUntil":"63626900","refunded":"120000000"}]}
```

`GET /pools/:id/refunds?limit=50` returns victim refund credits, newest first. `claimed` is true once the victim called `claimRefund`.

```
{"items":[{"txHash":"0x...","blockNumber":63625900,"victim":"0x...","searcher":"0x...","amount":"120000000","claimed":false}]}
```

`GET /pools/:id/bonded` returns every address with a bond amount above zero, largest first.

```
{"items":[{"searcher":"0x...","amount":"1000000000","depositBlock":"63625500","strikeCount":0,"bannedUntil":"0","flaggedUntil":"0"}]}
```

`GET /pools/:id/withheld?limit=50` returns clamp withholdings, newest first.

```
{"items":[{"txHash":"0x...","blockNumber":63625910,"sender":"0x...","currency":"0x0000000000000000000000000000000000000000","amount":"1234"}]}
```

`GET /pools/:id/staleness?window=1000` measures how far the pool price moved inside a block. For each of the last `window` blocks that had both a checkpoint and a swap, `deviation = |priceEnd - priceStart| / priceStart` with `price = (sqrtPriceX96 / 2^96)^2`, computed in floating point. `p50`, `p95` (linear interpolation between ranks) and `mean` are taken over those deviations and are `null` when `count` is 0. All four are plain fractions: 0.0012 means 0.12 percent. `series` is ascending by block and limited to the last 200 entries.

```
{"window":1000,"count":2,"p50":0.00105,"p95":0.001995,"mean":0.00105,"series":[{"blockNumber":63625900,"startSqrtPriceX96":"79228162514264337593543950336","endSqrtPriceX96":"79236085330515764027303304731","deviation":0.0002},{"blockNumber":63625904,"startSqrtPriceX96":"79228162514264337593543950336","endSqrtPriceX96":"79307390941609523052180224135","deviation":0.002}]}
```

`GET /searchers/:address` returns the bond (or `null`), the searcher's slashes and flags, newest first, up to 500 each.

```
{"searcher":"0x4e36ee389458856e79945a07bf1be36261e7b6a2","bond":null,"slashes":[],"flags":[]}
```

`flags[]` entries are `{txHash, blockNumber, poolId, slashed, evidenceHash, flaggedUntil}`. A flag relayed from another chain carries the zero pool id.

`GET /indexer/status` reports indexing progress. `headBlock` and `lag` are `null` when the RPC call for the head fails.

```
{"chainId":1301,"indexedBlock":63625657,"headBlock":63625657,"hook":"0x67d06225c8081fc19f4e2722a45a4cec0e9320c4","lag":0}
```

Ponder reserves `GET /status`, `/health`, `/ready` and `/metrics` and answers them before any app route, so the app-level status is served at `/indexer/status`. Ponder's own `/status` answers `{"unichainSepolia":{"id":1301,"block":{"number":...,"timestamp":...}}}`.

## How the frontend consumes it

The frontend reads the base URL from its own environment (for local development `http://localhost:42069`) and polls `GET /pools` and `GET /pools/:id` for the dashboard cards, `GET /pools/:id/slashes`, `/refunds`, `/bonded` and `/withheld` for the tables, `GET /pools/:id/staleness` for the deviation chart (multiply the fractions by 100 to show percent), `GET /searchers/:address` for the connected wallet's bond state, and `GET /indexer/status` for the sync indicator. Numbers arrive as strings so the client parses them with `BigInt` before formatting.

## Tests

`pnpm test` runs four vitest suites with no network and no Ponder runtime: `test/staleness.test.ts` (price conversion at 2^96 and 2 * 2^96, deviation, percentiles for empty, single, odd and even inputs, series limiting), `test/mappers.test.ts` (a fixture for every event, the derived pool and bond counters, repeat bans, refund claim and sweep marking), `test/dto.test.ts` (JSON shapes, string encoding, limit parsing) and `test/chains.test.ts` (chain selection, RPC override, deployment validation).
