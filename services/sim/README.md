# Vadium sim

A scenario runner that produces real on-chain evidence for the Vadium hook on Unichain Sepolia. It deploys one `SimSwapRouter` per actor, bonds some of them, and submits scripted sandwich sequences so the indexer and dashboard show caught sandwiches, victim refunds, and withheld (clamped) swaps before any external traffic exists. Every run first writes a plan file that lists each transaction, and nothing is broadcast unless `--execute` is passed.

## What it exercises

The hook clamps unbonded flow to the block-start price: a swap that does better than the price the pool offered at the start of its block has the gain withheld (`ClampWithheld`). A bonded address is exempt on its first swap of a block and trades at the real price. If a bonded address swaps, a different address then swaps and gets a worse price than block start, and the bonded address reverses direction in the same block, the hook slashes the bond (`Sandwiched`) and credits the victim a refund (`VictimRefundCredited`).

Each actor is a `SimSwapRouter` (`app/script/SimSwapRouter.sol`) owned by the sim key. The hook sees the router as the swapper, so one router is one accountable identity. Inputs come from the owner (native ETH via `msg.value`, USDC via `transferFrom`) and outputs go back to the owner, so the only money that stays out is what the hook withholds or slashes.

## Scenarios

`unbonded-sandwich`. Router A (unbonded) sells ETH, router V sells ETH, A buys ETH back, all in one block. Expected: no `Sandwiched` (there is no bond to slash), `ClampWithheld` on A's back-run, and A's round trip is not profitable once the withheld amount is subtracted. This shows the clamp alone defeats a plain sandwich.

`unbonded-mule`. Same front-run and victim, but a third unbonded router M does the back-run. Expected: `ClampWithheld` on M and no `Sandwiched`. This shows the clamp works per swap, so splitting the legs across addresses gains nothing.

`bonded-sandwich`. Router A bonds `minBond` in a separate transaction; after the next block A sells ETH (exempt, real price), V sells ETH with `hookData` naming the sim owner as refund recipient, A buys back. Expected: A is exempt going in, `Sandwiched` names A, `VictimRefundCredited` names the sim owner, the owner's claimable refund and the pool's insurance reserve both grow, A's bonded balance falls, and A's back-run is also withheld because the exemption covers only the first swap of a block. This is the slash path end to end.

`bonded-arb-follower`. Router B bonds, then B sells ETH (exempt) and an unbonded router F buys ETH in the same block. Expected: `ClampWithheld` on F, nothing withheld from B, no `Sandwiched`. This shows bonded arbitrage moves the price while unbonded followers are held to block start.

Each scenario is a pure function in `src/scenarios.ts` that returns the ordered calls and the expectations; the runner checks the expectations from receipts and from state read before and after the batch.

## Same-block submission

Unichain Sepolia produces a block every second, so the legs of a scenario must reach the sequencer together. The runner signs every batch leg up front with consecutive nonces from the sim key (the key owns every router, and `SimSwapRouter.swap` is owner-only), then sends the raw transactions back to back without waiting for receipts. Gas is a fixed limit (`SWAP_GAS_LIMIT`) and is not estimated, because the later legs cannot be estimated against state the earlier legs have not produced yet.

After the receipts arrive the runner checks that every batch leg shares one block number. When they do not, the report's `same-block` expectation fails and `needsRetry` is set; the other expectations still run but are not meaningful for that attempt. Rerun the scenario. Setup steps (bonding) are sent alone, confirmed, and followed by a wait for the next block so the batch starts on a clean block.

A bonded router that has been slashed is flagged and no longer exempt. Rerunning `bonded-sandwich` with the same router A would be slashed again as a repeat offense and would not reproduce the first-strike evidence, so the runner refuses when a bonded role is not exempt and tells you to remove that role from `routers.json`; the next `--execute` deploys a fresh router for it.

## Running

```
pnpm install
pnpm artifacts            # after `forge build` at the repo root
cp .env.example .env      # set SIM_PRIVATE_KEY (or SIM_ADDRESS for read-only)
pnpm plan --liquidity 20000000   # offline plan, no RPC
pnpm run run              # online dry run: preflight, sizing, plan file, no transactions
pnpm run run --execute    # deploy routers, approve, bond, run the batches, write reports
```

`pnpm artifacts` runs the repo's `scripts/export-artifacts.mjs` (hook ABI and deployment records) and copies `out/SimSwapRouter.sol/SimSwapRouter.json` into `generated/`. The hook address, PoolManager, pool key, pool id, and bond token are always read from `generated/deployments.json` for `CHAIN_ID`; nothing is hardcoded.

The offline plan takes `--liquidity <raw>`, `--sqrt-price <sqrtPriceX96>` (default 2^96, a 1:1 raw price), `--lp-fee <pips>` (default from the pool key), and `--min-bond <raw>` (default 100000000). The online plan and the dry run read all of these from the chain.

