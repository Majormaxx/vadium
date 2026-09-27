# Positioning

One page on what Vadium is, who it is for, and why it exists next to the alternatives.

## What it is

Vadium is a Uniswap v4 hook for pool operators who want sandwich protection without a stale price. Unbonded flow is held to the block-start price, so a sandwich cannot capture its victim's price impact. Bonded flow is exempt on its first swap of each block and trades at the real price, because a bonded address that completes a sandwich loses part of its bond: the victim is refunded first, the pool's LP reserve takes the rest. The bond buys the right to arbitrage inside the block, and that arbitrage is what keeps the block-start price near market.

It ships as a reference hook and as an importable module (`BondedFlow`, `BlockPriceClamp`) that other hook authors can compose, because v4 allows one hook per pool.

## Who it is for

- Pool operators and LP managers on Unichain who run volatile pairs and want the clamp's protection without the clamp's stale-price cost.
- Professional arbitrageurs who will post a bond to keep trading at the real price.
- Hook authors who want a bonded, slashable identity for professional flow without building the bond, strike, reserve, and refund machinery themselves.

## Why not the alternatives

**OpenZeppelin `AntiSandwichHook`.** Free and audited. It clamps every same-block swap to block-start in one direction and its own documentation notes that in-block arbitrage stops, so the block-start price can be stale or manipulated. Vadium keeps the clamp for anonymous flow and adds an accountable exemption so the price keeps moving. It clamps both directions from a static snapshot and computes the target in constant time.

**Angstrom (Sorella).** Uniform clearing price per block with an off-chain node and an arbitrage auction. Heavier to run and to integrate. Vadium is a single on-chain contract with no auction and no node, and it composes into other hooks.

**Unichain's sequencer.** TEE block building, an encrypted mempool, and verifiable priority ordering narrow the sandwich surface at the chain level. They do not remove it, and they do nothing for LPs when an attack still lands. Vadium sits inside the pool and pays the victim and the LPs from the attacker's own capital.

## What it does not claim

- It does not catch a sandwich split across two bonded addresses. That is disclosed, tested as a known hole, and left to the evidence-based watchtower.
- It does not refund a victim who traded through a router that did not name them. The credit goes to the router.
- It is unaudited. The threat model is in `docs/THREAT-MODEL.md`.

## Status

Testnet. See `deployments/` for what is live and `README.md` for how to deploy.
