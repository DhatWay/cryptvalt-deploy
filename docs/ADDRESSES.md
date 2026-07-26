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

| `0xC47ea60026428Fe6DfDC23dE625fDaDFc47B35a4` | Original v2.0 CryptValt core — replaced by the v2.1 redeploy (reauction + archive). Do not use. |

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

Deployed July 2026 by `0x205B...8D5f` with the Safe as constructor admin
of the core; two-step ownership transfers to the Safe initiated for the
other seven.

| Contract | Network | Address |
|---|---|---|
| CryptValt | Sepolia | `0xb901af1956bfBB3CD40b41106DB6684412CD0846` |
| CryptValtToken | Sepolia | `0xDd770632715dEeB7550f66D7d464831B24885d58` |
| CryptValtFounder | Sepolia | `0xE42ad606468A09e06AB482992F8635A1B3Fd27b6` |
| CryptValtMembership | Sepolia | `0x625D86d014db3C56dEDD609e1de8b445564E5614` |
| CryptValtRevenue | Sepolia | `0x16EF394DF0021331EdB1e4ddAFfb9c67f4351830` |
| CryptValtGovernor | Sepolia | `0xd5bd72e3724Ae39A18CfE72D8e5CE2A4Bd951B9d` |
| CryptValtValuation | Sepolia | `0x7ecCA87785313F8CdD285F5c79235bB4e1268e78` |
| CryptValtDAO | Sepolia | `0x4370a034D896882aFBA7c036A3154a70c0606638` |