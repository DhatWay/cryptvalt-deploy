# CryptValt — Address Registry (ADDRESSES.md)

Single source of truth for platform-controlled addresses. If any address
in code, docs, or configuration disagrees with this file, this file wins
and the other location is stale.

## Custody

| Role | Address | Notes |
|---|---|---|
| **CryptValt Safe (2-of-2 multisig)** | `0xE5EF58bC03468909a72248EdB5dE1d17d66E576C` | "Mekkah's Vote SAFE". THE admin. Owns/administers all v2.0 contracts, gates backend admin endpoints (`OWNER_WALLET`), receives platform fees. Both signatures below are required for every action. |
| Signer 1 — CryptValt Second Vote | `0x205B0eA398825eE9A723A3C55026c7ceae618D5f` | One of the two Safe owners. Never appears in code. |
| Signer 2 — Mekkah's Vote | `0x685A63cf9A410B906f7404CFA79575530f52191c` | One of the two Safe owners. Never appears in code. |

## Retired / do not use

| Address | Status |
|---|---|
| `0x640B8140cD4FB3CDA81c91D5C733C40d5509Cd56` | Former wallet once labeled as the Safe in site code; not multisig-capable. Removed from all code July 2026. If found anywhere, replace with the Safe address above. |
| `0x8BF1e2e8Fd235D37a3D461C9a19C037313EA02c5` | "CryptValt Safe Wallet" — ordinary wallet, not the Safe contract. Not used in code. |

## Where the Safe address must appear

- `public/index.html` → `CONFIG.OWNER_WALLET`
- `public/promo/index.html` and `public/promo/outreach.html`
- Railway environment variable `OWNER_WALLET`
- v2.0 contract deployment: `.env` → `SAFE_ADDRESS` (constructor admin of
  CryptValt core; Ownable2Step transfer target for the other seven)

## Deployed contracts (v2.0)

_To be filled in at Sepolia deployment — one row per contract with
address and deployment tx._

| Contract | Network | Address |
|---|---|---|
| CryptValt | Sepolia | _pending_ |
| CryptValtToken | Sepolia | _pending_ |
| CryptValtFounder | Sepolia | _pending_ |
| CryptValtMembership | Sepolia | _pending_ |
| CryptValtRevenue | Sepolia | _pending_ |
| CryptValtGovernor | Sepolia | _pending_ |
| CryptValtValuation | Sepolia | _pending_ |
| CryptValtDAO | Sepolia | _pending_ |
