const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtMembership", function () {
  it("Should deploy and mint Bronze", async function () {
    const [owner, addr1] = await ethers.getSigners();
    const Membership = await ethers.getContractFactory("CryptValtMembership");
    const membership = await Membership.deploy(owner.address);
    await membership.deployed();

    await membership.connect(addr1).mintBronze({ value: ethers.utils.parseEther("0.05") });

    expect(await membership.balanceOf(addr1.address)).to.equal(1);
    expect(await membership.tierOf(1)).to.equal(1);
  });
});