The dry run runs the same preflight as an execute: the RPC's chain id matches, the hook has code and answers the clamp views (an older deployment fails here with a redeploy hint), the pool is registered, liquidity is non-zero (otherwise it prints the `make add-liquidity` hint), and the owner's USDC and ETH cover the planned inputs, bonds, and gas headroom. It then lists which routers would be deployed and which bonds posted, and writes the plan file. Only `--execute` sends anything.

Execute deploys any router missing from `routers.json` (written after each deployment, so a crash never loses an address), approves USDC once per router, then runs the selected scenarios in order. Each scenario writes its own report and a failure in one does not stop the next. The process exits non-zero when any scenario failed or was aborted.

Two maintenance commands exist for the money the scenarios leave behind. `tsx src/cli.ts withdraw-bond --role B` reports a router's bond and maturity block and withdraws it with `--execute` once `minBondDurationBlocks` have passed (a struck bond is locked for `firstOffenseLockExtensionBlocks` more). `tsx src/cli.ts claim-refund` reports the sim owner's claimable refund and claims it with `--execute`; the bonded-sandwich victim names the owner EOA in `hookData`, so the credit is claimable straight from the hook.

## Sizing

Amounts come from live liquidity. With in-range liquidity L and sqrt price P, the virtual reserves of a full-range position are L/P of ETH and L*P of USDC. Each leg moves `SWAP_FRACTION_BPS` of the reserve on its input side (default 5%), which is enough price impact for the clamp and the victim loss to be visible without draining a thin pool. The legs are then capped so that every leg of the selected scenarios fits `ETH_BUDGET_WEI` and `USDC_BUDGET`. The attacker's back-run spends about what its front-run returned (constant-product estimate after the fee). Bonds are sized by the hook's `minBond` and sit outside the swap budgets; the dry run reports the total USDC required including them.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | `https://sepolia.unichain.org` | JSON-RPC endpoint |
| `CHAIN_ID` | `1301` | Deployment record to use |
| `SIM_PRIVATE_KEY` | unset | Owner of every router; required for `--execute` |
| `SIM_ADDRESS` | unset | Read-only owner for plans and dry runs without a key |
| `USDC_BUDGET` | `20000000` | Raw USDC the selected scenarios may spend on swap inputs |
| `ETH_BUDGET_WEI` | `1000000000000000` | Wei the selected scenarios may spend on swap inputs |
| `SWAP_FRACTION_BPS` | `500` | Fraction of the virtual reserve each leg moves |
| `SCENARIOS` | all four | Comma-separated subset to run |
| `SWAP_GAS_LIMIT` | `1500000` | Gas limit per batch leg |

`--scenarios a,b` on the command line overrides `SCENARIOS`.

## Reports

Every run writes `reports/<timestamp>-plan.json` describing each planned transaction: scenario, step index, phase (`setup` or `batch`), role, router address (or "not deployed yet"), function, arguments, native value, and the expectations that will be checked. `totals` gives the transaction count, ETH and USDC inputs, and USDC bonded.

Each executed scenario writes `reports/<timestamp>-<scenario>.json` with the chain id, hook, pool id, owner, router addresses, the sizing used, the planned calls, one entry per step (transaction hash, block number, status, gas used, decoded events from the hook and the PoolManager `Swap`), the state snapshots before and after the batch (price, liquidity, insurance reserve, withheld totals, the owner's claimable refund, each router's bonded balance and exemption), and one entry per expectation with `pass` and a detail string. `pass` is true when every expectation passed; `needsRetry` is true when the legs did not share a block. Big integers are written as decimal strings.

## Tests

`pnpm typecheck` and `pnpm test` run without a network. The tests cover the sizing math (scaling with liquidity, budget caps, zero liquidity rejected), every planner's call order, directions, routers, and hookData, expectation evaluation against fixture receipts in both passing and failing shapes, and report serialization.

## Layout

```
src/config.ts      environment parsing
src/chain.ts       viem clients and chain definition
src/artifacts.ts   generated/ loaders, StateView and ERC-20 ABIs, PoolManager Swap event
src/sizing.ts      pure: leg sizes from liquidity and budget
src/scenarios.ts   pure: the four planners
src/evaluate.ts    pure: expectations against decoded receipts and state
src/report.ts      plan and report shapes, serialization
src/runner.ts      preflight, deploy, approve, same-block batch, decode, write reports
src/cli.ts         plan, run, withdraw-bond, claim-refund
scripts/artifacts.mjs
test/              vitest suites
generated/         gitignored, from pnpm artifacts
reports/           gitignored
routers.json       gitignored, deployed router addresses per chain
```
