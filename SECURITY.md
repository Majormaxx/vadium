# Security

Vadium is unaudited. Do not deploy the hook to a production pool with meaningful liquidity until an audit report is published under `docs/audits/`.

## Scope

- `src/base/`, `src/hooks/`, `src/libraries/`, `src/interfaces/`: the hook, its composable bases, and the pure math.
- `src/reactive/`: the Reactive Network sidecar (experimental).
- `app/script/`: deploy and wiring scripts, in scope only for issues that would produce a misconfigured deployment.

Out of scope: `frontend/`, `services/`, test code, and third-party libraries under `lib/`.

## Reporting

Email security@cipherplay.net with a description, the affected file and function, and a proof of concept (a Foundry test is ideal). You will get an acknowledgement within 72 hours.

We follow coordinated disclosure with a 90-day window from acknowledgement. If a fix ships sooner, the report can be published sooner by agreement. There is no bug bounty at this stage; that will change once the hook holds mainnet liquidity, and this file will say so when it does.

## What counts

Anything that lets a party take funds it is not owed: draining the reserve, stealing bonds or refunds, minting withheld claims the hook cannot back, or bypassing the clamp so a sandwich profits against a clamped pool. Also anything that bricks a pool: a state that makes every swap revert, or a payout path that can never complete.

Findings about the disclosed limits in `docs/THREAT-MODEL.md` (the bonded-mule split, refund attribution by the victim's own router, the constant-liquidity clamp target) are welcome as improvements but are not vulnerabilities.
