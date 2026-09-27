# ADR-004: Safe as owner, no timelock

Status: accepted, 2026-09-27.

## Context

The owner registers pools, sets bounded parameters, rotates roles, pauses, pays reserves to LPs, and sweeps stranded tokens. None of these can move bonds, reserves, or refund credits to the owner: `sweepToken` refuses any bond-token amount that is owed, and every payout path ends in a PoolManager donate.

## Decision

On mainnet the owner is a Safe with at least two signers, reached by two-step ownership transfer from the deployer. No `TimelockController` for now: the owner surface cannot extract user funds, and a timelock would add a contract to the audit scope without reducing that risk. A pause can never block `withdrawBond`, so an owner cannot trap a searcher.

## Consequences

- Parameter changes take effect immediately. Searchers who dislike a change can withdraw after their lock.
- Revisit if any upgradeable proxy or a function that moves user funds to a configurable address is ever added.
