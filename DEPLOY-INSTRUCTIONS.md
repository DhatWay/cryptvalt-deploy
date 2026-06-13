# CryptValt — Contract Deployment Instructions
## Using Gitpod (works from any tablet or phone browser)

---

## BEFORE YOU START

You need:
- Your MetaMask private key for CryptValt Founder wallet
- Sepolia test ETH in that wallet (already done)
- A Gitpod account (free, sign up with GitHub)

---

## STEP 1 — Push this folder to GitHub

1. Create a new GitHub repository called **cryptvalt-deploy**
2. Make it PRIVATE — never public (contains your contract code)
3. Upload all files from this folder to that repo
4. Do NOT upload a .env file — keep that local only

---

## STEP 2 — Open Gitpod

1. Go to **gitpod.io** in your browser
2. Sign in with GitHub
3. Click **New Workspace**
4. Paste your repo URL: `https://github.com/DhatWay/cryptvalt-deploy`
5. Click **Continue**
6. Wait for the workspace to load (about 1-2 minutes)

---

## STEP 3 — Set environment variables in Gitpod

1. In Gitpod, click the **hamburger menu** (top left)
2. Go to **Gitpod** → **User Settings** → **Variables**
3. Add these variables one by one:

| Name | Value |
|------|-------|
| `PRIVATE_KEY` | Your MetaMask private key (see below how to get it) |
| `ALCHEMY_SEPOLIA` | `https://eth-sepolia.g.alchemy.com/v2/d9dDJRLcCVtzyTu2URTDk` |
| `ALCHEMY_MAINNET` | `https://eth-mainnet.g.alchemy.com/v2/d9dDJRLcCVtzyTu2URTDk` |
| `ETHERSCAN_API_KEY` | `M8IFB7DY77BTGUXX78SXCE48JJMRBBSTIA` |

**HOW TO GET YOUR PRIVATE KEY FROM METAMASK:**
1. Open MetaMask
2. Select CryptValt Founder account
3. Tap the three dots menu
4. Tap Account Details
5. Tap Export Private Key
6. Enter your MetaMask password
7. Copy the key — it starts with a long string of letters and numbers
8. Paste it as the PRIVATE_KEY value in Gitpod
9. **DELETE IT FROM GITPOD IMMEDIATELY AFTER DEPLOYMENT**

---

## STEP 4 — Install dependencies

In the Gitpod terminal type:
```
npm install
```
Wait for it to finish. Takes about 1-2 minutes.

---

## STEP 5 — Compile contracts

```
npm run compile
```
You should see all 8 contracts compile successfully.

---

## STEP 6 — Deploy to Sepolia

```
npm run deploy:sepolia
```

This will:
- Deploy all 8 contracts in the correct order
- Print each contract address as it deploys
- Save all addresses to deployed-addresses.json
- Automatically verify all contracts on Etherscan

Takes about 10-15 minutes total.

---

## STEP 7 — Copy the addresses

When deployment finishes you'll see a file called **deployed-addresses.json** in the file explorer. Open it and copy the addresses. It looks like:

```json
{
  "addresses": {
    "CRYPTVALT_TOKEN":      "0x...",
    "CRYPTVALT_GOVERNOR":   "0x...",
    "CRYPTVALT_VALUATION":  "0x...",
    "CRYPTVALT_MEMBERSHIP": "0x...",
    "CRYPTVALT_FOUNDER":    "0x...",
    "CRYPTVALT":            "0x...",
    "CRYPTVALT_REVENUE":    "0x...",
    "CRYPTVALT_DAO":        "0x..."
  }
}
```

Send these addresses to Claude and the config.js will be updated automatically.

---

## STEP 8 — Delete your private key

IMMEDIATELY after deployment:
1. Go to Gitpod User Settings → Variables
2. Delete the PRIVATE_KEY variable
3. Done — your key is no longer stored anywhere

---

## STEP 9 — Update config.js

Send the deployed-addresses.json contents to Claude.
Claude will update JS/config.js with all the contract addresses.
Push the updated config.js to your CryptValt GitHub repo.
The platform is now live on Sepolia testnet.

---

## FOR MAINNET DEPLOYMENT (after Sepolia testing is complete)

1. In hardhat.config.js — uncomment the mainnet network section
2. Make sure you have real ETH in your wallet ($500-2000 for gas)
3. Run: `npm run deploy:mainnet`
4. Same process as above

---

## TROUBLESHOOTING

**"Insufficient funds" error:**
Get more Sepolia test ETH from faucet.alchemy.com

**"Contract already deployed" error:**
Contracts deployed successfully — check deployed-addresses.json

**Verification fails:**
Not a problem — contracts are deployed even if verification fails.
You can verify manually later on sepolia.etherscan.io

**Any other error:**
Copy the error message and send it to Claude.
