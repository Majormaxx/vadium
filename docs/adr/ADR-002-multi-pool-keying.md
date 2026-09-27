# ADR-002: One hook instance, many pools, keyed by PoolId

Status: accepted, 2026-09-27.

## Context

The first version bound the hook to one pool at construction but never checked the `PoolKey` in its callbacks, so any pool initialized with the hook address shared its state. v4 allows one hook per pool, so a single-pool hook has no distribution beyond pools its own team deploys.

## Decision

Pool-scoped state (registration, configuration, insurance reserve, same-block ordering, withheld claims, checkpoint) lives under `PoolId`. Identity-scoped state (bonds, strikes, bans, flags, refund credits) is hook-wide, because the accountable party is the searcher, not the pair. The owner pre-registers a pool; `beforeInitialize` reverts for anything else. Every registered pool must contain the hook's bond token, because reserve payouts are a one-sided donate of that token.

The base contracts (`BondedFlow`, `BlockPriceClamp`) implement no `IHooks` function, so other hook authors can inherit them into their own hooks. `src/examples/ExampleBondedHook.sol` is the reference composition and is tested.

## Consequences

- One bond, one reputation, across every pool the hook serves.
- Reserve capital stays with the pool whose LPs were harmed.
- A hook author who wants a different privilege (a fee tier, an allowlist) overrides `_isExempt` usage in their own callbacks and reuses the rest.
