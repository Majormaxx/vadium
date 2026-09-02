# Vadium

[![Solidity](https://img.shields.io/badge/solidity-0.8.26-blue)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/built%20with-Foundry-ff69b4)](https://book.getfoundry.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-72%20passing-brightgreen)](https://github.com/Majormaxx/vadium/actions)
[![Unichain Sepolia](https://img.shields.io/badge/chain-Unichain%20Sepolia-lightgrey)](https://sepolia.uniscan.xyz)

A Uniswap v4 hook that makes sandwich attacks unprofitable instead of just detected. The cost of attacking is staked upfront: a searcher posts a bond in the pool's fee token to earn a lower swap fee, and when their own flow reads as a sandwich, that bond is slashed and held in an LP insurance reserve. No oracle, no swap, no off-chain watcher to run the core pool.

This is a hackathon build for the UHI10 Hookathon. Testnet only, unaudited.

## Problem

When you swap tokens, someone else can watch your order, buy just before you, move the price, then sell back to you at the worse price. They profit, you pay more. That is a sandwich attack, and it hits ordinary users hardest because they never see it coming.

Standard answers either raise fees to deter attackers (which punishes honest traders too) or rebate honest searchers (which attackers can just claim). Neither makes low-fee, volatile-pair liquidity safe to provide.

## The design

Think of it as a rental-car security deposit.

A trader who wants lower fees on this pool puts down a deposit in the pool's own token. As long as they trade honestly, they keep the deposit and pay a reduced fee. If they are caught sandwiching, part of their deposit is taken. The money taken goes into a reserve that pays the pool's liquidity providers.

The load-bearing piece is the tension between the two sides:

**Fee discount (the carrot).** A searcher who `bond()`s `token1` gets a `beforeSwap` fee override that cuts the pool's 30 bps fee on their swaps. The discount only holds if the searcher keeps trading from the same bonded address.

**Slash (the stick).** Reusing that same address across a sandwich is exactly what a sandwich looks like to this hook. The `afterSwap` detector checks each swap against the searcher's prior swap in the same block: same address, same block, reversed direction, an intervening swap from a different address. A match confiscates half the bond on first offense, escalates to a full slash plus a re-bonding ban on repeat, and the confiscated capital lands in the LP insurance reserve.

The mechanism does not depend on catching every attacker. To get the discount, a searcher must trade from one visible identity, and trading from one visible identity is how a sandwich gets caught. An attacker who rotates through fresh addresses avoids detection, but forgoes the discount that made bonding worthwhile. Every evasion costs more than the attack earns.

## Architecture

```mermaid
flowchart TB
    subgraph Unichain["Unichain Sepolia (1301)"]
        Searcher[Searcher / Router] -->|bond / withdrawBond| V[VadiumHook]
        Searcher -->|swap| PM[PoolManager]
        PM -.->|beforeSwap: fee override| V
        PM -.->|afterSwap: sandwich detect| V
        V -->|slash| R[LP insurance reserve]
        R -->|donate| LP[In-range LPs]
        V[VadiumHook] --> B[BondManager]
        V --> F[FeeDiscount]
        V --> D[SandwichDetector]
    end

    style Unichain fill:#e3f5fd,color:#1a1a2e,stroke:#90caf9
```

## System lifecycle

| Step | Trigger | Actor |
|---|---|---|
| 1. Bond | `bond(amount)` with token1 | Searcher |
| 2. Discounted swap | `beforeSwap` applies fee override | PoolManager |
| 3. Record swap | `afterSwap` stores sender leg | Hook |
| 4. Match detection | same block, same address, reversed direction, intervening other address | Hook |
| 5. First offense | slash 50% of bond, extend lock window | Hook |
| 6. Repeat offense | full slash + ban from re-bonding | Hook |
| 7. Reserve | slashed token1 credited to the LP insurance reserve | Hook |
| 8. Claim | owner/keeper routes reserve to in-range LPs via `donate()` | Hook |
| 9. Withdraw | `withdrawBond()` after minimum duration | Searcher |

## Deployments

Nothing is deployed yet; addresses are filled after the testnet broadcast.

| Contract | Chain | Address |
|---|---|---|
| `VadiumHook` | Unichain Sepolia (1301) | pending |
| Vadium pool | Unichain Sepolia (1301) | pending |

## Contract

### Permission bits

The hook address is CREATE2-mined so its lower 14 bits encode the required flags (`mask 0x00C0`). The deploy script brute-forces the salt against the deterministic factory.

| Callback | Purpose |
|---|---|
| `beforeSwap` | Apply bonded fee discount via `OVERRIDE_FEE_FLAG` |
| `afterSwap` | Record swap leg, run sandwich detection, slash + donate |

Detection and slashing run only inside the `afterSwap` callback, so they sit under v4's callback reentrancy lock. Bond transfers use `SafeERC20`. Callback entrypoints are gated by `onlyPoolManager`.

### Bond mechanics

| Parameter | Default | Notes |
|---|---|---|
| `DEFAULT_FEE_DISCOUNT_BPS` | 10 | 0.10% off the pool fee |
| `DEFAULT_MIN_BOND` | 100e6 | 100 USDC |
| `DEFAULT_MIN_BOND_DURATION_BLOCKS` | 100 | lock before withdrawal |
| `FIRST_SLASH_BPS` | 5000 | 50% on first offense |
| `FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS` | 7,200 | window for escalation |
| `REPEAT_OFFENSE_BAN_BLOCKS` | 216,000 | re-bond ban on repeat |

### Interface

```solidity
interface IVadiumHook {
    function bond(uint256 amount) external;
    function withdrawBond() external;

    function isBonded(address searcher) external view returns (bool);
    function bondedBalance(address searcher) external view returns (uint256);
    function isBanned(address searcher) external view returns (bool);
}
```

## Detection

The detector keys on four conditions inside one block, all observable from the hook's own callback state:

1. The sender has a prior swap in this block.
2. The prior swap was in the opposite direction.
3. A different address swapped between the two legs.
4. No cross-block or cross-pool sequencing is considered.

Position-in-block is a monotonic per-block counter, so a later swap always has a strictly larger `positionInBlock`. The intervening-swap signal comes from the immediately-preceding swapper: if it differs from the current sender, a different address swapped after the sender's prior leg.

The two-tier slash is calibrated against false positives. A same-block direction reversal is a strong signal but not proof beyond doubt (a market maker rebalancing can trip it), so a first flag takes only a portion, and only a repeat inside the extended lock window draws the full slash and the ban.

```solidity
uint256 slashed = b.computeSlash(isRepeat, FIRST_SLASH_BPS);
// first offense: (amount * 5000) / 10_000
// repeat:         full remaining amount
```

## Gas (testnet, unoptimized)

| Operation | Gas |
|---|---|
| `bond` | 124,370 |
| `withdrawBond` | 148,432 |
| Non-sandwich swap through hook | 437,982 |
| Sandwich -> slash + donate | 711,531 |

Hook runtime bytecode ~5.6 kB, creation ~6.2 kB. These are the per-operation gas deltas measured in `Integration.t.sol`; the constant per-swap detection bookkeeping in `afterSwap` is paid by every swapper on the pool, bonded or not.

## Events

| Event | Indexed | Consumer |
|---|---|---|
| `Bonded(address,uint256,uint256)` | searcher | Off-chain |
| `BondWithdrawn(address,uint256)` | searcher | Off-chain |
| `Sandwiched(address,uint256,bool,uint256,uint256)` | searcher | Off-chain |

## Custom errors

| Error | Parameters | Reverts when... |
|---|---|---|
| `BondTooSmall` | `uint256 amount, uint256 minimum` | Bond below `DEFAULT_MIN_BOND` |
| `BondNotMatured` | `uint256 currentBlock, uint256 maturityBlock` | Withdraw before lock elapses |
| `Banned` | `uint256 bannedUntil` | Banned address bonds or withdraws |
| `NoBond` | -- | Withdraw with no live bond |
| `BondAlreadyActive` | -- | Re-bond while one is active |
| `UnsupportedOperation` | -- | `unlock()` callback reached |

## Access control

| Surface | Role | Functions |
|---|---|---|
| Bond lifecycle | Anyone | `bond`, `withdrawBond` |
| Swap callbacks | `PoolManager` only | `beforeSwap`, `afterSwap` (`onlyPoolManager`) |

There is no wallet-admin role. Bonding is permissionless; callback entrypoints are locked to the PoolManager by `SafeCallback`. The deployer's only leverage is the CREATE2 salt that places the hook.

## Deploy

Unichain Sepolia, chain ID 1301:

```
forge script app/script/Deploy.s.sol:DeployVadium \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast -vvvv
```

The script guards `block.chainid == 1301`, mines the CREATE2 salt, deploys via the deterministic factory, and initializes the pool at tick 0.

| Address | Value |
|---|---|
| PoolManager (Sepolia 1301) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| USDC | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |
| Deterministic deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

Pool: native ETH (`token0`) / USDC (`token1`), static 30 bps fee, tick spacing 10.

## Structure

```
src/core/
├── VadiumHook.sol                # The hook
├── interfaces/IVadiumHook.sol    # Searcher-facing bond surface
└── libraries/
    ├── BondManager.sol           # Two-tier slash + expiry math
    ├── FeeDiscount.sol           # Before-swap fee override rules
    └── SandwichDetector.sol      # Same-block sandwich match logic
app/script/Deploy.s.sol           # CREATE2 salt mining + pool init
test/                             # 72 tests (unit + integration + gas)
```

## Test

```
forge test
```

72 tests across 5 suites, all green under the `fast` profile, `forge fmt --check` clean.

| Suite | Area |
|---|---|
| `VadiumHook.t.sol` | Bond lifecycle, slash escalation, bans |
| `BondManager.t.sol` | Slash math, expiry windows |
| `FeeDiscount.t.sol` | Override rules, boundaries |
| `SandwichDetector.t.sol` | Pattern matching |
| `Integration.t.sol` | Per-user-router end-to-end + gas benchmarks |

The integration tests run against a real `PoolManager` with per-user `SwapRouter` instances, because in v4 the `sender` the hook sees in `afterSwap` is the router, not the EOA. Each actor gets its own router, and the router is the bonded identity.

## Adversarial analysis

Detection alone cannot catch everyone, so the design does not rely on it. Three layers, in the order they matter:

1. **On-pool detector.** Catches the obvious case instantly: same account, same block, reversing the trade. Runs in `afterSwap` on the hot path.
2. **LP insurance reserve.** Even when a clever attacker slips through one layer, the pool keeps a standing fund of past penalties. LPs get recompensed on average, and the fund is visible onchain to anyone who checks. This is what makes imperfect detection acceptable.
3. **Watchtower (in progress).** A separate, slower process that correlates across accounts and across blocks, so rotating through fresh wallets stops hiding the pattern. The on-pool detector is the cheap fast tripwire; the watchtower is the slower, smarter review.

Disclosed v1 limits:

- Same-address detection keys on address reuse. An attacker who rotates through fresh wallets dodges it, at the cost of forgoing the discount they bonded for.
- Detection is scoped to same-block, same-pool activity. Cross-pool, multi-block sequencing is a watchtower concern, not a hook concern.
- The per-swap detection bookkeeping in `afterSwap` costs gas for every swapper, bonded or not, since it runs on the hot path.

Nothing here substitutes for an audit.

## License

MIT.
