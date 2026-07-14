const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtGovernor", function () {
  let governor, owner, platform, addr1;

  beforeEach(async function () {
    [owner, platform, addr1] = await ethers.getSigners();
    const Governor = await ethers.getContractFactory("CryptValtGovernor");
    governor = await Governor.deploy(platform.address);
    await governor.waitForDeployment();
  });

  it("Should initialize with default reputation", async function () {
    const rep = await governor.getReputation(addr1.address);
    expect(rep).to.equal(500);
  });

  it("Should allow platform to update reputation on listing", async function () {
    await governor.connect(platform).onListingCreated(1, addr1.address);
    const rep = await governor.reputation(addr1.address);
    expect(rep).to.equal(500);
  });

  it("Should allow owner to verify wallet", async function () {
    await governor.connect(owner).verifyWallet(addr1.address);
    expect(await governor.verified(addr1.address)).to.be.true;
    expect(await governor.reputation(addr1.address)).to.equal(650);
  });

  it("Should allow platform to add reputation on auction settled", async function () {
    await governor.connect(platform).onAuctionSettled(1, addr1.address, 100);
    const rep = await governor.reputation(addr1.address);
    expect(rep).to.equal(550);
  });
});