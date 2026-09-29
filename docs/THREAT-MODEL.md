# Threat model

This document states what the hook protects, who can act on it, what each actor is trusted with, and which holes are known and left open on purpose. Read it before the code.

## Assets

- LP principal in a registered pool.
- Searcher bonds held by the hook.
- Victim refund credits held by the hook.
- The per-pool insurance reserve.
- Withheld ERC-6909 claims the hook owns inside the PoolManager.
- Price integrity: the pool's block-start price should track the market within one block.

## Actors

| Actor | Can do | Trusted with |
|---|---|---|
| Swapper (unbonded) | Swap through any router | Nothing. Clamped to block-start price. |
| Bonded searcher | Bond, withdraw after lock, swap exempt from the clamp on the first swap of a block | Nothing beyond their own bond, which is at risk. |
| Router | Pass `hookData` naming the principal to credit a refund to | Its own users' refunds only. It cannot claim another address's exemption. |
| Owner (Safe on mainnet) | Register pools, set config and params within bounds, set roles, pause, claim coverage to LPs, sweep stranded tokens and expired refunds into a reserve | Liveness and parameter sanity. It cannot move bonds, reserves, or refund credits to itself. |
| Pool operator | Set that pool's config within bounds | Same as owner for one pool's knobs. |
| Keeper | Drain a pool's reserve to its LPs, capped per call, only for addresses with an active flag | Timing of payouts. |
| Watchtower | Flag any address with an evidence hash and slash a live bond by an amount it chooses | Correctness of its flags. A wrong flag slashes an honest bond. |
| Reactive relay | Extend a flag, never shorten, never slash | Liveness only. |
| PoolManager | Calls the hook callbacks | Assumed correct (audited by Uniswap). |
| Reactive callback proxy | Delivers relay messages and collects fees | Assumed to inject the true ReactVM id. |

## Trust assumptions

1. The block-start checkpoint is taken at the first swap of a block. A pool with no swaps for many blocks checkpoints its last-traded price, which may be far from market. Bonded arbitrage is what corrects it; if nobody bonds, unbonded flow pays the difference to LPs until the next block.
2. The clamp target is a constant-liquidity fill from the checkpoint. It is exact for full-range liquidity and approximate for concentrated liquidity outside the checkpoint band. `_targetUnspecified` is virtual for a tick-walking replacement.
3. The keeper is a single key. If it is lost, the owner can still pay LPs via `claimCoverage` and rotate the keeper.
4. The watchtower is a single key. It should be a multisig or a contract that verifies evidence before acting; the hook only stores the hash.
5. The bond token is a standard ERC-20 with no fee on transfer and no rebasing. Fee-on-transfer is rejected at bond time; rebasing tokens would break solvency accounting.

## Known holes, left open

**Bonded mule.** Two bonded addresses split the sandwich legs. Each leg is that address's first swap of the block, so both are exempt from the clamp, and no single address reverses direction, so the same-address detector never fires. Cost to the attacker: two bonds at risk to a watchtower flag with evidence. Executable statement: `test_KNOWN_bondedMuleHole` in `test/Economics.t.sol`.

Two answers exist. The watchtower can flag with evidence. And a pool can opt in to collective slashing (`setCollectiveSlash`): a bonded address with no prior swap in the block that closes a reversal opened by a different address, with a hurt swap in between, is slashed as the closer. Victim loss is always required on this path because the evidence is weaker. The false positive is a bonded address that trades against another address's earlier leg in the same block for its own reasons; the operator decides whether that trade-off suits the pool. Off by default. `test_bondedMule_slashedWhenCollectiveEnabled` shows it working on a real pool.

**Refund attribution by the victim's router.** A router names the address that receives a refund. A malicious router can redirect its own user's refund to itself. It cannot touch anyone else's, because attribution is per swap and only that swap's measured shortfall funds the credit. Users choose their router; the hook cannot verify a principal without a signature scheme, which is a possible v2.

**Clamp fidelity on concentrated liquidity.** A clamped swap that crosses into a band with more liquidity than at block start can receive more than the constant-liquidity target and be withheld the difference, even with no manipulation. Pools this project deploys seed full-range liquidity, where the target is exact.

**Keeper timing.** The keeper chooses when to drain and to which LP set (whoever is in range at drain time). Donations are pro rata to in-range liquidity, not to the LPs present during the attack. The cap per call and the flag requirement bound the discretion; they do not remove it.

**Victim measure includes unrelated impact.** A victim's shortfall is measured against the block-start price, so it includes the impact of every earlier swap in the block, not only the front-run. The refund is additionally capped by a share of the slash, which bounds over-attribution.

## Invariants the tests enforce

- `bondToken.balanceOf(hook) >= totalBonded + totalReserve + totalClaimable`.
- Per pool: `withdrawn <= slashedPledged` and `reserve == slashedPledged - withdrawn`.
- `isExempt` implies bonded, unbanned, unflagged, and unpaused.
- ERC-6909 claims the hook holds cover every `withheld` balance.
- Strike counts never decrease, including across withdraw and re-bond.
- Sum of bonds equals `totalBonded`.

See `test/invariant/BondedFlowInvariant.t.sol`.

## Static analysis triage

`make lint` runs slither (fails on medium or higher) and semgrep's smart-contract rules (fails on warning or higher). Remaining low and informational results, reviewed 2026-09-27:

- Slither `incorrect-equality` on `_clampCheckpoint` and `_shortfallInBond`: both compare a block number or a zero amount by design.
- Slither `reentrancy-no-eth` on `_afterSwap`: the external call is `poolManager.mint`, made from inside the PoolManager's own `afterSwap` callback while the manager is locked; the state written afterwards is the swap record. No path re-enters the hook from that call.
- Slither `unused-return` on `unlock`, `donate`, `settle`, and `getSlot0`: the return values are not needed; the callback and the delta checks carry the result.
- Slither `uninitialized-local` on `slashed` in `flagFromWatchtower`: zero is the intended default.
- Semgrep informational rules (nested ifs, prefix increments, payable constructors, revert strings) are not gated.
