# CryptValt Security Overview (SECURITY.md)

This document describes the security posture of the CryptValt smart
contract suite, the controls in place, known limitations, and how to
report vulnerabilities.

## Honest status statement

The CryptValt v2.0 contracts have undergone:

- AI-assisted line-by-line security review and hardening
- A full regression test suite (28 tests) covering the complete
  marketplace lifecycle and every fixed vulnerability (see BUGS.md)
- Static analysis (Slither) as part of the development workflow

They have **not yet** received a formal third-party audit. A formal
audit is planned before mainnet handles significant value. Users should
understand and accept this risk before participating. We publish our
full bug history (BUGS.md) rather than hiding it.

## Foundation

All v2.0 contracts are built on OpenZeppelin Contracts v5 — the
industry-standard, professionally audited library securing the majority
of major Ethereum protocols:

| Contract | OpenZeppelin bases |
|---|---|
| CryptValt (core escrow) | AccessControlDefaultAdminRules, ReentrancyGuard, Pausable |
| CryptValtToken | ERC20, ERC20Permit, ERC20Burnable, Ownable2Step, Pausable, ReentrancyGuard |
| CryptValtFounder | ERC721, ERC721Enumerable, ERC2981, Ownable2Step, ReentrancyGuard |
| CryptValtMembership | ERC721, ERC721Enumerable, ERC2981, Ownable2Step, ReentrancyGuard |
| CryptValtRevenue | Ownable2Step, ReentrancyGuard |
| CryptValtGovernor | Ownable2Step |
| CryptValtValuation | Ownable2Step |
| CryptValtDAO | Ownable2Step, Pausable, ReentrancyGuard |

## Architecture-level protections

- **Pull-payment pattern everywhere.** No contract pushes ETH to
  arbitrary recipients during settlement; all payouts are queued and
  withdrawn by the recipient. A reverting recipient can never block
  the system.
- **On-chain solvency invariant.** `CryptValt.isSolvent()` publicly
  proves at any moment that the contract holds at least its total
  outstanding obligations.
- **Collateralized sealed bids.** A revealed bid must be fully covered
  by its deposit; the escrow always holds the winning bid in full.
- **O(1) settlement.** No unbounded loops on any critical path.
- **Timelocks.** Fee changes and platform-wallet changes: 24h.
  Emergency drain: only in emergency mode, after a 48h queued delay,
  cancellable. Admin (Safe) handover on the core contract: 24h
  two-step. DAO execution: 48h after queue, whitelisted targets only.

## Admin rights strategy

Admin control is held by a 2-of-2 Gnosis Safe multisig — no single key
can perform any privileged action.

- The core CryptValt contract takes the Safe as `DEFAULT_ADMIN` in its
  **constructor**: the multisig controls it from block one, with any
  future admin change requiring a two-step, 24h-delayed transfer
  (OpenZeppelin AccessControlDefaultAdminRules).
- The other 7 contracts use Ownable2Step: ownership transfer requires
  the Safe to actively accept, making a mistyped-address lockout
  impossible.
- What admin CAN do: pause, freeze abusive wallets/listings, resolve
  disputes, queue (timelocked) fee/wallet changes, configure tiers.
- What admin CANNOT do: take user escrow outside the timelocked
  emergency path, change fees outside the 10–30% hard bounds, mint
  extra CVT (fixed supply), or bypass the bid/settlement logic.

## Reporting a vulnerability

See BOUNTY.md for scope and rewards. Report privately to the team
before public disclosure; we commit to acknowledging reports within
72 hours.