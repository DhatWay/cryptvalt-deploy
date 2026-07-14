const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptValt Core", function () {
  let cryptvalt, owner, platform, addr1, addr2;

  beforeEach(async function () {
    [owner, platform, addr1, addr2] = await ethers.getSigners();
    const CryptValt = await ethers.getContractFactory("CryptValt");
    cryptvalt = await CryptValt.deploy(platform.address, 2000);
    await cryptvalt.waitForDeployment();
  });

  it("Should create a listing", async function () {
    const cid = "QmTest123456789";
    const keyHash = ethers.keccak256(ethers.toUtf8Bytes("secret1234567890"));
    const category = "tech";
    const reserve = ethers.parseEther("1");
    const duration = 86400;
    const royalty = 500;

    await cryptvalt.connect(addr1).listIdea(cid, keyHash, category, reserve, duration, royalty);
    const listing = await cryptvalt.listings(1);
    expect(listing.inventor).to.equal(addr1.address);
    expect(listing.reservePrice).to.equal(reserve);
  });

  it("Should commit and reveal a bid", async function () {
    const cid = "QmTest123456789";
    const keyHash = ethers.keccak256(ethers.toUtf8Bytes("secret1234567890"));
    const category = "health";
    const reserve = ethers.parseEther("1");
    const duration = 86400;

    await cryptvalt.connect(addr1).listIdea(cid, keyHash, category, reserve, duration, 500);

    const bidAmount = ethers.parseEther("1.5");
    const salt = ethers.randomBytes(32);
    const commitment = ethers.keccak256(
      ethers.solidityPacked(["uint256", "bytes32", "address", "uint256"], [bidAmount, salt, addr2.address, 1])
    );
    await cryptvalt.connect(addr2).commitBid(1, commitment, { value: bidAmount });

    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");

    await cryptvalt.connect(addr2).revealBid(1, bidAmount, salt);
    const bid = await cryptvalt.bids(1, addr2.address);
    expect(bid.revealed).to.be.true;
    expect(bid.revealedAmount).to.equal(bidAmount);
  });

  it("Should settle auction, deliver key, and release funds", async function () {
    const cid = "QmTest123456789";
    const keyHash = ethers.keccak256(ethers.toUtf8Bytes("secret1234567890"));
    const category = "finance";
    const reserve = ethers.parseEther("1");
    const duration = 86400;

    await cryptvalt.connect(addr1).listIdea(cid, keyHash, category, reserve, duration, 500);

    const bidAmount = ethers.parseEther("1.5");
    const salt = ethers.randomBytes(32);
    const commitment = ethers.keccak256(
      ethers.solidityPacked(["uint256", "bytes32", "address", "uint256"], [bidAmount, salt, addr2.address, 1])
    );
    await cryptvalt.connect(addr2).commitBid(1, commitment, { value: bidAmount });

    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");

    await cryptvalt.connect(addr2).revealBid(1, bidAmount, salt);

    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");

    const settleTx = await cryptvalt.settleAuction(1);
    await expect(settleTx).to.emit(cryptvalt, "Settled").withArgs(1, addr2.address, bidAmount);
    const listing = await cryptvalt.listings(1);
    expect(listing.winner).to.equal(addr2.address);
    expect(listing.winningBid).to.equal(bidAmount);

    const encKey = "encryptedKey1234567890";
    const deliverTx = await cryptvalt.connect(addr1).deliverKey(1, encKey);
    await expect(deliverTx).to.emit(cryptvalt, "FundsReleased");

    const bal = await ethers.provider.getBalance(addr1.address);
    expect(bal).to.be.gt(ethers.parseEther("0.01"));
  });
});