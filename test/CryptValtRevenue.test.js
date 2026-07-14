const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtRevenue", function () {
  let revenue, owner, treasury, addr1, addr2;

  beforeEach(async function () {
    [owner, treasury, addr1, addr2] = await ethers.getSigners();
    const Revenue = await ethers.getContractFactory("CryptValtRevenue");
    revenue = await Revenue.deploy(treasury.address);
    await revenue.waitForDeployment();
  });

  it("Should deposit revenue and distribute", async function () {
    await revenue.deposit({ value: ethers.parseEther("1") });
    const stats = await revenue.getStats();
    expect(stats[0]).to.equal(ethers.parseEther("1"));
  });

  it("Should register and pay scout", async function () {
    const listingId = 1;
    await revenue.registerScout(listingId, addr1.address);
    await revenue.payScout(listingId, ethers.parseEther("10"));
    const scoutStats = await revenue.getScoutStats(addr1.address);
    expect(scoutStats[2]).to.be.gt(0);
  });

  it("Should allow scout to claim", async function () {
    const listingId = 1;
    await revenue.registerScout(listingId, addr1.address);
    await revenue.payScout(listingId, ethers.parseEther("10"));

    await revenue.registerPlatinumHolder(addr2.address, 1);
    await revenue.registerFounderHolder(addr2.address, 1);
    await revenue.deposit({ value: ethers.parseEther("10") });

    const balanceBefore = await ethers.provider.getBalance(addr1.address);
    await revenue.connect(addr1).claimScout();
    const balanceAfter = await ethers.provider.getBalance(addr1.address);
    expect(balanceAfter).to.be.gt(balanceBefore);
  });
});