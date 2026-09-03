# Vadium — UHI10 Hookathon Submission Copy

Use these answers in the Hook Submission Form. Adjust the Project ID and cohort to your real enrollment. Every field is written for a judge who may not be a DeFi power user.

## Project ID

`HK-UHI10-####` (fill in your assigned ID)

## Project Title

Vadium

## 1-2 sentence description

Vadium makes sandwich attacks unprofitable instead of just detected. The cost of attacking is staked upfront: a searcher posts a bond in the pool's token to earn a lower fee, and when their own flow reads as a sandwich, that bond is slashed into a reserve that pays the pool's liquidity providers. Volatile pairs stay LP-viable at a low 30 bps fee, with no oracle, no auction, and no off-chain watcher running the pool.

## Project tags

Sandwich-Neutralizing Hook, Fee-Rebate System, MEV Protection, Honesty Bond, LP Insurance Reserve, Sustainable Liquidity, LP Protection

## Does your project address the current Uniswap Hookathon theme?

A — Yes, my project addresses the theme.

## Problem / Background

When you swap tokens on a decentralized exchange, someone else can watch your order, buy just before you to move the price, then sell back to you at the worse price. They profit, you pay more. This is a sandwich attack, and it punishes ordinary users the most, because they never see the attack coming and have no way to tell it happened.

Liquidity providers bear the residual pain. Concentrated liquidity in a volatile pair is a target for this extraction, and offering that liquidity at low fees becomes a losing bet. The usual answers each miss the mark: raising fees to deter attackers punishes honest traders, while rebating honest searchers is trivially claimed by attackers too. Nobody makes the attacker's own capital the thing that funds LP protection.

## Impact — What makes this project unique?

Vadium is built on a simple, plain idea: the cost of attacking is staked upfront.

Think of it as a rental-car security deposit. A trader who wants lower fees on this pool puts down a deposit in the pool's own token. As long as they trade honestly, they keep the deposit and pay a reduced fee. If they are caught sandwiching, part of their deposit is taken, and the money goes into a reserve that pays the pool's liquidity providers.

The mechanism does not depend on catching every attacker. To get the discount, a searcher must trade from one visible identity, and trading from one visible identity is exactly how a sandwich gets caught. An attacker who rotates through fresh addresses avoids detection but forgoes the discount that made bonding worthwhile. Every evasion costs more than the attack earns, so toxic flow is priced out instead of merely filtered.

The LP insurance reserve makes imperfect detection acceptable. Even when a clever attacker slips through, the pool keeps a standing fund of past penalties, visible onchain, that recompenses LPs on average. That turns Vadium from a detector into an economic mechanism: the attacker's own bond collateralizes the pool's protection.

## Challenges

The hard part was keeping the slashing honest. A same-block direction reversal is a strong sandwich signal but not proof beyond doubt, so a first offense takes only half the bond and extends a lock window. Only a repeat inside that window escalates to a full slash and a re-bonding ban. The design refuses to over-punish on a single, imperfect signal.

Moving the slash into the locked `afterSwap` callback added another layer. Settling the confiscated capital against the PoolManager without breaking v4 accounting took care, and the integration tests run against a real PoolManager with per-user routers precisely because in v4 the sender the hook sees is the router, not the EOA. Get that wrong and the detector never matches a single sandwich.

The disclosed limit is that same-address detection keys on identity reuse. An attacker who spins up fresh wallets dodges it, though they forfeit the discount they bonded for. Two layers close that gap: the insurance reserve accumulates every penalty so LPs are recompensed on average even when a specific attack slips through, and the hook ships a watchtower slot. `flagFromWatchtower`, callable only by a one-time-assigned watchtower address, credits a live bond into the reserve, counts the same strike as the on-pool detector, and marks the address for the keeper, whose `drainFlagged` settles the whole reserve to LPs in a single atomic `unlock`. A flag also strips the discounted fee for its duration, and the slash extends the bond's withdrawal lock, so an evader cannot keep trading cheap while flagged and cannot walk away with the residual bond. That is the on-chain anchor for a cross-account, cross-block Reactive observer that flags the pattern the hot-path detector cannot see.

## Demo video, slide deck, project link

- Demo video: (fill in URL)
- Slide deck: (fill in URL)
- Project link: https://github.com/Majormaxx/vadium
