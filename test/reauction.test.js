/*
 * CryptValt v2.1 — Reauction & Archive Test Suite
 * Run: npx hardhat test
 *
 * Covers the two admin-triggered additions:
 *  - reauction(): relists a dead auction as a NEW listing that
 *    inherits the payload and preserves the old auction's records
 *  - archiveListing(): status-8 archival, blocked while funds are owed
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 24 * 60 * 60;

function commitment(amount, salt, sender, id) {
  return ethers.solidityPackedKeccak256(
    ["uint256", "bytes32", "address", "uint256"],
    [amount, salt, sender, id]
  );
}

describe("CryptValt v2.1 — reauction & archive", function () {
  let admin, treasury, inventor, bidder1, bidder2, other;
  let cryptvalt;

  const CID  = "QmTestCID12345678901234567890";
  const KEYH = "a".repeat(64);

  beforeEach(async function () {
    [admin, treasury, inventor, bidder1, bidder2, other] = await ethers.getSigners();
    const CryptValt = await ethers.getContractFactory("CryptValt");
    cryptvalt = await CryptValt.deploy(admin.address, treasury.address, 2000);
  });

  async function list(reserveEth = "1", days = 3, royalty = 500) {
    await cryptvalt.connect(inventor).listIdea(
      CID, KEYH, "tech", ethers.parseEther(reserveEth), days * DAY, royalty
    );
    return Number(await cryptvalt.listingCount());
  }

  /** Run a listing to Cancelled (6): one bidder commits, never reveals. */
  async function toCancelled() {
    const id = await list();
    const salt = ethers.encodeBytes32String("s");
    await cryptvalt.connect(bidder1).commitBid(
      id, commitment(ethers.parseEther("2"), salt, bidder1.address, BigInt(id)),
      { value: ethers.parseEther("2") }
    );
    await time.increase(4 * DAY + 2);
    await cryptvalt.settleAuction(id);
    expect((await cryptvalt.getListing(id)).status).to.equal(6);
    return id;
  }

  /** Run a listing to Complete (4) with funds released. */
  async function toComplete() {
    const id = await list();
    const salt = ethers.encodeBytes32String("w");
    const bid  = ethers.parseEther("3");
    await cryptvalt.connect(bidder2).commitBid(
      id, commitment(bid, salt, bidder2.address, BigInt(id)), { value: bid }
    );
    await time.increase(3 * DAY + 1);
    await cryptvalt.connect(bidder2).revealBid(id, bid, salt);
    await time.increase(DAY + 1);
    await cryptvalt.settleAuction(id);
    await cryptvalt.connect(inventor).deliverKey(id, "encrypted-key");
    expect((await cryptvalt.getListing(id)).status).to.equal(4);
    return id;
  }

  // ────────────────────────────────────────────────────────────────
  //  REAUCTION
  // ────────────────────────────────────────────────────────────────

  describe("reauction()", function () {
    it("relists a cancelled auction as a new listing inheriting the payload", async function () {
      const oldId = await toCancelled();

      await expect(
        cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("0.5"), 2 * DAY, 300)
      ).to.emit(cryptvalt, "Reauctioned");

      const newId = Number(await cryptvalt.listingCount());
      expect(newId).to.equal(oldId + 1);

      const n = await cryptvalt.getListing(newId);
      expect(n.inventor).to.equal(inventor.address);
      expect(n.reservePrice).to.equal(ethers.parseEther("0.5"));
      expect(n.royaltyBps).to.equal(300);
      expect(n.status).to.equal(0); // live again
      expect(n.winner).to.equal(ethers.ZeroAddress);
      expect(n.bidCount).to.equal(0);

      // payload carried across
      const [cid, keyHash, cat] = await cryptvalt.getListingStrings(newId);
      expect(cid).to.equal(CID);
      expect(keyHash).to.equal(KEYH);
      expect(cat).to.equal("tech");

      // provenance links
      expect(await cryptvalt.reauctionedFrom(newId)).to.equal(oldId);
      expect(await cryptvalt.reauctionedTo(oldId)).to.equal(newId);
      expect(await cryptvalt.reauctionCount(newId)).to.equal(1);
    });

    it("preserves the old auction's records so past bidders can still claim", async function () {
      const oldId = await toCancelled();
      await cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("1"), 2 * DAY, 0);

      // Old listing untouched, and bidder1 can still reclaim their deposit.
      expect((await cryptvalt.getListing(oldId)).status).to.equal(6);
      await cryptvalt.connect(bidder1).claimBidRefund(oldId);
      expect(await cryptvalt.pendingWithdrawals(bidder1.address))
        .to.equal(ethers.parseEther("2"));
      await cryptvalt.connect(bidder1).withdraw();
      expect(await cryptvalt.isSolvent()).to.equal(true);
    });

    it("the relisted auction runs a full normal lifecycle", async function () {
      const oldId = await toCancelled();
      await cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("1"), 2 * DAY, 0);
      const id = Number(await cryptvalt.listingCount());

      const salt = ethers.encodeBytes32String("r2");
      const bid  = ethers.parseEther("4");
      await cryptvalt.connect(bidder2).commitBid(
        id, commitment(bid, salt, bidder2.address, BigInt(id)), { value: bid }
      );
      await time.increase(2 * DAY + 1);
      await cryptvalt.connect(bidder2).revealBid(id, bid, salt);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);
      await cryptvalt.connect(inventor).deliverKey(id, "key-round-2");

      expect(await cryptvalt.pendingWithdrawals(inventor.address))
        .to.equal(ethers.parseEther("3.2")); // 80% of 4
      expect(await cryptvalt.isSolvent()).to.equal(true);
    });

    it("supports repeated reauctions and reports the full chain", async function () {
      const first = await toCancelled();
      await cryptvalt.connect(admin).reauction(first, ethers.parseEther("1"), 1 * DAY, 0);
      const second = Number(await cryptvalt.listingCount());

      // let round 2 die with no bids
      await time.increase(2 * DAY + 2);
      await cryptvalt.settleAuction(second);
      await cryptvalt.connect(admin).reauction(second, ethers.parseEther("1"), 1 * DAY, 0);
      const third = Number(await cryptvalt.listingCount());

      expect(await cryptvalt.reauctionCount(third)).to.equal(2);
      const chain = await cryptvalt.getReauctionHistory(third);
      expect(chain.map(Number)).to.deep.equal([first, second, third]);
      // same chain resolves from any member
      const chainFromFirst = await cryptvalt.getReauctionHistory(first);
      expect(chainFromFirst.map(Number)).to.deep.equal([first, second, third]);
    });

    it("refuses to relist live, awaiting-key or completed auctions", async function () {
      const live = await list();
      await expect(cryptvalt.connect(admin).reauction(live, ethers.parseEther("1"), DAY, 0))
        .to.be.revertedWithCustomError(cryptvalt, "NotReauctionable");

      const done = await toComplete();
      await expect(cryptvalt.connect(admin).reauction(done, ethers.parseEther("1"), DAY, 0))
        .to.be.revertedWithCustomError(cryptvalt, "NotReauctionable");
    });

    it("validates parameters and blocks frozen inventors and non-admins", async function () {
      const oldId = await toCancelled();

      await expect(cryptvalt.connect(other).reauction(oldId, ethers.parseEther("1"), DAY, 0))
        .to.be.reverted; // not GOVERNOR_ROLE
      await expect(cryptvalt.connect(admin).reauction(oldId, 0, DAY, 0))
        .to.be.revertedWithCustomError(cryptvalt, "NoReserve");
      await expect(cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("1"), 100, 0))
        .to.be.revertedWithCustomError(cryptvalt, "BadDuration");
      await expect(cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("1"), DAY, 5000))
        .to.be.revertedWithCustomError(cryptvalt, "HighRoyalty");

      await cryptvalt.connect(admin).freezeWallet(inventor.address, "under review");
      await expect(cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("1"), DAY, 0))
        .to.be.revertedWithCustomError(cryptvalt, "WalletIsFrozen");
    });

    it("is blocked while the platform is paused", async function () {
      const oldId = await toCancelled();
      await cryptvalt.connect(admin).pause();
      await expect(cryptvalt.connect(admin).reauction(oldId, ethers.parseEther("1"), DAY, 0))
        .to.be.reverted;
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  ARCHIVE
  // ────────────────────────────────────────────────────────────────

  describe("archiveListing()", function () {
    it("archives a completed, fully-paid listing", async function () {
      const id = await toComplete();
      await expect(cryptvalt.connect(admin).archiveListing(id))
        .to.emit(cryptvalt, "Archived").withArgs(id, admin.address);
      expect((await cryptvalt.getListing(id)).status).to.equal(8);
    });

    it("archives a cancelled listing once every deposit is claimed", async function () {
      const id = await toCancelled();
      // bidder1's deposit is still unclaimed → blocked
      await expect(cryptvalt.connect(admin).archiveListing(id))
        .to.be.revertedWithCustomError(cryptvalt, "FundsStillOwed");

      await cryptvalt.connect(bidder1).claimBidRefund(id);
      await cryptvalt.connect(admin).archiveListing(id);
      expect((await cryptvalt.getListing(id)).status).to.equal(8);
    });

    it("refuses to archive active, revealing, awaiting-key or disputed listings", async function () {
      const live = await list();
      await expect(cryptvalt.connect(admin).archiveListing(live))
        .to.be.revertedWithCustomError(cryptvalt, "CannotArchiveActive");

      // awaiting key
      const id = await list();
      const salt = ethers.encodeBytes32String("x");
      const bid  = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, salt, bidder1.address, BigInt(id)), { value: bid }
      );
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder1).revealBid(id, bid, salt);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);
      await expect(cryptvalt.connect(admin).archiveListing(id))
        .to.be.revertedWithCustomError(cryptvalt, "CannotArchiveActive");

      // disputed
      await cryptvalt.connect(bidder1).raiseDispute(id);
      await expect(cryptvalt.connect(admin).archiveListing(id))
        .to.be.revertedWithCustomError(cryptvalt, "CannotArchiveActive");
    });

    it("blocks double-archiving and non-admin callers", async function () {
      const id = await toComplete();
      await cryptvalt.connect(admin).archiveListing(id);
      await expect(cryptvalt.connect(admin).archiveListing(id))
        .to.be.revertedWithCustomError(cryptvalt, "AlreadyArchived");
      const id2 = await toComplete();
      await expect(cryptvalt.connect(other).archiveListing(id2)).to.be.reverted;
    });

    it("an archived listing can still be reauctioned", async function () {
      const id = await toCancelled();
      await cryptvalt.connect(bidder1).claimBidRefund(id);
      await cryptvalt.connect(admin).archiveListing(id);
      await cryptvalt.connect(admin).reauction(id, ethers.parseEther("1"), DAY, 0);
      const newId = Number(await cryptvalt.listingCount());
      expect(await cryptvalt.reauctionedFrom(newId)).to.equal(id);
      expect((await cryptvalt.getListing(newId)).status).to.equal(0);
    });

    it("archiving never moves funds and keeps the contract solvent", async function () {
      const id = await toComplete();
      const invBefore  = await cryptvalt.pendingWithdrawals(inventor.address);
      const platBefore = await cryptvalt.pendingWithdrawals(treasury.address);
      await cryptvalt.connect(admin).archiveListing(id);
      expect(await cryptvalt.pendingWithdrawals(inventor.address)).to.equal(invBefore);
      expect(await cryptvalt.pendingWithdrawals(treasury.address)).to.equal(platBefore);
      expect(await cryptvalt.isSolvent()).to.equal(true);
    });
  });
});
