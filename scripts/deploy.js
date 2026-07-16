/**
 * CryptValt — Full Deployment Script
 *
 * Deploys all 8 contracts in dependency order.
 * Automatically verifies each contract on Etherscan.
 * Saves all deployed addresses to deployed-addresses.json.
 *
 * RUN ON SEPOLIA:
 *   npm run deploy:sepolia
 *
 * RUN ON MAINNET (after audit):
 *   npm run deploy:mainnet
 */

const { ethers, run, network } = require('hardhat');
const fs = require('fs');

// ── Your wallet address — receives platform fees ───────────
const OWNER_WALLET = '0x640B8140cD4FB3CDA81c91D5C733C40d5509Cd56'; // CryptValt Safe (2-of-2 multisig)

// ── Platform fee — 20% in basis points (2000 = 20%) ───────
const PLATFORM_FEE = 2000;

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log('\n╔════════════════════════════════════════╗');
  console.log('║     CRYPTVALT CONTRACT DEPLOYMENT      ║');
  console.log('╚════════════════════════════════════════╝\n');
  console.log(`Network:   ${network.name}`);
  console.log(`Deployer:  ${deployer.address}`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance:   ${ethers.formatEther(balance)} ETH`);
  console.log('');

  if (balance === 0n) {
    console.error('ERROR: No ETH in deployer wallet. Get Sepolia test ETH first.');
    process.exit(1);
  }

  // ── Resume support: load any already-deployed addresses ──
  // so a rerun (e.g. after running out of gas) never wastes gas
  // redeploying contracts that already succeeded.
  const SAVE_FILE = 'deployed-addresses.json';
  let addresses = {};
  if (fs.existsSync(SAVE_FILE)) {
    try {
      const prev = JSON.parse(fs.readFileSync(SAVE_FILE, 'utf8'));
      if (prev.network === network.name && prev.addresses) {
        addresses = prev.addresses;
        console.log(`Resuming — found ${Object.keys(addresses).length} already-deployed contract(s) on ${network.name}.\n`);
      }
    } catch(e) { /* ignore unreadable/old file, start fresh */ }
  }

  async function deployIfNeeded(step, key, label, factoryName, args) {
    if (addresses[key]) {
      console.log(`${step}/8 ${label} already deployed — skipping. (${addresses[key]})\n`);
      return;
    }
    console.log(`${step}/8 Deploying ${label}...`);
    const Factory = await ethers.getContractFactory(factoryName);
    const instance = await Factory.deploy(...args);
    await instance.waitForDeployment();
    addresses[key] = await instance.getAddress();
    console.log(`    ✓ ${label}: ${addresses[key]}\n`);
    fs.writeFileSync(SAVE_FILE, JSON.stringify({ network: network.name, deployedAt: new Date().toISOString(), deployer: deployer.address, addresses }, null, 2));
  }

  // ══════════════════════════════════════════════════════
  // 1. CryptValtToken — CVT ERC-20
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(1, 'CRYPTVALT_TOKEN', 'CryptValtToken', 'CryptValtToken', [OWNER_WALLET]);

  // ══════════════════════════════════════════════════════
  // 2. CryptValtGovernor — Reputation system
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(2, 'CRYPTVALT_GOVERNOR', 'CryptValtGovernor', 'CryptValtGovernor', [OWNER_WALLET]);

  // ══════════════════════════════════════════════════════
  // 3. CryptValtValuation — Pricing algorithm
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(3, 'CRYPTVALT_VALUATION', 'CryptValtValuation', 'CryptValtValuation', [OWNER_WALLET]);

  // ══════════════════════════════════════════════════════
  // 4. CryptValtMembership — NFT membership tiers
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(4, 'CRYPTVALT_MEMBERSHIP', 'CryptValtMembership', 'CryptValtMembership', [OWNER_WALLET]);

  // ══════════════════════════════════════════════════════
  // 5. CryptValtFounder — Genesis Founder NFTs
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(5, 'CRYPTVALT_FOUNDER', 'CryptValtFounder', 'CryptValtFounder', [OWNER_WALLET]);

  // ══════════════════════════════════════════════════════
  // 6. CryptValt — Core protocol (main contract)
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(6, 'CRYPTVALT', 'CryptValt (core)', 'CryptValt', [OWNER_WALLET, PLATFORM_FEE]);

  // ══════════════════════════════════════════════════════
  // 7. CryptValtRevenue — Revenue distribution
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(7, 'CRYPTVALT_REVENUE', 'CryptValtRevenue', 'CryptValtRevenue', [OWNER_WALLET]);

  // ══════════════════════════════════════════════════════
  // 8. CryptValtDAO — DAO governance
  // ══════════════════════════════════════════════════════
  await deployIfNeeded(8, 'CRYPTVALT_DAO', 'CryptValtDAO', 'CryptValtDAO', [
    addresses.CRYPTVALT_TOKEN,
    addresses.CRYPTVALT_FOUNDER,
    OWNER_WALLET,
  ]);

  // ══════════════════════════════════════════════════════
  // SAVE ADDRESSES
  // ══════════════════════════════════════════════════════
  const output = {
    network:     network.name,
    deployedAt:  new Date().toISOString(),
    deployer:    deployer.address,
    addresses,
  };

  fs.writeFileSync('deployed-addresses.json', JSON.stringify(output, null, 2));

  console.log('╔════════════════════════════════════════╗');
  console.log('║         ALL CONTRACTS DEPLOYED         ║');
  console.log('╚════════════════════════════════════════╝\n');
  console.log('Addresses saved to: deployed-addresses.json\n');
  console.log(JSON.stringify(addresses, null, 2));

  // ══════════════════════════════════════════════════════
  // ETHERSCAN VERIFICATION
  // ══════════════════════════════════════════════════════
  console.log('\n\nVerifying contracts on Etherscan...');
  console.log('(Waiting 30 seconds for blockchain to index...)\n');
  await sleep(30000);

  const toVerify = [
    { name: 'CryptValtToken',     address: addresses.CRYPTVALT_TOKEN,      args: [OWNER_WALLET] },
    { name: 'CryptValtGovernor',  address: addresses.CRYPTVALT_GOVERNOR,   args: [OWNER_WALLET] },
    { name: 'CryptValtValuation', address: addresses.CRYPTVALT_VALUATION,  args: [OWNER_WALLET] },
    { name: 'CryptValtMembership',address: addresses.CRYPTVALT_MEMBERSHIP, args: [OWNER_WALLET] },
    { name: 'CryptValtFounder',   address: addresses.CRYPTVALT_FOUNDER,    args: [OWNER_WALLET] },
    { name: 'CryptValt',          address: addresses.CRYPTVALT,            args: [OWNER_WALLET, PLATFORM_FEE] },
    { name: 'CryptValtRevenue',   address: addresses.CRYPTVALT_REVENUE,    args: [OWNER_WALLET] },
    { name: 'CryptValtDAO',       address: addresses.CRYPTVALT_DAO,        args: [addresses.CRYPTVALT_TOKEN, addresses.CRYPTVALT_FOUNDER, OWNER_WALLET] },
  ];

  for (const contract of toVerify) {
    try {
      console.log(`Verifying ${contract.name}...`);
      await run('verify:verify', {
        address:              contract.address,
        constructorArguments: contract.args,
      });
      console.log(`✓ ${contract.name} verified\n`);
    } catch(e) {
      if (e.message.includes('Already Verified')) {
        console.log(`✓ ${contract.name} already verified\n`);
      } else {
        console.log(`✗ ${contract.name} verification failed: ${e.message}\n`);
      }
    }
    await sleep(3000);
  }

  console.log('\n╔════════════════════════════════════════╗');
  console.log('║            DEPLOYMENT COMPLETE         ║');
  console.log('╚════════════════════════════════════════╝');
  console.log('\nNext step: Copy addresses from deployed-addresses.json');
  console.log('into JS/config.js in your CryptValt frontend repo.\n');
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
