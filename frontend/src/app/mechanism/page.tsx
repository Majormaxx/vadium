import type { Metadata } from "next";

export const metadata: Metadata = { title: "Mechanism" };

const repo = "https://github.com/Majormaxx/vadium";

export default function MechanismPage() {
  return (
    <article className="prose">
      <h1>Mechanism</h1>
      <p className="mt-3">
        Vadium is a Uniswap v4 hook. It applies two rules to every swap in a registered pool and one penalty to
        addresses that break the deal the rules set up.
      </p>

      <h2>Rule one: the clamp</h2>
      <p>
        At the first swap of each block the hook records the pool&apos;s price and in-range liquidity. That record is
        the checkpoint. Every later swap in the same block is compared with what it would have received at the
        checkpoint. If the swap did better than the checkpoint, the difference is withheld: the hook keeps it as
        ERC-6909 claims inside the PoolManager, and anyone can flush those claims to the pool&apos;s LPs. If the swap
        did worse, nothing is withheld, and the shortfall is recorded as that swap&apos;s loss.
      </p>
      <p>
        Both directions are clamped from the same checkpoint. A back-run cannot collect the price impact of the swap
        before it, whether or not it comes from the same address as the front-run. That is what stops an unbonded
        sandwich from paying.
      </p>

      <h2>Rule two: the exemption</h2>
      <p>
        An address with a live bond, no ban, and no active flag is exempt from the clamp on its first swap of each
        block. It trades at the real price. Every later swap by the same address in that block is clamped like anyone
        else&apos;s.
      </p>
      <p>
        The exemption is what keeps the checkpoint honest. A clamp with no exemption freezes the pool at the block
        start price, and that price drifts from the market whenever nobody can arbitrage inside the block. Bonded
        searchers move the price; unbonded flow follows one block later.
      </p>

      <h2>The slash</h2>
      <p>The detector fires when three things happen in one block, in order:</p>
      <ol>
        <li>a bonded address swaps in one direction,</li>
        <li>a different address swaps and receives a worse price than the checkpoint,</li>
        <li>the bonded address swaps back in the other direction.</li>
      </ol>
      <p>
        A first strike takes half the bond. A repeat inside the escalation window takes the rest and bans the address
        from re-bonding. In both cases the address is flagged, which removes its exemption, so a struck searcher is
        clamped from then on.
      </p>
      <p>
        The slashed amount is split. The victim is credited first: the smaller of its measured loss and half the slash,
        held by the hook and claimable at any time. Whatever remains goes to the pool&apos;s insurance reserve. The
        keeper drains the reserve to the LPs in range at the time of the drain, capped per call; the owner can also pay
        it out as coverage.
      </p>
      <p>
        A bonded market maker that reverses around a trade which was not hurt is not slashed. The victim condition
        requires the intervening swap to have executed worse than the checkpoint.
      </p>

      <h2>Withheld gains</h2>
      <p>
        Gains withheld from clamped swaps never leave the pool. They sit as claims the hook owns until anyone calls
        <code>flushWithheld</code>, which donates them to the in-range LPs. The pool page lists each withheld event.
      </p>

      <h2>Disclosed limits</h2>
      <p>These are stated in the threat model and left open on purpose.</p>
      <h3>Bonded mule</h3>
      <p>
        Two bonded addresses can split the legs of a sandwich. Each leg is that address&apos;s first swap of the
        block, so both are exempt, and no single address reverses direction, so the detector never fires. The cost to
        the attacker is two bonds exposed to a watchtower flag with evidence. The repository keeps this executable as
        <code>test_KNOWN_bondedMuleHole</code>.
      </p>
      <h3>Clamp target fidelity</h3>
      <p>
        The clamp target assumes the checkpoint liquidity holds across the whole fill. That is exact for full-range
        liquidity and approximate when a swap crosses into a band with different liquidity than at block start. A
        clamped swap that crosses into deeper liquidity can be withheld a difference that has nothing to do with
        manipulation. The pools this project deploys seed full-range liquidity.
      </p>
      <h3>Refund attribution</h3>
      <p>
        The hook sees a router, not a wallet. A router names the address that receives a refund by passing exactly 32
        bytes of hook data; a router that names nobody receives the credit itself. A router can redirect its own
        user&apos;s refund and nobody else&apos;s, because only that swap&apos;s measured shortfall funds the credit.
      </p>
      <h3>Keeper timing</h3>
      <p>
        The keeper chooses when to drain a reserve. The LPs in range at that moment receive it, pro rata to liquidity,
        which is not the same set as the LPs present during the attack. The per-call cap and the requirement that a
        drained address hold an active flag bound the discretion without removing it.
      </p>
      <h3>Victim measure</h3>
      <p>
        A victim&apos;s loss is measured against the checkpoint, so it includes the impact of every earlier swap in
        the block, not only the front-run. The refund is capped at a share of the slash, which bounds over-attribution.
      </p>

      <h2>Read more</h2>
      <ul>
        <li>
          <a href={`${repo}/blob/main/README.md`} target="_blank" rel="noreferrer">
            README
          </a>
          , the mechanism, architecture, contract reference, and gas figures.
        </li>
        <li>
          <a href={`${repo}/blob/main/docs/THREAT-MODEL.md`} target="_blank" rel="noreferrer">
            Threat model
          </a>
          , assets, actors, trust assumptions, known holes, and the invariants the tests enforce.
        </li>
        <li>
          <a href={`${repo}/blob/main/docs/POSITIONING.md`} target="_blank" rel="noreferrer">
            Positioning
          </a>
          , who the hook is for and how it compares to the alternatives.
        </li>
        <li>
          <a href={`${repo}/tree/main/docs/adr`} target="_blank" rel="noreferrer">
            Decision records
          </a>
          , why the clamp is paired with a bonded exemption, how pools are keyed, how refunds route, and why the owner
          is a Safe without a timelock.
        </li>
        <li>
          <a href={`${repo}/blob/main/test/Economics.t.sol`} target="_blank" rel="noreferrer">
            Economics tests
          </a>
          , the profit of unbonded, mule, and bonded sandwiches on a real PoolManager.
        </li>
      </ul>
      <p>Testnet only. Unaudited.</p>
    </article>
  );
}
