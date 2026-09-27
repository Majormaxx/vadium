# Vadium status site

Read-only web view of the Vadium hook: the pools it protects, their insurance reserves, bonded searchers, slashes, victim refunds, and withheld gains. Nothing on the site signs or sends a transaction. It reads from an indexer for history and from the chain directly for live totals, so the live numbers stay up when the indexer is down.

## Pages

| Path | Shows |
|---|---|
| `/` | Every registered pool: pair, fee, reserve, sandwiches caught, refunds credited and claimed, withheld totals, last checkpoint. A strip above the table gives the indexed block, head block, indexer lag, and whether the hook is paused. |
| `/pool/[poolId]` | One pool: reserve, slashed pledged, withdrawn, last checkpoint with the implied price, a staleness card (p50, p95, mean, and a sparkline of per-block drift), then tables of slashes, refunds, bonded addresses, and withheld events, with a short explanation of each number. |
| `/searcher/[address]` | One router address: bond amount, deposit block, strikes, ban and flag expiry, whether it is currently exempt from the clamp, any claimable refund credit, slash history, and watchtower flags. |
| `/mechanism` | Plain prose on the clamp, the exemption, the slash, the withheld gains, and the disclosed limits, with links to the repository docs. |
| `/status` | The indexer's `/status` JSON, a live read of `paused`, `totalBonded`, `totalReserve`, `totalClaimable`, and `insuranceReserve(poolId)` from the hook, and the deployment record for the configured chain. |

When the indexer cannot be reached, each page shows an "Indexer unavailable" notice and keeps the numbers it can read from the chain. Invalid pool ids and addresses return a 404.

## Environment

Copy `.env.example` to `.env.local` and adjust. All variables are optional; the defaults point at a local indexer and Unichain Sepolia.

| Variable | Default | Meaning |
|---|---|---|
| `NEXT_PUBLIC_INDEXER_URL` | `http://localhost:42069` | Base URL of the indexer API. |
| `NEXT_PUBLIC_CHAIN_ID` | `1301` | Chain for on-chain reads. `1301` is Unichain Sepolia, `130` is Unichain. |
| `NEXT_PUBLIC_RPC_URL` | `https://sepolia.unichain.org` | JSON-RPC endpoint for that chain. |
| `NEXT_PUBLIC_HOOK_ADDRESS` | from `src/generated/deployments.json` | Overrides the hook address. Needed when the build has no generated deployment record. |
| `NEXT_PUBLIC_SITE_URL` | Vercel's production URL, else `http://localhost:3000` | Absolute base for Open Graph image links. |

Environment is read at request time, not at build time. Changing a variable on the host takes effect on the next request without a rebuild.

## Generated files

Two directories are produced by scripts and ignored by git.

`src/generated/` holds `VadiumHook.abi.json`, `VadiumReactive.abi.json`, and `deployments.json`, written by the repository's `scripts/export-artifacts.mjs` from the forge build output and the `deployments/` records. Run `pnpm abis` from this directory after `forge build` at the repo root. The command also runs `scripts/check-abi.mjs`, which fails if a function signature used in `src/lib/onchain.ts` no longer matches the hook's ABI. The site only needs `deployments.json` at runtime, and reads it with `fs` on each request, so a redeploy that rewrites the file is picked up without a rebuild. If the file is missing the site still builds and runs; set `NEXT_PUBLIC_HOOK_ADDRESS` so the chain reads have a target.

`public/brand/` holds the logo in SVG and PNG plus the favicons, rendered from `brand-src/` by `pnpm brand`. The header and the page icons reference these files, so run the export once after installing.

## Run locally

```
pnpm install
pnpm brand
pnpm abis        # needs forge build output at the repo root; optional
pnpm dev
```

The dev server listens on http://localhost:3000. Point `NEXT_PUBLIC_INDEXER_URL` at a running indexer to see history; without one the pages show the chain reads only.

## Test

```
pnpm typecheck   # tsc --noEmit
pnpm test        # vitest, test/*.test.ts
pnpm build       # next build
```

The unit tests cover `src/lib/format.ts` (fixed-point formatting, percent helpers, block distance, address shortening, sqrtPriceX96 to price), `src/lib/staleness.ts` (sparkline path generation, deviation formatting), and `src/lib/api.ts` (every route parsed from fixture JSON through an injected `fetch`, with 404, HTTP error, network failure, and malformed body each mapped to a typed result). They make no network calls and run in well under two seconds.

The build never contacts the indexer or the RPC. Every data page is server-rendered on demand.

## Deploy on Vercel

1. Import the repository and set the root directory to `frontend`.
2. Framework preset Next.js, install command `pnpm install`, build command `pnpm brand && pnpm build`.
3. Set `NEXT_PUBLIC_INDEXER_URL` to the public indexer, and `NEXT_PUBLIC_HOOK_ADDRESS` to the hook, because the Vercel checkout has no forge artifacts and therefore no `src/generated/deployments.json`. Set `NEXT_PUBLIC_CHAIN_ID` and `NEXT_PUBLIC_RPC_URL` if the target is not Unichain Sepolia through the public RPC.
4. Deploy. The status page confirms both data sources: the indexer block under "Indexer" and the RPC head under "Hook on chain".

If you would rather ship the deployment record than an env var, run `pnpm abis` locally and commit a copy of `deployments.json` outside `src/generated/`, then point `src/lib/chain.ts` at it. The default keeps generated files out of git.

## Layout

```
src/app/            pages (app router, server components only)
src/components/     header, footer, stat cards, responsive table, sparkline, links
src/lib/api.ts      typed indexer client returning ApiResult instead of throwing
src/lib/chain.ts    chain definitions, deployment lookup, explorer links, token labels
src/lib/onchain.ts  viem reads of the hook
src/lib/format.ts   number, percent, block, address, and price formatting
src/lib/staleness.ts sparkline path and deviation formatting
scripts/            brand export and ABI drift check
test/               vitest suites for the three lib modules
```

The staleness figures (`p50`, `p95`, `mean`, and each series point's `deviation`) are treated as basis points, so a value of `12` renders as `0.12%`.
