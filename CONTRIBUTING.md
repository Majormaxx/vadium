# Contributing

## Setup

```
git clone --recurse-submodules https://github.com/Majormaxx/vadium
cd vadium
cp .env.example .env
make test
```

`make test` runs every suite except the fork suites, which skip unless `UNICHAIN_SEPOLIA_RPC` is set. `make test-fork` runs those against the live chain.

## Rules

- `forge fmt` before committing. CI checks it.
- Every change to `src/` ships with tests in the same commit, and the gas snapshot is regenerated with `make snapshot` when gas moves.
- A change to the mechanism (what gets clamped, slashed, refunded, or exempted) needs an ADR under `docs/adr/` and an update to `docs/THREAT-MODEL.md`.
- Commit messages are one line, past tense, describing what shipped: `added extend-only relay flags`.
- No internal planning documents, roadmap references, or phase names in committed files.

## Layout

```
src/base/        composable bases: BondedFlow, BlockPriceClamp, ReactiveFlagReceiver
src/hooks/       VadiumHook, the reference composition
src/libraries/   pure math: BondManager, ClampMath, FeeDiscount, InsurancePolicy, SandwichDetector
src/interfaces/  IBondedFlow, IBlockPriceClamp, IReactiveFlagReceiver, IVadiumHook
src/examples/    ExampleBondedHook, the minimal third-party composition
src/reactive/    VadiumReactive, the experimental cross-chain relay
app/script/      Deploy, Wire, AddLiquidity, DeployReactive, Chains
test/            unit (VadiumHook.t.sol), Integration, Economics, invariant/, libraries/, fork/
deployments/     one JSON per chain id, written by Deploy.s.sol
```
