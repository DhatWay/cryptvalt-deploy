# CryptValt Bug Bounty — Scope & Rewards (BOUNTY.md)

CryptValt invites security researchers to review our contracts. We pay
for responsibly disclosed vulnerabilities.

**Status:** Testnet phase (Sepolia). Rewards below apply to the testnet
program; a larger program launches with mainnet.

## In scope

All 8 contracts in `contracts/` at the commit tagged `v2.0`:

- CryptValt.sol (core escrow) — **highest priority**
- CryptValtRevenue.sol — **highest priority**
- CryptValtToken.sol
- CryptValtFounder.sol
- CryptValtMembership.sol
- CryptValtDAO.sol
- CryptValtGovernor.sol
- CryptValtValuation.sol

## Severity & rewards (testnet program)

| Severity | Examples | Reward |
|---|---|---|
| Critical | Theft or permanent freezing of user escrow/deposits; breaking the solvency invariant; bypassing the multisig | $1,000 – $2,500 |
| High | Theft of yield/revenue entitlements; settlement DoS; privilege escalation | $500 – $1,000 |
| Medium | Griefing with material cost to users; accounting drift; timelock bypass of non-fund parameters | $100 – $500 |
| Low | Gas inefficiencies with security relevance; event/accounting mismatches | $25 – $100 |

Rewards are at the team's discretion within bands, based on impact and
report quality. First valid report of an issue is rewarded.

## Out of scope

- The documented DAO live-voting-power limitation (BUGS.md KL-001)
- Issues requiring a compromised admin Safe (2-of-2) as a precondition
- Frontend, infrastructure, and off-chain services (separate program later)
- Findings from automated tools without a demonstrated exploit path
- Gas optimizations without security impact
- Already-known issues listed in BUGS.md

## Rules

1. Report privately first; allow 30 days for remediation before any
   public disclosure.
2. No testing against contracts holding real user funds on mainnet;
   use Sepolia or a local fork.
3. No social engineering, phishing, or attacks on team members/users.
4. One vulnerability per report, with reproduction steps (a failing
   Hardhat test is the gold standard and earns the top of the band).

## How to report

Email the team (address published on the site's security page) with:
severity estimate, affected contract + function, description, impact,
and reproduction steps or PoC test.

We acknowledge within 72 hours and aim to triage within 7 days.
