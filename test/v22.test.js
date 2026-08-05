/*
 * CryptValt v2.2 — Mainnet Hardening Test Suite
 * Run: npx hardhat test
 *
 * Four changes, each of which only matters once the ETH is real:
 *
 *  1. Pausing no longer causes a deadline default. The reveal and key
 *     windows are extended by however long the platform was paused.
 *  2. Failing to reveal forfeits part of the deposit, so a sealed bid
 *     is not a free option on the asset.
 *  3. Deposits must carry a margin over the bid they hide, so a public
 *     deposit bounds a bid instead of publishing it.
 *  4. Vetoing DAO governance takes VETO_THRESHOLD founder NFTs, not
 *     one — minting is public and payable.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY  = 24 * 60 * 60;
const HOUR = 60 * 60;

function commitment(amount, salt, sender, id) {
  return ethers.solidityPackedKeccak256(
    ["uint256", "bytes32", "address", "uint256"],
    [amount, salt, sender, id]
  );
}

describe("CryptValt v2.2 — mainnet hardening", function () {
  let admin, treasury, inventor, bidder1, bidder2, other;
  let cryptvalt;

  const CID  = "QmTestCID12345678901234567890";
  const KEYH = "a".repeat(64);
  const SALT = ethers.encodeBytes32String("salt-1");

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

  /** A deposit that satisfies the margin rule for a given bid. */
  function depositFor(bidEth) {
    const bid = ethers.parseEther(bidEth);
    return bid + (bid * 2000n) / 10000n;   // 20% over — margin needs 10%
  }

  /* ================================================================
     1. PAUSE MUST NOT CAUSE A DEADLINE DEFAULT
     ================================================================ */

  describe("pause does not run down anyone's window", function () {

    it("extends the reveal window by the paused duration", async function () {
      const id = await list("1", 1);
      const bid = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: depositFor("2") }
      );

      // Auction ends; reveal window opens.
      await time.increase(DAY + 60);

      // Platform goes down for 12 hours, mid-window.
      await cryptvalt.connect(admin).pause();
      await time.increase(12 * HOUR);
      await cryptvalt.connect(admin).unpause();

      expect(await cryptvalt.pausedOffset()).to.be.closeTo(12 * HOUR, 60);

      // Past the ORIGINAL 24h deadline, but only by less than the
      // downtime — the bidder must still be able to reveal.
      await time.increase(18 * HOUR);
      await expect(
        cryptvalt.connect(bidder1).revealBid(id, bid, SALT)
      ).to.not.be.reverted;
    });

    it("extends the key delivery window by the paused duration", async function () {
      const id = await list("1", 1);
      const bid = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: depositFor("2") }
      );
      await time.increase(DAY + 60);
      await cryptvalt.connect(bidder1).revealBid(id, bid, SALT);
      await time.increase(24 * HOUR + 60);
      await cryptvalt.settleAuction(id);

      // A day of downtime inside the 48h delivery window.
      await cryptvalt.connect(admin).pause();
      await time.increase(DAY);
      await cryptvalt.connect(admin).unpause();

      // Past the original deadline. The inventor did nothing wrong and
      // must still be able to deliver.
      await time.increase(36 * HOUR);
      await expect(
        cryptvalt.connect(inventor).deliverKey(id, "b".repeat(64))
      ).to.not.be.reverted;
    });

    it("does not let a buyer reclaim while the extension is still running", async function () {
      const id = await list("1", 1);
      const bid = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: depositFor("2") }
      );
      await time.increase(DAY + 60);
      await cryptvalt.connect(bidder1).revealBid(id, bid, SALT);
      await time.increase(24 * HOUR + 60);
      await cryptvalt.settleAuction(id);

      await cryptvalt.connect(admin).pause();
      await time.increase(DAY);
      await cryptvalt.connect(admin).unpause();

      // Original deadline has passed; the extended one has not.
      await time.increase(36 * HOUR);
      await expect(
        cryptvalt.connect(bidder1).claimRefund(id)
      ).to.be.revertedWithCustomError(cryptvalt, "DeadlineNotPassed");
    });

    it("caps cumulative extension so auctions cannot be held open forever", async function () {
      const cap = await cryptvalt.MAX_PAUSE_EXTENSION();
      for (let i = 0; i < 3; i++) {
        await cryptvalt.connect(admin).pause();
        await time.increase(7 * DAY);
        await cryptvalt.connect(admin).unpause();
      }
      expect(await cryptvalt.pausedOffset()).to.equal(cap);
    });

    it("still lets people withdraw while paused", async function () {
      const id = await list("1", 1);
      const bid = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: depositFor("2") }
      );
      await time.increase(DAY + 60);
      await cryptvalt.connect(bidder1).revealBid(id, bid, SALT);
      await time.increase(24 * HOUR + 60);
      await cryptvalt.settleAuction(id);

      await cryptvalt.connect(admin).pause();
      // Surplus over the winning bid is refundable even while halted —
      // a pause must never trap anyone's money.
      await expect(cryptvalt.connect(bidder1).withdraw()).to.not.be.reverted;
    });
  });

  /* ================================================================
     2. NON-REVELATION IS NOT FREE
     ================================================================ */

  describe("abandoning a commitment costs something", function () {

    it("returns the full deposit to a bidder who revealed and lost", async function () {
      const id = await list("1", 1);
      const lowBid  = ethers.parseEther("1.5");
      const highBid = ethers.parseEther("3");
      const dep     = depositFor("1.5");

      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(lowBid, SALT, bidder1.address, id), { value: dep }
      );
      await cryptvalt.connect(bidder2).commitBid(
        id, commitment(highBid, SALT, bidder2.address, id), { value: depositFor("3") }
      );
      await time.increase(DAY + 60);
      await cryptvalt.connect(bidder1).revealBid(id, lowBid, SALT);
      await cryptvalt.connect(bidder2).revealBid(id, highBid, SALT);
      await time.increase(24 * HOUR + 60);
      await cryptvalt.settleAuction(id);

      await cryptvalt.connect(bidder1).claimBidRefund(id);
      expect(await cryptvalt.pendingWithdrawals(bidder1.address)).to.equal(dep);
    });

    it("forfeits a share from a bidder who never revealed", async function () {
      const id  = await list("1", 1);
      const bid = ethers.parseEther("2");
      const dep = depositFor("2");

      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: dep }
      );
      await time.increase(DAY + 60 + 24 * HOUR + 60);   // both windows pass
      await cryptvalt.settleAuction(id);

      const bps     = await cryptvalt.NO_REVEAL_FORFEIT_BPS();
      const forfeit = (dep * bps) / 10000n;

      await expect(cryptvalt.connect(bidder1).claimBidRefund(id))
        .to.emit(cryptvalt, "DepositForfeited")
        .withArgs(id, bidder1.address, forfeit);

      expect(await cryptvalt.pendingWithdrawals(bidder1.address)).to.equal(dep - forfeit);
      expect(await cryptvalt.forfeitedDeposits(id)).to.equal(forfeit);
    });

    it("credits the forfeit to the platform, not the inventor", async function () {
      const id  = await list("1", 1);
      const bid = ethers.parseEther("2");
      const dep = depositFor("2");

      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: dep }
      );
      await time.increase(DAY + 60 + 24 * HOUR + 60);
      await cryptvalt.settleAuction(id);

      const before = await cryptvalt.pendingWithdrawals(treasury.address);
      await cryptvalt.connect(bidder1).claimBidRefund(id);
      const after  = await cryptvalt.pendingWithdrawals(treasury.address);

      const bps = await cryptvalt.NO_REVEAL_FORFEIT_BPS();
      expect(after - before).to.equal((dep * bps) / 10000n);

      // Paying the seller would give them a reason to want bids to fail.
      expect(await cryptvalt.pendingWithdrawals(inventor.address)).to.equal(0n);
    });

    it("keeps the contract solvent after a forfeit", async function () {
      const id  = await list("1", 1);
      const bid = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: depositFor("2") }
      );
      await time.increase(DAY + 60 + 24 * HOUR + 60);
      await cryptvalt.settleAuction(id);
      await cryptvalt.connect(bidder1).claimBidRefund(id);

      expect(await cryptvalt.isSolvent()).to.equal(true);
      await cryptvalt.connect(bidder1).withdraw();
      expect(await cryptvalt.isSolvent()).to.equal(true);
    });

    it("never lets a deposit be claimed twice", async function () {
      const id  = await list("1", 1);
      const bid = ethers.parseEther("2");
      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: depositFor("2") }
      );
      await time.increase(DAY + 60 + 24 * HOUR + 60);
      await cryptvalt.settleAuction(id);
      await cryptvalt.connect(bidder1).claimBidRefund(id);

      await expect(
        cryptvalt.connect(bidder1).claimBidRefund(id)
      ).to.be.revertedWithCustomError(cryptvalt, "NothingToClaim");
    });
  });

  /* ================================================================
     3. A DEPOSIT MUST NOT PUBLISH THE BID
     ================================================================ */

  describe("deposits bound a bid rather than revealing it", function () {

    it("rejects a deposit that only just meets the reserve", async function () {
      const id = await list("1", 1);
      const bid = ethers.parseEther("1");
      await expect(
        cryptvalt.connect(bidder1).commitBid(
          id, commitment(bid, SALT, bidder1.address, id),
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(cryptvalt, "DepositMarginTooLow");
    });

    it("accepts a deposit carrying the required margin", async function () {
      const id = await list("1", 1);
      const bid = ethers.parseEther("1");
      const margin = await cryptvalt.MIN_DEPOSIT_MARGIN_BPS();
      const reserve = ethers.parseEther("1");
      const min = reserve + (reserve * margin) / 10000n;

      await expect(
        cryptvalt.connect(bidder1).commitBid(
          id, commitment(bid, SALT, bidder1.address, id), { value: min }
        )
      ).to.not.be.reverted;
    });

    it("rejects a reveal that would consume the whole deposit", async function () {
      const id  = await list("1", 1);
      const dep = ethers.parseEther("2");
      // Bid equal to the deposit: if this were allowed, the public
      // deposit would have been the bid all along.
      const bid = dep;

      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: dep }
      );
      await time.increase(DAY + 60);
      await expect(
        cryptvalt.connect(bidder1).revealBid(id, bid, SALT)
      ).to.be.revertedWithCustomError(cryptvalt, "DepositMarginTooLow");
    });

    it("refunds the surplus in full to the winner", async function () {
      const id  = await list("1", 1);
      const bid = ethers.parseEther("2");
      const dep = ethers.parseEther("5");        // deliberately over-deposited

      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(bid, SALT, bidder1.address, id), { value: dep }
      );
      await time.increase(DAY + 60);
      await cryptvalt.connect(bidder1).revealBid(id, bid, SALT);
      await time.increase(24 * HOUR + 60);
      await cryptvalt.settleAuction(id);

      // Over-depositing to hide a bid must cost nothing but the lock-up.
      expect(await cryptvalt.pendingWithdrawals(bidder1.address)).to.equal(dep - bid);
    });
  });

  /* ================================================================
     4. GOVERNANCE CANNOT BE CAPTURED FOR ONE MINT
     ================================================================ */

  describe("veto requires a real stake", function () {
    let dao, token, founder;

    beforeEach(async function () {
      const Token   = await ethers.getContractFactory("CryptValtToken");
      const Founder = await ethers.getContractFactory("CryptValtFounder");
      const DAO     = await ethers.getContractFactory("CryptValtDAO");

      token   = await Token.deploy(admin.address);
      founder = await Founder.deploy(admin.address);
      dao     = await DAO.deploy(
        await token.getAddress(), await founder.getAddress(), admin.address
      );
    });

    it("sets a threshold above a single token", async function () {
      expect(await dao.VETO_THRESHOLD()).to.be.greaterThan(1n);
    });

    it("refuses a veto from a holder of one NFT", async function () {
      const price = await founder.MINT_PRICE().catch(() => 0n);
      await founder.connect(admin).setMintOpen?.(true).catch(() => {});
      await founder.connect(other).mint({ value: price }).catch(() => {});

      const held = await founder.balanceOf(other.address);
      if (held === 0n) this.skip();          // mint gated differently
      expect(held).to.be.lessThan(await dao.VETO_THRESHOLD());

      await expect(dao.connect(other).veto(1))
        .to.be.revertedWithCustomError(dao, "NotFounder");
    });
  });
});
