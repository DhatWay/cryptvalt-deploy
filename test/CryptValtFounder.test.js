const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtFounder", function () {
  it("Should deploy and mint a Founder NFT", async function () {
    const [owner, addr1] = await ethers.getSigners();
    const Founder = await ethers.getContractFactory("CryptValtFounder");
    const founder = await Founder.deploy(owner.address);
    await founder.waitForDeployment();

    await founder.openMint();
    await founder.connect(addr1).mint({ value: ethers.parseEther("1") });

    expect(await founder.balanceOf(addr1.address)).to.equal(1);
    expect(await founder.ownerOf(1)).to.equal(addr1.address);
  });
});