const { ethers } = require("hardhat");
async function main() {
  const [d] = await ethers.getSigners();
  const SAFE = process.env.SAFE_ADDRESS, TREASURY = process.env.TREASURY_ADDRESS || SAFE;
  if (!SAFE) throw new Error("SAFE_ADDRESS missing");
  console.log("Deployer:", d.address);
  const C = await ethers.getContractFactory("CryptValt");
  const c = await C.deploy(SAFE, TREASURY, 2000);
  await c.waitForDeployment();
  console.log("NEW CryptValt:", await c.getAddress());
}
main().catch(e => { console.error(e); process.exitCode = 1; });