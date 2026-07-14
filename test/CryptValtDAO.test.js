const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValtDAO", function () {
  let dao, token, founder, owner, addr1, addr2;

  beforeEach(async function () {
    [owner, addr1, addr2] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("CryptValtToken");
    token = await Token.deploy(owner.address);
    await token.waitForDeployment();

    const Founder = await ethers.getContractFactory("CryptValtFounder");
    founder = await Founder.deploy(owner.address);
    await founder.waitForDeployment();
    await founder.openMint();

    const DAO = await ethers.getContractFactory("CryptValtDAO");
    dao = await DAO.deploy(await token.getAddress(), await founder.getAddress(), owner.address);
    await dao.waitForDeployment();

    await token.transfer(addr1.address, ethers.parseEther("100000"));
    await token.transfer(addr2.address, ethers.parseEther("100000"));
  });

  it("Should create a proposal", async function () {
    await dao.connect(addr1).propose("Test", "Desc", 1, ethers.ZeroAddress, "0x");
    const proposal = await dao.proposals(1);
    expect(proposal.proposer).to.equal(addr1.address);
  });

  it("Should allow voting", async function () {
    await dao.connect(addr1).propose("Vote", "Desc", 1, ethers.ZeroAddress, "0x");
    await dao.connect(addr2).castVote(1, 1);
    const proposal = await dao.proposals(1);
    expect(proposal.forVotes).to.be.gt(0);
  });

  it("Should allow founder veto", async function () {
    await founder.adminMint(addr2.address);
    await dao.connect(addr1).propose("Veto", "Desc", 1, ethers.ZeroAddress, "0x");
    await dao.connect(addr2).veto(1);
    const proposal = await dao.proposals(1);
    expect(proposal.vetoed).to.be.true;
  });
});