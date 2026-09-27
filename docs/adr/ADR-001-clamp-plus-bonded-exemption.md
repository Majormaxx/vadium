# ADR-001: Clamp unbonded flow to the block-start price, exempt bonded flow

Status: accepted, 2026-09-27.

## Context

The first version punished sandwiches only when a bonded address reused itself across both legs. An unbonded attacker was detected and ignored. Mechanism-based alternatives exist: OpenZeppelin's `AntiSandwichHook` holds every same-block swap to the block-start price, which makes sandwiching unprofitable for everyone but also stops in-block arbitrage, so the pool's price goes stale; its own documentation says so.

## Decision

Combine the two. Unbonded flow is clamped: no swap in a block executes at a better price than the pool offered at the block's first swap, in either direction, and the gain is withheld for LPs. Bonded flow is exempt on its first swap of the block and trades at the real price, because it is slashable when its own flow forms a sandwich around a swap that was hurt. The bond therefore buys the right to arbitrage inside the block, which is what keeps the block-start price near market.

The clamp is ported from OpenZeppelin's implementation rather than inherited, because their library pins a v4-core revision with types ours lacks, and because their checkpoint mutates during simulation (which is why they clamp one direction only). Our checkpoint is a static snapshot; the target is computed in constant time from the filled amount after the swap.

## Consequences

- An unbonded sandwich, including one split across addresses, cannot capture its victim's price impact. Proven in `test/Economics.t.sol`.
- A bonded arbitrageur moves the price; later clamped swaps in the same block get the worse of block-start and current price, and LPs receive the difference. The next block's checkpoint includes the move.
- A bonded attacker's second leg is clamped like anyone else's and the bond is slashed.
- A pool with no bonded participants degrades to the plain clamp's stale-price behavior. Operators can disable the clamp per pool.
