# ADR-003: Victim refunds as claimable credits, attributed by hookData

Status: accepted, 2026-09-27.

## Context

At slash time the hook knows the victim: it is the immediately preceding swapper, and its shortfall against the block-start price was measured in its own `afterSwap`. The `sender` the hook sees is a router, often stateless, so a direct transfer would strand funds.

## Decision

A slash first credits the victim with `min(shortfall, slashed * victimRefundBps / 10_000)` as a claimable balance keyed by an attributed address, and the remainder to the pool's reserve. The attributed address is the 32-byte `hookData` the router passed, decoded as an address, or the router itself when no data was passed. Credits are claimed with `claimRefund`. After `refundClaimWindowBlocks` the owner may sweep an unclaimed credit into a registered pool's reserve.

The exemption never reads `hookData`; it keys on `sender`. A router can therefore redirect only its own user's refund, never borrow a bonded principal's privilege.

## Consequences

- Victims are paid before LPs; the LP reserve is a residual claim.
- Self-sandwich farming is unprofitable: the refund is capped at a share of the slash, and the "victim" router's loss is the attacker's own capital.
- Stateless routers such as the Universal Router credit refunds to themselves unless they pass hookData; those credits are what the sweep exists for.
