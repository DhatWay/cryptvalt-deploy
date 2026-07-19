# CryptValt v2.0 — Contracts, Tests & Deployment

Hardened, OpenZeppelin-based release of all 8 CryptValt contracts.

## What's in this package

```
contracts/   8 Solidity contracts (v2.0, OpenZeppelin edition)
test/        Full Hardhat test suite (no testnet needed)
scripts/     One-shot deploy script (local / Sepolia)
hardhat.config.js
package.json
```

## Running the tests (GitHub Codespaces, works on Android browser)

1. Open your Codespace, create a folder, and upload all files keeping
   the folder structure above.
2. In the terminal:

```bash
npm install
npx hardhat test
```

That's it — the tests run on Hardhat's built-in local network with fake
funded accounts. No Sepolia ETH, no faucet, no wallet needed.

## Local dry-run deployment

```bash
npx hardhat run scripts/deploy.js
```

## Sepolia deployment (with your 2-of-2 Safe)

1. Create a `.env` file (NEVER commit it):

```
SAFE_ADDRESS=0xYourSafeAddress
TREASURY_ADDRESS=0xYourSafeAddress
SEPOLIA_RPC_URL=https://rpc.sepolia.org
PRIVATE_KEY=0xYourDeployerKey
```

2. Deploy:

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

3. Follow the ACTION REQUIRED lines the script prints:
   - From the Safe: call `acceptOwnership()` on the 7 Ownable2Step
     contracts (Safe app → New transaction → Contract interaction).
   - From the Safe: call `setGovernorContract(...)` and
     `setValuationContract(...)` on the core CryptValt contract.

The core CryptValt contract takes the Safe as admin in its constructor,
so the multisig controls it from block one.

## v2.0 security changes (summary for your records)

| Contract    | Fixes |
|-------------|-------|
| CryptValt   | Collateralized sealed bids; O(1) settlement; pull-payments everywhere; 24h admin timelocks; 48h emergency-drain delay; solvency invariant; OZ AccessControlDefaultAdminRules/ReentrancyGuard/Pausable |
| Token       | Staking precision fix (1e18-scaled accumulator); real token escrow for staking/vesting; ERC20Permit; Ownable2Step |
| Founder     | Self-revenue fix; EIP-2981 royalties; OZ ERC721; Ownable2Step |
| Membership  | Self-revenue fix; EIP-2981; revenue-follows-token transfers; OZ ERC721; Ownable2Step |
| Revenue     | Per-token accounting (v1 overpaid multi-token holders); funded scout payouts; settle-before-remove; 1e18 precision |
| Governor    | Modernization only (no fund-safety issues found) |
| Valuation   | Modernization only |
| DAO         | Quorum supply snapshot; documented live-power limitation + v3 checkpoint plan |

## Known limitations (disclose these)

- DAO voting power is read live, not from checkpoints (documented in
  the contract; mitigations: one vote per wallet, Founder veto, target
  whitelist, 48h timelock). Migrate CVT to ERC20Votes before the DAO
  controls treasury funds.
- These contracts have undergone AI-assisted security review and
  automated testing, not a formal third-party audit.
