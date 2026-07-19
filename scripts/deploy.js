/*
 * CryptValt v2.0 — Full Deployment Script
 *
 * Deploys all 8 contracts in dependency order, wires them together,
 * and (when SAFE_ADDRESS is set) hands admin control to your 2-of-2
 * Gnosis Safe.
 *
 * Local dry run:   npx hardhat run scripts/deploy.js
 * Sepolia:         npx hardhat run scripts/deploy.js --network sepolia
 *
 * Environment (.env):
 *   SAFE_ADDRESS     = 0x...   your 2-of-2 Safe (REQUIRED for testnet/mainnet)
 *   TREASURY_ADDRESS = 0x...   defaults to SAFE_ADDRESS if unset
 *   SEPOLIA_RPC_URL  = https://...
 *   PRIVATE_KEY      = deployer key (never commit this file!)
 */

const { ethers, network } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`\nDeploying CryptValt v2.0 on ${network.name}`);
  console.log(`Deployer: ${deployer.address}\n`);

  const SAFE = process.env.SAFE_ADDRESS || deployer.address;
  const TREASURY = process.env.TREASURY_ADDRESS || SAFE;
  const PLATFORM_FEE_BPS = 2000; // 20%

  if (network.name !== "hardhat" && !process.env.SAFE_ADDRESS) {
    throw new Error(
      "SAFE_ADDRESS is not set. Refusing to deploy to a real network " +
      "without the 2-of-2 Safe as admin."
    );
  }

  const addresses = {};

  // 1. Core escrow — Safe is admin from block one (no transfer needed).
  const CryptValt = await ethers.getContractFactory("CryptValt");
  const cryptvalt = await CryptValt.deploy(SAFE, TREASURY, PLATFORM_FEE_BPS);
  await cryptvalt.waitForDeployment();
  addresses.CryptValt = await cryptvalt.getAddress();
  console.log(`1/8 CryptValt          ${addresses.CryptValt}`);

  // 2. Token — deployer holds supply for distribution; ownership moves
  //    to the Safe via two-step below.
  const Token = await ethers.getContractFactory("CryptValtToken");
  const token = await Token.deploy(deployer.address, TREASURY);
  await token.waitForDeployment();
  addresses.CryptValtToken = await token.getAddress();
  console.log(`2/8 CryptValtToken     ${addresses.CryptValtToken}`);

  // 3. Founder NFT
  const Founder = await ethers.getContractFactory("CryptValtFounder");
  const founder = await Founder.deploy(deployer.address, TREASURY);
  await founder.waitForDeployment();
  addresses.CryptValtFounder = await founder.getAddress();
  console.log(`3/8 CryptValtFounder   ${addresses.CryptValtFounder}`);

  // 4. Membership NFT
  const Membership = await ethers.getContractFactory("CryptValtMembership");
  const membership = await Membership.deploy(deployer.address, TREASURY);
  await membership.waitForDeployment();
  addresses.CryptValtMembership = await membership.getAddress();
  console.log(`4/8 CryptValtMembership ${addresses.CryptValtMembership}`);

  // 5. Revenue router
  const Revenue = await ethers.getContractFactory("CryptValtRevenue");
  const revenue = await Revenue.deploy(deployer.address, TREASURY);
  await revenue.waitForDeployment();
  addresses.CryptValtRevenue = await revenue.getAddress();
  console.log(`5/8 CryptValtRevenue   ${addresses.CryptValtRevenue}`);

  // 6. Governor (reputation engine)
  const Governor = await ethers.getContractFactory("CryptValtGovernor");
  const governor = await Governor.deploy(deployer.address, addresses.CryptValt);
  await governor.waitForDeployment();
  addresses.CryptValtGovernor = await governor.getAddress();
  console.log(`6/8 CryptValtGovernor  ${addresses.CryptValtGovernor}`);

  // 7. Valuation oracle
  const Valuation = await ethers.getContractFactory("CryptValtValuation");
  const valuation = await Valuation.deploy(deployer.address, addresses.CryptValt);
  await valuation.waitForDeployment();
  addresses.CryptValtValuation = await valuation.getAddress();
  console.log(`7/8 CryptValtValuation ${addresses.CryptValtValuation}`);

  // 8. DAO
  const DAO = await ethers.getContractFactory("CryptValtDAO");
  const dao = await DAO.deploy(
    deployer.address,
    addresses.CryptValtToken,
    addresses.CryptValtFounder,
    TREASURY
  );
  await dao.waitForDeployment();
  addresses.CryptValtDAO = await dao.getAddress();
  console.log(`8/8 CryptValtDAO       ${addresses.CryptValtDAO}\n`);

  // ── Wiring ──────────────────────────────────────────────────────
  console.log("Wiring contracts together...");
  // Core → Governor + Valuation. NOTE: these are DEFAULT_ADMIN calls on
  // CryptValt; since the Safe is admin, on a real network these two
  // must be executed FROM THE SAFE (via the Safe app's transaction
  // builder). On local hardhat, deployer == SAFE so they work directly.
  if (SAFE === deployer.address) {
    await (await cryptvalt.setGovernorContract(addresses.CryptValtGovernor)).wait();
    await (await cryptvalt.setValuationContract(addresses.CryptValtValuation)).wait();
    console.log("  CryptValt → governor/valuation wired");
  } else {
    console.log("  ACTION REQUIRED (from your Safe):");
    console.log(`    CryptValt.setGovernorContract(${addresses.CryptValtGovernor})`);
    console.log(`    CryptValt.setValuationContract(${addresses.CryptValtValuation})`);
  }

  await (await token.setCryptValt(addresses.CryptValt)).wait();
  await (await revenue.setCryptValt(addresses.CryptValt)).wait();
  await (await revenue.setMembership(addresses.CryptValtMembership)).wait();
  await (await revenue.setFounder(addresses.CryptValtFounder)).wait();
  console.log("  Token + Revenue wired");

  // ── Hand ownership to the Safe (two-step) ───────────────────────
  if (SAFE !== deployer.address) {
    console.log("\nStarting two-step ownership transfer to the Safe...");
    for (const [name, c] of [
      ["Token", token], ["Founder", founder], ["Membership", membership],
      ["Revenue", revenue], ["Governor", governor], ["Valuation", valuation],
      ["DAO", dao],
    ]) {
      await (await c.transferOwnership(SAFE)).wait();
      console.log(`  ${name}: transfer initiated`);
    }
    console.log(
      "\n  ACTION REQUIRED: from the Safe, call acceptOwnership() on each" +
      "\n  of the 7 contracts above to complete the two-step transfer." +
      "\n  (CryptValt core needs no transfer — the Safe is already admin.)"
    );
  }

  console.log("\n=== Deployment complete — save these addresses ===");
  console.log(JSON.stringify(addresses, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
