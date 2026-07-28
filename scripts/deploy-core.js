/**
 * CryptValt — Core-only redeploy (v2.1)
 *
 * Redeploys CryptValt.sol alone, leaving the other seven contracts in
 * place. Writes the new address AND the exact constructor arguments to
 * deployed-core.json, because Etherscan verification fails unless the
 * arguments match byte for byte — and the previous version of this
 * script only printed the address to the console.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-core.js --network sepolia
 */

const { ethers } = require("hardhat");
const fs   = require("fs");
const path = require("path");

const PLATFORM_FEE_BPS = 2000; // 20% platform / 80% inventor

async function main() {
  const [deployer] = await ethers.getSigners();

  const SAFE     = process.env.SAFE_ADDRESS;
  const TREASURY = process.env.TREASURY_ADDRESS || SAFE;
  if (!SAFE) throw new Error("SAFE_ADDRESS missing from .env");

  console.log("Deployer:", deployer.address);
  console.log("Safe:    ", SAFE);
  console.log("Treasury:", TREASURY);
  console.log("Fee bps: ", PLATFORM_FEE_BPS);

  const Factory = await ethers.getContractFactory("CryptValt");
  const core    = await Factory.deploy(SAFE, TREASURY, PLATFORM_FEE_BPS);
  await core.waitForDeployment();

  const address = await core.getAddress();
  const tx      = core.deploymentTransaction();
  const net     = await ethers.provider.getNetwork();

  const record = {
    contract:        "CryptValt",
    address,
    network:         net.name,
    chainId:         Number(net.chainId),
    deployer:        deployer.address,
    txHash:          tx ? tx.hash : null,
    constructorArgs: [SAFE, TREASURY, PLATFORM_FEE_BPS],
    compiler:        "0.8.28",
    optimizerRuns:   1,
    viaIR:           true,
    evmVersion:      "cancun",
    deployedAt:      new Date().toISOString(),
  };

  const outPath = path.join(__dirname, "..", "deployed-core.json");
  fs.writeFileSync(outPath, JSON.stringify(record, null, 2));

  console.log("\nNEW CryptValt:", address);
  console.log("Saved to:", outPath);
  console.log("\nVerify with:");
  console.log(`  npx hardhat verify --network sepolia ${address} ${SAFE} ${TREASURY} ${PLATFORM_FEE_BPS}`);
  console.log("\nThen update, in this order:");
  console.log("  1. docs/ADDRESSES.md  — new address; move the old one to Retired");
  console.log("  2. public/index.html  — CONFIG.CONTRACTS.CRYPTVALT");
  console.log("  3. Railway env        — CRYPTVALT_ADDRESS");
  console.log("  4. Safe               — re-run the 2 wiring calls (governor, valuation)");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
