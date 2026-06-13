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
const OWNER_WALLET = '0x05248CD920dAeB2E5369A63Fe93367f9F1bf5677';

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

  const addresses = {};

  // ══════════════════════════════════════════════════════
  // 1. CryptValtToken — CVT ERC-20
  //    constructor(address _treasury)
  // ══════════════════════════════════════════════════════
  console.log('1/8 Deploying CryptValtToken...');
  const Token = await ethers.getContractFactory('CryptValtToken');
  const token = await Token.deploy(OWNER_WALLET);
  await token.waitForDeployment();
  addresses.CRYPTVALT_TOKEN = await token.getAddress();
  console.log(`    ✓ CryptValtToken: ${addresses.CRYPTVALT_TOKEN}\n`);

  // ══════════════════════════════════════════════════════
  // 2. CryptValtGovernor — Reputation system
  //    constructor(address _platform)
  // ══════════════════════════════════════════════════════
  console.log('2/8 Deploying CryptValtGovernor...');
  const Governor = await ethers.getContractFactory('CryptValtGovernor');
  const governor = await Governor.deploy(OWNER_WALLET);
  await governor.waitForDeployment();
  addresses.CRYPTVALT_GOVERNOR = await governor.getAddress();
  console.log(`    ✓ CryptValtGovernor: ${addresses.CRYPTVALT_GOVERNOR}\n`);

  // ══════════════════════════════════════════════════════
  // 3. CryptValtValuation — Pricing algorithm
  //    constructor(address _platform)
  // ══════════════════════════════════════════════════════
  console.log('3/8 Deploying CryptValtValuation...');
  const Valuation = await ethers.getContractFactory('CryptValtValuation');
  const valuation = await Valuation.deploy(OWNER_WALLET);
  await valuation.waitForDeployment();
  addresses.CRYPTVALT_VALUATION = await valuation.getAddress();
  console.log(`    ✓ CryptValtValuation: ${addresses.CRYPTVALT_VALUATION}\n`);

  // ══════════════════════════════════════════════════════
  // 4. CryptValtMembership — NFT membership tiers
  //    constructor(address _treasury)
  // ══════════════════════════════════════════════════════
  console.log('4/8 Deploying CryptValtMembership...');
  const Membership = await ethers.getContractFactory('CryptValtMembership');
  const membership = await Membership.deploy(OWNER_WALLET);
  await membership.waitForDeployment();
  addresses.CRYPTVALT_MEMBERSHIP = await membership.getAddress();
  console.log(`    ✓ CryptValtMembership: ${addresses.CRYPTVALT_MEMBERSHIP}\n`);

  // ══════════════════════════════════════════════════════
  // 5. CryptValtFounder — Genesis Founder NFTs
  //    constructor(address _treasury)
  // ══════════════════════════════════════════════════════
  console.log('5/8 Deploying CryptValtFounder...');
  const Founder = await ethers.getContractFactory('CryptValtFounder');
  const founder = await Founder.deploy(OWNER_WALLET);
  await founder.waitForDeployment();
  addresses.CRYPTVALT_FOUNDER = await founder.getAddress();
  console.log(`    ✓ CryptValtFounder: ${addresses.CRYPTVALT_FOUNDER}\n`);

  // ══════════════════════════════════════════════════════
  // 6. CryptValt — Core protocol (main contract)
  //    constructor(address _wallet, uint256 _fee)
  // ══════════════════════════════════════════════════════
  console.log('6/8 Deploying CryptValt (core)...');
  const CryptValt = await ethers.getContractFactory('CryptValt');
  const cryptvalt = await CryptValt.deploy(OWNER_WALLET, PLATFORM_FEE);
  await cryptvalt.waitForDeployment();
  addresses.CRYPTVALT = await cryptvalt.getAddress();
  console.log(`    ✓ CryptValt: ${addresses.CRYPTVALT}\n`);

  // ══════════════════════════════════════════════════════
  // 7. CryptValtRevenue — Revenue distribution
  //    constructor(address _treasury)
  // ══════════════════════════════════════════════════════
  console.log('7/8 Deploying CryptValtRevenue...');
  const Revenue = await ethers.getContractFactory('CryptValtRevenue');
  const revenue = await Revenue.deploy(OWNER_WALLET);
  await revenue.waitForDeployment();
  addresses.CRYPTVALT_REVENUE = await revenue.getAddress();
  console.log(`    ✓ CryptValtRevenue: ${addresses.CRYPTVALT_REVENUE}\n`);

  // ══════════════════════════════════════════════════════
  // 8. CryptValtDAO — DAO governance
  //    constructor(address _cvt, address _founder, address _treasury)
  // ══════════════════════════════════════════════════════
  console.log('8/8 Deploying CryptValtDAO...');
  const DAO = await ethers.getContractFactory('CryptValtDAO');
  const dao = await DAO.deploy(
    addresses.CRYPTVALT_TOKEN,    // CVT token address
    addresses.CRYPTVALT_FOUNDER,  // Founder NFT address
    OWNER_WALLET                  // Treasury
  );
  await dao.waitForDeployment();
  addresses.CRYPTVALT_DAO = await dao.getAddress();
  console.log(`    ✓ CryptValtDAO: ${addresses.CRYPTVALT_DAO}\n`);

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
