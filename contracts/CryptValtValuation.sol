const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtValuation", function () {
  let valuation, owner, platform, addr1;

  beforeEach(async function () {
    [owner, platform, addr1] = await ethers.getSigners();
    const Valuation = await ethers.getContractFactory("CryptValtValuation");
    valuation = await Valuation.deploy(platform.address);
    await valuation.waitForDeployment();
  });

  it("Should initialize with default category multipliers", async function () {
    expect(await valuation.catMult("tech")).to.equal(16000);
    expect(await valuation.catMult("health")).to.equal(19000);
    expect(await valuation.catMult("finance")).to.equal(17500);
  });

  it("Should record a sale and update category average", async function () {
    await valuation.connect(platform).recordSale("tech", 1000);
    const avg = await valuation.catAvg("tech");
    expect(avg).to.equal(1000);
    expect(await valuation.totalSales()).to.equal(1);
  });

  it("Should store valuation for an ID", async function () {
    await valuation.connect(platform).storeVal(1, 100, 200, 300);
    const val = await valuation.getVal(1);
    expect(val[0]).to.equal(100);
    expect(val[1]).to.equal(200);
    expect(val[2]).to.equal(300);
  });

  it("Should estimate valuation", async function () {
    const [lo, mid, hi] = await valuation.estimate(80, "tech", 1000000);
    expect(mid).to.be.gt(0);
    expect(lo).to.be.lt(mid);
    expect(hi).to.be.gt(mid);
  });

  it("Should allow owner to update sentiment", async function () {
    await valuation.connect(owner).setSentiment(12000);
    expect(await valuation.sentiment()).to.equal(12000);
  });
});
