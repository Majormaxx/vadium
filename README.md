# Vadium

A Uniswap v4 hook that deters sandwich attacks on a single pool by aligning the searcher's incentives with the LP's. Searchers post a bond in the pool's fee token; bonded, well-behaved searchers pay a reduced swap fee. A searcher whose own on-chain activity matches a same-block sandwich pattern gets slashed, and the slashed capital flows to in-range LPs via `donate()`.

Status: hackathon build for the UHI10 Hookathon. Testnet only, unaudited.

## How it works

Two mechanisms pull against each other, and that tension is the design.

**Fee discount (the carrot).** A searcher who `bond()`s `token1` gets a fee override in `beforeSwap` that cuts the pool's 30 bps fee for their swaps. The discount only attaches if the searcher keeps trading from the same bonded address.

**Slash (the stick).** Reusing that same address across a sandwich is exactly what a sandwich looks like to this hook, so the `afterSwap` detector checks each swap against the searcher's prior swap in the same block: same address, same block, reversed direction, with an intervening swap from a different address. A match confiscates half the bond on first offense, escalates to a full slash and a rebond ban on repeat, and routes the funds to in-range LPs.

Because the bond and the slash are the same `token1`, no oracle, no swap, and no normalization is needed anywhere in the slash-to-donate path.

## Components

| Path | Role |
|---|---|
| `src/core/VadiumHook.sol` | The hook. Owns the pool key, bond bookkeeping, detection, slashing, donation. |
| `src/core/libraries/BondManager.sol` | Bond struct and the slash/expiry math. |
| `src/core/libraries/FeeDiscount.sol` | Before-swap fee override rules. |
| `src/core/libraries/SandwichDetector.sol` | Same-address, same-block sandwich match logic. |
| `src/core/interfaces/IVadiumHook.sol` | Bond surface and the views a frontend needs. |
| `app/script/Deploy.s.sol` | CREATE2 salt mining + pool init for Unichain Sepolia. |

## Contract

Permission bits: `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG` (mask `0x00C0`). Detection and slashing run only inside the `afterSwap` callback, so they sit under v4's callback reentrancy lock. Bond transfers use `SafeERC20`. Callback entrypoints are gated by `onlyPoolManager`.

The hook governs a single pool, locked at construction. Solidity `0.8.26`, `evm_version` `cancun`. Runtime bytecode ~5.6 kB, creation ~6.2 kB (unoptimized).

## Bonded swap (per-user router)

In v4, the `sender` the hook sees in `afterSwap` is the router (`msg.sender` of `pm.swap()`), not the EOA. So each actor gets its own `SwapRouter`, and the router is the bonded identity. `SwapRouter.bond()` pulls `token1` from the EOA to the router, approves the hook, and bonds on the router's address. The integration tests exercise exactly this: `searcherRouter` and `victimRouter` are distinct bonded identities, and a mule gets its own router in the mule test.

## Deploy

Unichain Sepolia, chain ID 1301.

```
forge script app/script/Deploy.s.sol:DeployVadium \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast -vvvv
```

The script guards `block.chainid == 1301`, mines a CREATE2 salt that lands the hook at an address whose low 14 bits equal the permission mask, deploys via the deterministic factory, then initializes the pool at tick 0.

Pool: native ETH (`token0`) / USDC (`token1`), static 30 bps fee, tick spacing 10. Initial sqrt price is a 1:1 tick 0. Bond denomination is USDC.

| Address | Value |
|---|---|
| PoolManager (Sepolia 1301) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| USDC | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |
| Deterministic deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

## Constants

| Constant | Value |
|---|---|
| `DEFAULT_FEE_DISCOUNT_BPS` | 10 (0.10% off the fee) |
| `DEFAULT_MIN_BOND` | 100e6 (100 USDC) |
| `DEFAULT_MIN_BOND_DURATION_BLOCKS` | 100 |
| `FIRST_SLASH_BPS` | 5000 (50%) |
| `FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS` | 7,200 |
| `REPEAT_OFFENSE_BAN_BLOCKS` | 216,000 |

## Gas (testnet, unoptimized)

| Operation | Gas |
|---|---|
| `bond` | 124,370 |
| `withdrawBond` | 148,432 |
| Non-sandwich swap through hook | 437,982 |
| Sandwich → slash + donate | 711,531 |

## Test

```
forge test
```

72 tests: unit tests for `VadiumHook`, `BondManager`, `FeeDiscount`, `SandwichDetector`, plus end-to-end integration tests using per-user `SwapRouter` instances and the real `PoolManager` (9 scenarios + 4 gas benchmarks).

## Adversarial analysis

This is the buildable subset of a sandwich, not a full sandwich detector. Disclosed, known v1 weaknesses:

- Detection keys on address reuse. A searcher running two fresh EOA wallets (or a mule address) across the two sandwich legs is not matched by same-address detection. Countermeasure in scope for v2: cross-address link prover or Mempool flashbots-style ordering analysis.
- Detection is scoped to same-block, same-pool activity. Cross-pool, multi-block sandwich sequencing is out of scope.
- The gas cost of the detection bookkeeping is paid by every swapper on the pool, bonded or not, since it runs in `afterSwap`.

Nothing here is a substitute for an audit.

## License

MIT.
