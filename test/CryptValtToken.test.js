const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtToken", function () {
  it("Should deploy and mint total supply to owner", async function () {
    const [owner] = await ethers.getSigners();
    const Token = await ethers.getContractFactory("CryptValtToken");
    const token = await Token.deploy(owner.address);
    await token.waitForDeployment();

    const totalSupply = await token.TOTAL_SUPPLY();
    expect(await token.balanceOf(owner.address)).to.equal(totalSupply);
  });

  it("Should transfer tokens", async function () {
    const [owner, addr1] = await ethers.getSigners();
    const Token = await ethers.getContractFactory("CryptValtToken");
    const token = await Token.deploy(owner.address);
    await token.waitForDeployment();

    await token.transfer(addr1.address, 1000);
    expect(await token.balanceOf(addr1.address)).to.equal(1000);
  });

  it("Should stake and unstake", async function () {
    const [owner, addr1] = await ethers.getSigners();
    const Token = await ethers.getContractFactory("CryptValtToken");
    const token = await Token.deploy(owner.address);
    await token.waitForDeployment();

    await token.transfer(addr1.address, 10000);
    await token.connect(addr1).stake(5000);
    expect(await token.stakedBalance(addr1.address)).to.equal(5000);
    expect(await token.balanceOf(addr1.address)).to.equal(5000);

    await token.connect(addr1).unstake(2000);
    expect(await token.stakedBalance(addr1.address)).to.equal(3000);
    expect(await token.balanceOf(addr1.address)).to.equal(7000);
  });
});