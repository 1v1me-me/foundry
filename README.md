# 1v1me.me Contracts

Smart contracts for [1v1me.me](https://1v1me.me) — 1v1me.me runs 24/7 elimination tournaments where newborn tokens compete for spectator bids in fast-paced, head-to-head prediction markets. Winners seize liquidity from defeated opponents and ascend the bracket until only one remains. Live on **BNB Smart Chain (BSC)**.

## Technology Stack

- **Blockchain**: BNB Smart Chain
- **Smart Contracts**: Solidity ^0.8.30
- **Development**: Foundry, OpenZeppelin libraries (upgradeable contracts, reentrancy guards)

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56)
- **BNB Smart Chain Testnet** (Chain ID: 97)

## Contract Addresses

| Network          | ContractBeacon                             | TournamentManager                          | MatchEngine                                | FighterVault                               |
| ---------------- | ------------------------------------------ | ------------------------------------------ | ------------------------------------------ | ------------------------------------------ |
| BNB Mainnet (56) | 0xeB9bcAA5ac0B9c890862a00a0d482b1fcf15CEC1 | 0x5b3BA297a60685844Fe673c134651d7DCF1A74b6 | 0x2235519578c9eFfBe52C824Fe6fCe428BD5AC1d3 | 0x22ca8Bc2C6dDC31Fe76da6A0d587a9C41ebc849C |
| BNB Testnet (97) | 0x39B6B4237EdDa89fa2Cec8048c80c3Cc5f596A0F | 0x785071A2b61B3C9d55EC36888151db9114E7d1f6 | 0x5D7Dd27FF83E6f93A4657db6E992ef0b25EAf40b | 0x72699A7CbD88DA78E2aFAf9D8B5d606455959468 |

## Features

- **Participatory prize pools.** Every share purchase grows the pot in real-time. When a match resolves, the eliminated fighter's entire vault transfers to the winner. The final prize is the sum of all capital committed across every round.

- **Trailing-average match resolution.** Outcomes aren't decided by a single block's state. A 12-second exponential moving average smooths vault values before comparison, ensuring results reflect sustained market activity rather than last-moment capital spikes.

- **Permissionless on-chain resolution.** No oracle, no admin intervention, no off-chain computation. Any participant can trigger `determineResult` once a round window closes. Winner determination is pure on-chain arithmetic: compare trailing vault values, transfer assets, advance the bracket.

- **O(1) Feistel bracket seeding.** Bracket positions are derived on-demand via a 4-round Feistel cipher seeded by `prevrandao`, eliminating the need to store permutation arrays. Supports up to 1,024 entrants with zero storage overhead and verifiable fairness.

- **Vault-native share accounting.** Each fighter is a minimal vault with linear share pricing (`totalAssets / totalShares`). No BEP-20 token overhead, no bonding curve complexity. Straightforward conversion arithmetic with predictable pricing at any scale.

## Architecture

- **TournamentManager** — Tournament lifecycle, bracket generation, prize distribution
- **MatchEngine** — Pricing mechanics, vault share minting
- **FighterVault** — Vault-based token management, share accounting and redemption
- **ContractBeacon** — Upgradeable beacon proxy for all core contracts

### Libraries

- **BracketLogic** — Single-elimination bracket math and seeding
- **FeistelShuffle** — Efficient on-chain shuffle for fair bracket assignment
- **TournamentMath** — Helper-functions

## License

All rights reserved. Copyright (c) 2025-2026 1v1meme.
