/*
 * CryptValt v2.0 — Extended Coverage Suite
 * Run: npx hardhat coverage
 *
 * Complements cryptvalt.test.js by exercising every remaining path:
 * disputes, secondary market, freezing, pausing, admin functions,
 * vesting edges, governor heuristics, valuation math, DAO branches,
 * and error-branch assertions.
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

describe("CryptValt v2.0 — extended coverage", function () {
  let admin, treasury, inventor, bidder1, bidder2, other, scout;
  let cryptvalt, token, founder, membership, revenue, governor, valuation, dao;

  beforeEach(async function () {
    [admin, treasury, inventor, bidder1, bidder2, other, scout] =
      await ethers.getSigners();

    const CryptValt = await ethers.getContractFactory("CryptValt");
    cryptvalt = await CryptValt.deploy(admin.address, treasury.address, 2000);
    const Token = await ethers.getContractFactory("CryptValtToken");
    token = await Token.deploy(admin.address, treasury.address);
    const Founder = await ethers.getContractFactory("CryptValtFounder");
    founder = await Founder.deploy(admin.address, treasury.address);
    const Membership = await ethers.getContractFactory("CryptValtMembership");
    membership = await Membership.deploy(admin.address, treasury.address);
    const Revenue = await ethers.getContractFactory("CryptValtRevenue");
    revenue = await Revenue.deploy(admin.address, treasury.address);
    const Governor = await ethers.getContractFactory("CryptValtGovernor");
    governor = await Governor.deploy(admin.address, await cryptvalt.getAddress());
    const Valuation = await ethers.getContractFactory("CryptValtValuation");
    valuation = await Valuation.deploy(admin.address, await cryptvalt.getAddress());
    const DAO = await ethers.getContractFactory("CryptValtDAO");
    dao = await DAO.deploy(
      admin.address, await token.getAddress(),
      await founder.getAddress(), treasury.address
    );
  });

  // Helper: run an auction to AwaitingKey (status 2) with bidder2 winning 3 ETH.
  async function auctionToAwaitingKey() {
    await cryptvalt.connect(inventor).listIdea(
      "QmTestCID12345678901234567890", "a".repeat(64), "tech",
      ethers.parseEther("1"), 3 * DAY, 500
    );
    const id = 1n;
    const salt = ethers.encodeBytes32String("s2");
    const bid = ethers.parseEther("3");
    await cryptvalt.connect(bidder2).commitBid(
      id, commitment(bid, salt, bidder2.address, id), { value: bid }
    );
    await time.increase(3 * DAY + 1);
    await cryptvalt.connect(bidder2).revealBid(id, bid, salt);
    await time.increase(DAY + 1);
    await cryptvalt.settleAuction(id);
    return { id, bid };
  }

  // ────────────────────────────────────────────────────────────────
  //  CORE: LISTING VALIDATION ERRORS
  // ────────────────────────────────────────────────────────────────

  describe("Listing validation", function () {
    it("rejects bad CID, key hash, category, reserve, duration, royalty", async function () {
      const good = ["QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 500];

      await expect(cryptvalt.connect(inventor).listIdea("short", good[1], good[2], good[3], good[4], good[5]))
        .to.be.revertedWithCustomError(cryptvalt, "BadCID");
      await expect(cryptvalt.connect(inventor).listIdea(good[0], "short", good[2], good[3], good[4], good[5]))
        .to.be.revertedWithCustomError(cryptvalt, "BadKeyHash");
      await expect(cryptvalt.connect(inventor).listIdea(good[0], good[1], "", good[3], good[4], good[5]))
        .to.be.revertedWithCustomError(cryptvalt, "NoCategory");
      await expect(cryptvalt.connect(inventor).listIdea(good[0], good[1], good[2], 0, good[4], good[5]))
        .to.be.revertedWithCustomError(cryptvalt, "NoReserve");
      await expect(cryptvalt.connect(inventor).listIdea(good[0], good[1], good[2], good[3], 100, good[5]))
        .to.be.revertedWithCustomError(cryptvalt, "BadDuration");
      await expect(cryptvalt.connect(inventor).listIdea(good[0], good[1], good[2], good[3], 30 * DAY, good[5]))
        .to.be.revertedWithCustomError(cryptvalt, "BadDuration");
      await expect(cryptvalt.connect(inventor).listIdea(good[0], good[1], good[2], good[3], good[4], 5000))
        .to.be.revertedWithCustomError(cryptvalt, "HighRoyalty");
    });

    it("rejects operations on nonexistent listings", async function () {
      await expect(cryptvalt.settleAuction(99))
        .to.be.revertedWithCustomError(cryptvalt, "NotFound");
      await expect(cryptvalt.connect(bidder1).commitBid(0, ethers.ZeroHash, { value: 1 }))
        .to.be.revertedWithCustomError(cryptvalt, "NotFound");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  CORE: BIDDING ERRORS
  // ────────────────────────────────────────────────────────────────

  describe("Bidding errors", function () {
    beforeEach(async function () {
      await cryptvalt.connect(inventor).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      );
    });

    it("inventor cannot bid; deposits below reserve rejected; duplicate bids rejected", async function () {
      const c = commitment(ethers.parseEther("1"), ethers.encodeBytes32String("x"), inventor.address, 1n);
      await expect(cryptvalt.connect(inventor).commitBid(1, c, { value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(cryptvalt, "InventorCannotBid");

      const c1 = commitment(ethers.parseEther("1"), ethers.encodeBytes32String("x"), bidder1.address, 1n);
      await expect(cryptvalt.connect(bidder1).commitBid(1, c1, { value: ethers.parseEther("0.5") }))
        .to.be.revertedWithCustomError(cryptvalt, "DepositBelowReserve");

      await cryptvalt.connect(bidder1).commitBid(1, c1, { value: ethers.parseEther("1") });
      await expect(cryptvalt.connect(bidder1).commitBid(1, c1, { value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(cryptvalt, "BidExists");
    });

    it("rejects commits after end, reveals outside window, wrong salt, below-reserve reveals", async function () {
      const amt = ethers.parseEther("2");
      const salt = ethers.encodeBytes32String("s");
      const c = commitment(amt, salt, bidder1.address, 1n);
      await cryptvalt.connect(bidder1).commitBid(1, c, { value: amt });

      // Reveal too early
      await expect(cryptvalt.connect(bidder1).revealBid(1, amt, salt))
        .to.be.revertedWithCustomError(cryptvalt, "WrongWindow");

      await time.increase(3 * DAY + 1);
      // Commit after end
      const c2 = commitment(amt, salt, bidder2.address, 1n);
      await expect(cryptvalt.connect(bidder2).commitBid(1, c2, { value: amt }))
        .to.be.revertedWithCustomError(cryptvalt, "AuctionEnded");

      // Wrong salt
      await expect(cryptvalt.connect(bidder1).revealBid(1, amt, ethers.encodeBytes32String("wrong")))
        .to.be.revertedWithCustomError(cryptvalt, "BadReveal");
      // No bid
      await expect(cryptvalt.connect(other).revealBid(1, amt, salt))
        .to.be.revertedWithCustomError(cryptvalt, "InvalidBid");

      // Good reveal then double reveal
      await cryptvalt.connect(bidder1).revealBid(1, amt, salt);
      await expect(cryptvalt.connect(bidder1).revealBid(1, amt, salt))
        .to.be.revertedWithCustomError(cryptvalt, "InvalidBid");

      // Reveal after deadline
      await time.increase(2 * DAY);
      await expect(cryptvalt.connect(bidder1).revealBid(1, amt, salt))
        .to.be.revertedWithCustomError(cryptvalt, "WrongWindow");
    });

    it("settle before reveal deadline reverts; double settle reverts", async function () {
      await time.increase(3 * DAY + 1);
      await expect(cryptvalt.settleAuction(1))
        .to.be.revertedWithCustomError(cryptvalt, "RevealStillOpen");
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(1); // cancels (no reveals)
      await expect(cryptvalt.settleAuction(1))
        .to.be.revertedWithCustomError(cryptvalt, "CannotSettle");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  CORE: KEY DELIVERY ERRORS + WITHDRAW
  // ────────────────────────────────────────────────────────────────

  describe("Key delivery & withdraw errors", function () {
    it("rejects non-inventor, empty key, late delivery; withdraw with zero reverts", async function () {
      const { id } = await auctionToAwaitingKey();

      await expect(cryptvalt.connect(other).deliverKey(id, "k"))
        .to.be.revertedWithCustomError(cryptvalt, "NotInventor");
      await expect(cryptvalt.connect(inventor).deliverKey(id, ""))
        .to.be.revertedWithCustomError(cryptvalt, "EmptyKey");

      await expect(cryptvalt.connect(other).withdraw())
        .to.be.revertedWithCustomError(cryptvalt, "NothingToWithdraw");

      // Winner refund before deadline rejected
      await expect(cryptvalt.connect(bidder2).claimRefund(id))
        .to.be.revertedWithCustomError(cryptvalt, "DeadlineNotPassed");
      await expect(cryptvalt.connect(other).claimRefund(id))
        .to.be.revertedWithCustomError(cryptvalt, "NotWinner");

      await time.increase(2 * DAY + 1);
      await expect(cryptvalt.connect(inventor).deliverKey(id, "k"))
        .to.be.revertedWithCustomError(cryptvalt, "PastDeadline");
    });

    it("getWinnerKey blocked before delivery; getters return data", async function () {
      const { id } = await auctionToAwaitingKey();
      await expect(cryptvalt.connect(bidder2).getWinnerKey(id))
        .to.be.revertedWithCustomError(cryptvalt, "Denied");

      const [cid, keyHash, cat] = await cryptvalt.getListingStrings(id);
      expect(cid.length).to.be.greaterThan(0);
      expect(cat).to.equal("tech");
      expect((await cryptvalt.getBidders(id)).length).to.equal(1);
      expect((await cryptvalt.getInventorListings(inventor.address)).length).to.equal(1);
      expect((await cryptvalt.getBidderHistory(bidder2.address)).length).to.equal(1);
      const stats = await cryptvalt.getPlatformStats();
      expect(stats[0]).to.equal(1);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  CORE: DISPUTES
  // ────────────────────────────────────────────────────────────────

  describe("Disputes", function () {
    it("full dispute path resolved for inventor", async function () {
      const { id } = await auctionToAwaitingKey();
      await expect(cryptvalt.connect(other).raiseDispute(id))
        .to.be.revertedWithCustomError(cryptvalt, "NotParty");

      await cryptvalt.connect(bidder2).raiseDispute(id);
      await expect(cryptvalt.connect(bidder2).raiseDispute(id))
        .to.be.revertedWithCustomError(cryptvalt, "WrongStatus");

      await expect(cryptvalt.connect(other).resolveDispute(id, true)).to.be.reverted;

      await cryptvalt.connect(admin).resolveDispute(id, true);
      expect(await cryptvalt.pendingWithdrawals(inventor.address)).to.equal(ethers.parseEther("2.4"));
      await expect(cryptvalt.connect(admin).resolveDispute(id, true))
        .to.be.revertedWithCustomError(cryptvalt, "WrongStatus");
    });

    it("dispute resolved for winner refunds escrow", async function () {
      const { id, bid } = await auctionToAwaitingKey();
      await cryptvalt.connect(inventor).raiseDispute(id);
      await cryptvalt.connect(admin).resolveDispute(id, false);
      expect(await cryptvalt.pendingWithdrawals(bidder2.address)).to.equal(bid);
      expect((await cryptvalt.getListing(id)).status).to.equal(6);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  CORE: SECONDARY MARKET
  // ────────────────────────────────────────────────────────────────

  describe("Secondary market", function () {
    async function toComplete() {
      const { id } = await auctionToAwaitingKey();
      await cryptvalt.connect(inventor).deliverKey(id, "key");
      return id;
    }

    it("lists and sells with royalty + fee split; blocks double-buy", async function () {
      const id = await toComplete();
      await expect(cryptvalt.connect(other).listSecondary(id, ethers.parseEther("5")))
        .to.be.revertedWithCustomError(cryptvalt, "NotSettledOwner");
      await expect(cryptvalt.connect(bidder2).listSecondary(id, 0))
        .to.be.revertedWithCustomError(cryptvalt, "BadPrice");

      await cryptvalt.connect(bidder2).listSecondary(id, ethers.parseEther("10"));
      await expect(cryptvalt.connect(other).buySecondary(id, { value: ethers.parseEther("5") }))
        .to.be.revertedWithCustomError(cryptvalt, "PaymentTooLow");

      const invBefore = await cryptvalt.pendingWithdrawals(inventor.address);
      await cryptvalt.connect(other).buySecondary(id, { value: ethers.parseEther("10") });
      // royalty 5% = 0.5, fee 20% = 2, seller 7.5
      expect((await cryptvalt.pendingWithdrawals(inventor.address)) - invBefore)
        .to.equal(ethers.parseEther("0.5"));
      expect(await cryptvalt.pendingWithdrawals(bidder2.address)).to.equal(ethers.parseEther("7.5"));
      expect((await cryptvalt.getListing(id)).winner).to.equal(other.address);

      await expect(cryptvalt.connect(bidder1).buySecondary(id, { value: ethers.parseEther("10") }))
        .to.be.revertedWithCustomError(cryptvalt, "NotForSale");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  CORE: FREEZE / PAUSE / ADMIN
  // ────────────────────────────────────────────────────────────────

  describe("Freeze, pause & admin coverage", function () {
    it("frozen wallets blocked from listing; unfreeze restores", async function () {
      await cryptvalt.connect(admin).freezeWallet(bidder1.address, "abuse");
      await expect(cryptvalt.connect(bidder1).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      )).to.be.revertedWithCustomError(cryptvalt, "WalletIsFrozen");
      await cryptvalt.connect(admin).unfreezeWallet(bidder1.address);
      await cryptvalt.connect(bidder1).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      );
    });

    it("freezes/unfreezes listings; unfreeze of non-frozen reverts", async function () {
      await cryptvalt.connect(inventor).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      );
      await expect(cryptvalt.connect(admin).unfreezeListing(1))
        .to.be.revertedWithCustomError(cryptvalt, "NotFrozenListing");
      await cryptvalt.connect(admin).freezeListing(1);
      expect((await cryptvalt.getListing(1)).status).to.equal(7);
      await cryptvalt.connect(admin).unfreezeListing(1);
      expect((await cryptvalt.getListing(1)).status).to.equal(0);
    });

    it("pause blocks listing/bidding; unpause restores; emergency toggles", async function () {
      await cryptvalt.connect(admin).pause();
      await expect(cryptvalt.connect(inventor).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      )).to.be.reverted;
      await cryptvalt.connect(admin).unpause();
      await cryptvalt.connect(admin).activateEmergency();
      expect(await cryptvalt.emergencyMode()).to.equal(true);
      await cryptvalt.connect(admin).cancelEmergencyDrain();
      await cryptvalt.connect(admin).deactivateEmergency();
      expect(await cryptvalt.emergencyMode()).to.equal(false);
    });

    it("wallet change timelock; contract setters; role grant/revoke; fee bounds", async function () {
      await expect(cryptvalt.connect(admin).queueFeeChange(500))
        .to.be.revertedWithCustomError(cryptvalt, "BadFee");
      await expect(cryptvalt.connect(admin).executeFeeChange())
        .to.be.revertedWithCustomError(cryptvalt, "NotQueued");

      await cryptvalt.connect(admin).queueWalletChange(other.address);
      await expect(cryptvalt.connect(admin).executeWalletChange())
        .to.be.revertedWithCustomError(cryptvalt, "TimelockActive");
      await time.increase(DAY + 1);
      await cryptvalt.connect(admin).executeWalletChange();
      expect(await cryptvalt.platformWallet()).to.equal(other.address);

      await expect(cryptvalt.connect(admin).setGovernorContract(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "ZeroAddress");

      const GOVERNOR_ROLE = await cryptvalt.GOVERNOR_ROLE();
      await cryptvalt.connect(admin).grantRole(GOVERNOR_ROLE, other.address);
      await cryptvalt.connect(other).freezeWallet(bidder1.address, "test");
      await cryptvalt.connect(admin).revokeRole(GOVERNOR_ROLE, other.address);
      await expect(cryptvalt.connect(other).freezeWallet(bidder2.address, "test"))
        .to.be.reverted;
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  TOKEN: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Token extended", function () {
    it("unstake validation, zero-stake, depositReward auth, burn, treasury, pause", async function () {
      await expect(token.connect(bidder1).stake(0))
        .to.be.revertedWithCustomError(token, "ZeroAmount");
      await expect(token.connect(bidder1).unstake(1))
        .to.be.revertedWithCustomError(token, "InsufficientStaked");
      await expect(token.connect(bidder1).depositReward(1))
        .to.be.revertedWithCustomError(token, "NotAuthorized");
      await expect(token.connect(admin).depositReward(ethers.parseEther("1")))
        .to.be.revertedWithCustomError(token, "NoStakers");

      // stake → unstake round trip
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("100"));
      await token.connect(bidder1).stake(ethers.parseEther("100"));
      await token.connect(bidder1).unstake(ethers.parseEther("100"));
      expect(await token.balanceOf(bidder1.address)).to.equal(ethers.parseEther("100"));

      // fee-burn path
      await token.connect(admin).transfer(await token.getAddress(), ethers.parseEther("10"));
      const supplyBefore = await token.totalSupply();
      await token.connect(admin).burnFromFees(ethers.parseEther("10"));
      expect(await token.totalSupply()).to.equal(supplyBefore - ethers.parseEther("10"));

      await expect(token.connect(admin).updateTreasury(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(token, "ZeroAddress");
      await token.connect(admin).updateTreasury(other.address);
      await token.connect(admin).setCryptValt(await cryptvalt.getAddress());

      // pause blocks user transfer but allows staking escrow moves
      await token.connect(admin).transfer(bidder2.address, ethers.parseEther("10"));
      await token.connect(admin).pauseTransfers();
      await expect(token.connect(bidder2).transfer(other.address, 1)).to.be.reverted;
      await token.connect(admin).unpauseTransfers();
      await token.connect(bidder2).transfer(other.address, 1);
    });

    it("fee discount tiers and voting power", async function () {
      expect(await token.getFeeDiscount(other.address)).to.equal(0);
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("100"));
      expect(await token.getFeeDiscount(bidder1.address)).to.equal(500);
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("900"));
      expect(await token.getFeeDiscount(bidder1.address)).to.equal(1000);
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("9000"));
      expect(await token.getFeeDiscount(bidder1.address)).to.equal(2000);
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("40000"));
      expect(await token.getFeeDiscount(bidder1.address)).to.equal(3000);
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("50000"));
      expect(await token.getFeeDiscount(bidder1.address)).to.equal(5000);

      await token.connect(bidder1).stake(ethers.parseEther("50000"));
      // voting power = balance + 2× staked
      expect(await token.getVotingPower(bidder1.address)).to.equal(
        ethers.parseEther("50000") + ethers.parseEther("100000")
      );
      const stats = await token.getTokenStats();
      expect(stats[1]).to.equal(ethers.parseEther("50000"));
      const info = await token.getStakeInfo(bidder1.address);
      expect(info[0]).to.equal(ethers.parseEther("50000"));
    });

    it("vesting edge cases: duplicate, none, revoked, double-revoke", async function () {
      await expect(token.connect(bidder1).releaseVesting())
        .to.be.revertedWithCustomError(token, "NoVesting");
      await expect(token.connect(admin).revokeVesting(bidder1.address))
        .to.be.revertedWithCustomError(token, "NoVesting");

      await token.connect(admin).createVesting(
        bidder1.address, ethers.parseEther("100"), 0, 100 * DAY, 10 * DAY
      );
      await expect(token.connect(admin).createVesting(
        bidder1.address, ethers.parseEther("100"), 0, 100 * DAY, 10 * DAY
      )).to.be.revertedWithCustomError(token, "AlreadyVesting");

      await token.connect(admin).revokeVesting(bidder1.address);
      await expect(token.connect(admin).revokeVesting(bidder1.address))
        .to.be.revertedWithCustomError(token, "AlreadyRevoked");
      await expect(token.connect(bidder1).releaseVesting())
        .to.be.revertedWithCustomError(token, "VestingRevokedErr");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  FOUNDER: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Founder extended", function () {
    it("mint gating, admin mint, rarity tiers, metadata, freeze", async function () {
      await expect(founder.connect(bidder1).mint({ value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(founder, "MintClosed");
      await founder.connect(admin).setMintOpen(true);
      await expect(founder.connect(bidder1).mint({ value: ethers.parseEther("0.5") }))
        .to.be.revertedWithCustomError(founder, "LowPayment");

      await founder.connect(admin).setFrozen(true);
      await expect(founder.connect(bidder1).mint({ value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(founder, "Frozen");
      await founder.connect(admin).setFrozen(false);

      await founder.connect(admin).adminMint(bidder1.address);
      expect(await founder.balanceOf(bidder1.address)).to.equal(1);

      expect(await founder.getRarity(1)).to.equal("LEGENDARY");
      expect(await founder.getRarity(10)).to.equal("EPIC");
      expect(await founder.getRarity(30)).to.equal("RARE");
      expect(await founder.getRarity(80)).to.equal("STANDARD");

      await founder.connect(admin).setBaseURI("ipfs://newbase/");
      expect(await founder.tokenURI(1)).to.equal("ipfs://newbase/1.json");

      await expect(founder.connect(bidder1).claimRevenue())
        .to.be.revertedWithCustomError(founder, "NothingOwed");

      await founder.connect(admin).updateTreasury(other.address);
      const [recv] = await founder.royaltyInfo(1, 10000);
      expect(recv).to.equal(other.address);
    });

    it("depositRevenue with no holders routes to treasury; direct ETH works with holders", async function () {
      const tBefore = await ethers.provider.getBalance(treasury.address);
      await founder.connect(admin).depositRevenue({ value: ethers.parseEther("1") });
      expect((await ethers.provider.getBalance(treasury.address)) - tBefore)
        .to.equal(ethers.parseEther("1"));

      await founder.connect(admin).setMintOpen(true);
      await founder.connect(bidder1).mint({ value: ethers.parseEther("1") });
      // direct send hits receive()
      await admin.sendTransaction({
        to: await founder.getAddress(), value: ethers.parseEther("1"),
      });
      expect(await founder.pendingRevenue(bidder1.address)).to.equal(ethers.parseEther("1"));
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  MEMBERSHIP: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Membership extended", function () {
    it("mint gating, tier validation, tier config, admin mint, metadata", async function () {
      await expect(membership.connect(bidder1).mint(1, { value: ethers.parseEther("0.05") }))
        .to.be.revertedWithCustomError(membership, "MintClosed");
      await membership.connect(admin).setMintOpen(true);
      await expect(membership.connect(bidder1).mint(0, { value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(membership, "BadTier");
      await expect(membership.connect(bidder1).mint(4, { value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(membership, "BadTier");
      await expect(membership.connect(bidder1).mint(2, { value: ethers.parseEther("0.05") }))
        .to.be.revertedWithCustomError(membership, "LowPayment");

      await membership.connect(admin).configureTier(1, ethers.parseEther("0.01"), 1, 1500);
      await membership.connect(bidder1).mint(1, { value: ethers.parseEther("0.01") });
      await expect(membership.connect(bidder2).mint(1, { value: ethers.parseEther("0.01") }))
        .to.be.revertedWithCustomError(membership, "TierSoldOut");

      await membership.connect(admin).adminMint(bidder2.address, 3);
      expect(await membership.getHighestTier(bidder2.address)).to.equal(3);
      expect(await membership.getTierName(1)).to.equal("SILVER");
      expect(await membership.getTierName(2)).to.equal("GOLD");
      expect(await membership.getTierName(3)).to.equal("PLATINUM");
      expect(await membership.getTierName(9)).to.equal("NONE");

      await membership.connect(admin).setBaseURI("ipfs://m/");
      expect(await membership.tokenURI(1)).to.equal("ipfs://m/1.json");
      await membership.connect(admin).updateTreasury(other.address);

      await expect(membership.connect(bidder1).claimRevenue())
        .to.be.revertedWithCustomError(membership, "NothingOwed");
    });

    it("gold/silver mints don't touch platinum pool; deposit + claim works", async function () {
      await membership.connect(admin).setMintOpen(true);
      await membership.connect(bidder1).mint(3, { value: ethers.parseEther("0.5") });
      await membership.connect(bidder2).mint(2, { value: ethers.parseEther("0.15") });
      expect(await membership.pendingRevenue(bidder1.address)).to.equal(0);

      await membership.connect(admin).depositRevenue({ value: ethers.parseEther("3") });
      expect(await membership.pendingRevenue(bidder1.address)).to.equal(ethers.parseEther("3"));
      expect(await membership.pendingRevenue(bidder2.address)).to.equal(0);
      await membership.connect(bidder1).claimRevenue();

      // no-platinum deposit routes to treasury handled in constructor state:
      const Membership2 = await ethers.getContractFactory("CryptValtMembership");
      const m2 = await Membership2.deploy(admin.address, treasury.address);
      const tBefore = await ethers.provider.getBalance(treasury.address);
      await m2.connect(admin).depositRevenue({ value: ethers.parseEther("1") });
      expect((await ethers.provider.getBalance(treasury.address)) - tBefore)
        .to.equal(ethers.parseEther("1"));
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  REVENUE: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Revenue extended", function () {
    it("founder pool flow, claimAll, empty-pool fallthrough, receive()", async function () {
      // Empty pools: everything to treasury
      const tBefore = await ethers.provider.getBalance(treasury.address);
      await revenue.connect(admin).deposit({ value: ethers.parseEther("10") });
      expect((await ethers.provider.getBalance(treasury.address)) - tBefore)
        .to.equal(ethers.parseEther("10"));

      await revenue.connect(admin).registerFounderHolder(bidder1.address, 2);
      await revenue.connect(admin).registerPlatinumHolder(bidder1.address, 1);
      await revenue.connect(admin).registerScout(1, bidder1.address);
      await revenue.connect(admin).payScout(1, { value: ethers.parseEther("1") });

      // receive() distributes too
      await admin.sendTransaction({
        to: await revenue.getAddress(), value: ethers.parseEther("100"),
      });
      // founder 15% = 15 over 2 tokens all bidder1; platinum 10% = 10
      expect(await revenue.pendingFounder(bidder1.address)).to.equal(ethers.parseEther("15"));
      expect(await revenue.pendingPlatinum(bidder1.address)).to.equal(ethers.parseEther("10"));
      const all = await revenue.pendingAll(bidder1.address);
      expect(all[3]).to.equal(ethers.parseEther("26"));

      await revenue.connect(bidder1).claimAll();
      await expect(revenue.connect(bidder1).claimAll())
        .to.be.revertedWithCustomError(revenue, "NothingToClaim");
      await expect(revenue.connect(bidder1).claimFounder())
        .to.be.revertedWithCustomError(revenue, "NothingToClaim");

      await revenue.connect(admin).removeFounderHolder(bidder1.address);
      await expect(revenue.connect(admin).removeFounderHolder(bidder1.address))
        .to.be.revertedWithCustomError(revenue, "NotHolder");

      const stats = await revenue.getStats();
      expect(stats[0]).to.equal(ethers.parseEther("110"));
      const sstats = await revenue.getScoutStats(bidder1.address);
      expect(sstats[1]).to.equal(1);
    });

    it("scout registration rules, multipliers, unattached payScout, emergency withdraw", async function () {
      await revenue.connect(admin).registerScout(1, scout.address);
      await expect(revenue.connect(admin).registerScout(1, other.address))
        .to.be.revertedWithCustomError(revenue, "ScoutAlreadySet");
      await expect(revenue.connect(other).registerScout(2, scout.address))
        .to.be.revertedWithCustomError(revenue, "NotAuthorized");

      await expect(revenue.connect(admin).setScoutMultiplier(scout.address, 100))
        .to.be.revertedWithCustomError(revenue, "BadMultiplier");
      await revenue.connect(admin).setScoutMultiplier(scout.address, 20000);

      // payScout with no scout on listing → treasury
      const tBefore = await ethers.provider.getBalance(treasury.address);
      await revenue.connect(admin).payScout(99, { value: ethers.parseEther("1") });
      expect((await ethers.provider.getBalance(treasury.address)) - tBefore)
        .to.equal(ethers.parseEther("1"));

      // wiring setters
      await revenue.connect(admin).setCryptValt(await cryptvalt.getAddress());
      await revenue.connect(admin).setMembership(await membership.getAddress());
      await revenue.connect(admin).setFounder(await founder.getAddress());
      await revenue.connect(admin).updateTreasury(other.address);

      // emergency withdraw with timelock
      await revenue.connect(admin).registerPlatinumHolder(bidder1.address, 1);
      await revenue.connect(admin).deposit({ value: ethers.parseEther("10") });
      await expect(revenue.connect(admin).emergencyWithdraw())
        .to.be.revertedWithCustomError(revenue, "NotQueued");
      await revenue.connect(admin).queueEmergencyWithdraw();
      await expect(revenue.connect(admin).emergencyWithdraw())
        .to.be.revertedWithCustomError(revenue, "TimelockActive");
      await revenue.connect(admin).cancelEmergencyWithdraw();
      await revenue.connect(admin).queueEmergencyWithdraw();
      await time.increase(2 * DAY + 1);
      await revenue.connect(admin).emergencyWithdraw();
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  GOVERNOR: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Governor extended", function () {
    beforeEach(async function () {
      await governor.connect(admin).updatePlatform(admin.address); // admin acts as platform
    });

    it("velocity flagging, rep floors/ceilings, tiers, verify, freeze/unfreeze", async function () {
      await governor.connect(admin).setMaxBidsPerHr(2);
      await governor.connect(admin).onBidCommitted(1, bidder1.address);
      await governor.connect(admin).onBidCommitted(1, bidder1.address);
      await governor.connect(admin).onBidCommitted(1, bidder1.address); // 3rd → flag
      expect(await governor.getReputation(bidder1.address)).to.equal(450);
      expect(await governor.flagCount(bidder1.address)).to.equal(1);

      // Dispute losses push rep down to freeze threshold
      await governor.connect(admin).onDisputeResolved(bidder1.address, false); // -150 → 300
      await governor.connect(admin).onDisputeResolved(bidder1.address, false); // → 150
      await governor.connect(admin).onDisputeResolved(bidder1.address, false); // → 0 + freeze
      expect(await governor.frozen(bidder1.address)).to.equal(true);
      expect(await governor.getTier(bidder1.address)).to.equal("SUSPENDED");
      const [canB, reasonB] = await governor.canBid(bidder1.address);
      expect(canB).to.equal(false);
      expect(reasonB).to.equal("Wallet frozen");

      await governor.connect(admin).manualUnfreeze(bidder1.address);
      // rep 0 < minRepToBid → still blocked, different reason
      const [canB2, reasonB2] = await governor.canBid(bidder1.address);
      expect(canB2).to.equal(false);
      expect(reasonB2).to.equal("Reputation too low");
      const [canL] = await governor.canList(bidder1.address);
      expect(canL).to.equal(false);

      // Verify boosts rep; wins add rep, cap at 1000
      await governor.connect(admin).verifyWallet(bidder2.address); // 500+150=650
      expect(await governor.getTier(bidder2.address)).to.equal("SILVER");
      for (let i = 0; i < 16; i++) {
        await governor.connect(admin).onDisputeResolved(bidder2.address, true);
      }
      expect(await governor.getReputation(bidder2.address)).to.equal(1000);
      expect(await governor.getTier(bidder2.address)).to.equal("PLATINUM");

      // Listing spam heuristic
      await governor.connect(admin).onDisputeRaised(other.address); // init + -30
      for (let i = 0; i < 26; i++) {
        await governor.connect(admin).onListingCreated(i, other.address);
      }
      // unknown wallets always eligible
      const [canFresh] = await governor.canBid(scout.address);
      expect(canFresh).to.equal(true);

      // deactivation bypasses checks
      await governor.connect(admin).setActive(false);
      const [canNow] = await governor.canBid(bidder1.address);
      expect(canNow).to.equal(true);
      await governor.connect(admin).setActive(true);

      // param setters
      await governor.connect(admin).setMinRepToBid(50);
      await governor.connect(admin).setMinRepToList(75);
      const stats = await governor.getStats();
      expect(stats[2]).to.equal(true);

      // manual freeze on unseen wallet initializes then freezes
      await governor.connect(admin).manualFreeze(scout.address);
      expect(await governor.frozen(scout.address)).to.equal(true);

      // settlement rep bonus
      await governor.connect(admin).onAuctionSettled(1, bidder2.address, 100);
      expect(await governor.getReputation(bidder2.address)).to.equal(1000); // capped
    });

    it("non-platform callers rejected", async function () {
      await expect(governor.connect(other).onBidCommitted(1, bidder1.address))
        .to.be.revertedWithCustomError(governor, "NotPlatform");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  VALUATION: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Valuation extended", function () {
    it("recordSale EMA, storeVal, estimate validation, all setters + bounds", async function () {
      await expect(valuation.connect(admin).recordSale("", 1))
        .to.be.revertedWithCustomError(valuation, "EmptyCategory");
      await expect(valuation.connect(admin).recordSale("tech", 0))
        .to.be.revertedWithCustomError(valuation, "ZeroPrice");
      await expect(valuation.connect(other).recordSale("tech", 1))
        .to.be.revertedWithCustomError(valuation, "NotAuthorized");

      await valuation.connect(admin).recordSale("tech", ethers.parseEther("10"));
      await valuation.connect(admin).recordSale("tech", ethers.parseEther("20"));
      expect(await valuation.catAvg("tech")).to.equal(ethers.parseEther("12")); // 10*0.8+20*0.2

      // EMA blending kicks in at 5+ sales
      for (let i = 0; i < 4; i++) {
        await valuation.connect(admin).recordSale("tech", ethers.parseEther("10"));
      }
      const blended = await valuation.estimate(80, "tech", ethers.parseEther("1000"));
      expect(blended[1]).to.be.greaterThan(0);

      await expect(valuation.connect(admin).storeVal(1, 10, 5, 20))
        .to.be.revertedWithCustomError(valuation, "InvalidRange");
      await valuation.connect(admin).storeVal(1, 5, 10, 20);
      const v = await valuation.getVal(1);
      expect(v[1]).to.equal(10);

      await expect(valuation.estimate(101, "tech", 1))
        .to.be.revertedWithCustomError(valuation, "ScoreTooHigh");
      await expect(valuation.estimate(50, "", 1))
        .to.be.revertedWithCustomError(valuation, "EmptyCategory");

      // score curve branches
      for (const s of [5, 15, 25, 35, 45, 55, 65, 75, 85, 95]) {
        await valuation.estimate(s, "other", ethers.parseEther("100"));
      }
      // floor branch
      const tiny = await valuation.estimate(1, "other", 1);
      expect(tiny[1]).to.be.greaterThanOrEqual(5000);

      await expect(valuation.connect(admin).setCatMult("tech", 100))
        .to.be.revertedWithCustomError(valuation, "InvalidMultiplier");
      await valuation.connect(admin).setCatMult("tech", 20000);
      await expect(valuation.connect(admin).setSentiment(100))
        .to.be.revertedWithCustomError(valuation, "InvalidSentiment");
      await valuation.connect(admin).setSentiment(12000);
      await expect(valuation.connect(admin).setDemand(100))
        .to.be.revertedWithCustomError(valuation, "InvalidDemand");
      await valuation.connect(admin).setDemand(11000);
      await valuation.connect(admin).updatePlatform(other.address);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  DAO: REMAINING PATHS
  // ────────────────────────────────────────────────────────────────

  describe("DAO extended", function () {
    it("proposal threshold, defeat by quorum, defeat by vote, cancel, delegation", async function () {
      await expect(dao.connect(other).propose("T", "D", 0, ethers.ZeroAddress, "0x"))
        .to.be.revertedWithCustomError(dao, "InsufficientPower");

      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("20000"));
      await expect(dao.connect(bidder1).propose("", "D", 0, ethers.ZeroAddress, "0x"))
        .to.be.revertedWithCustomError(dao, "FieldsRequired");

      // Defeat by quorum: only 20k votes vs 5% of 100M supply
      await dao.connect(bidder1).propose("T", "D", 0, ethers.ZeroAddress, "0x");
      await dao.connect(bidder1).castVote(1, 1);
      await expect(dao.connect(bidder1).castVote(1, 5))
        .to.be.revertedWithCustomError(dao, "InvalidSupport");
      await expect(dao.connect(other).castVote(1, 1))
        .to.be.revertedWithCustomError(dao, "NoVotingPower");
      await time.increase(7 * DAY + 1);
      expect(await dao.getState(1)).to.equal(3); // Defeated (quorum)
      await expect(dao.queue(1)).to.be.revertedWithCustomError(dao, "NotSucceeded");

      // Defeat by vote: big against
      await token.connect(admin).transfer(bidder2.address, ethers.parseEther("8000000"));
      await dao.connect(bidder1).propose("T2", "D2", 0, ethers.ZeroAddress, "0x");
      await dao.connect(bidder2).castVote(2, 0); // against, huge
      await dao.connect(bidder1).castVote(2, 2); // abstain path
      await time.increase(7 * DAY + 1);
      expect(await dao.getState(2)).to.equal(3);

      // Cancel path
      await dao.connect(bidder1).propose("T3", "D3", 0, ethers.ZeroAddress, "0x");
      await expect(dao.connect(other).cancel(3))
        .to.be.revertedWithCustomError(dao, "NotProposerOrOwner");
      await dao.connect(bidder1).cancel(3);
      expect(await dao.getState(3)).to.equal(7);

      // Delegation
      await expect(dao.connect(bidder1).delegate(bidder1.address))
        .to.be.revertedWithCustomError(dao, "InvalidDelegate");
      await dao.connect(bidder1).delegate(other.address);
      expect(await dao.getVotingPower(bidder1.address)).to.equal(0);
      expect(await dao.getVotingPower(other.address)).to.equal(ethers.parseEther("20000"));
      await dao.connect(bidder1).delegate(scout.address); // re-delegate
      expect(await dao.getVotingPower(other.address)).to.equal(0);

      // veto rejections
      await expect(dao.connect(other).veto(2)).to.be.revertedWithCustomError(dao, "NotFounder");
      // v2.2: one NFT is no longer enough to veto.
      for (let i = 0; i < 3; i++) await founder.connect(admin).adminMint(bidder2.address);
      await expect(dao.connect(bidder2).veto(3)).to.be.revertedWithCustomError(dao, "Finalized");

      // executor whitelist + setters + pause
      await dao.connect(admin).addAllowedExecutor(other.address);
      expect(await dao.allowedExecutors(other.address)).to.equal(true);
      await dao.connect(admin).removeAllowedExecutor(other.address);
      await dao.connect(admin).setCVT(await token.getAddress());
      await dao.connect(admin).setFounder(await founder.getAddress());
      await dao.connect(admin).setPaused(true);
      await expect(dao.connect(bidder1).propose("T4", "D4", 0, ethers.ZeroAddress, "0x"))
        .to.be.reverted;
      await dao.connect(admin).setPaused(false);

      // view getters
      expect((await dao.getTitle(2))).to.equal("T2");
      expect((await dao.getDescription(2))).to.equal("D2");
      const receipt = await dao.getReceipt(2, bidder2.address);
      expect(receipt.hasVoted).to.equal(true);
      expect((await dao.getProposerHistory(bidder1.address)).length).to.equal(3);
    });

    it("executes a whitelisted proposal call for real", async function () {
      // DAO will call governor.setMinRepToBid(42); make DAO the governor owner.
      await governor.connect(admin).transferOwnership(await dao.getAddress());
      // Ownable2Step: DAO must accept — do it via an executed proposal? Simpler:
      // whitelist governor and have the DAO execute acceptOwnership first.
      await dao.connect(admin).addAllowedExecutor(await governor.getAddress());
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("8000000"));

      const acceptData = governor.interface.encodeFunctionData("acceptOwnership");
      await dao.connect(bidder1).propose("Accept", "own", 0, await governor.getAddress(), acceptData);
      await dao.connect(bidder1).castVote(1, 1);
      await time.increase(7 * DAY + 1);
      await dao.queue(1);
      await time.increase(2 * DAY + 1);
      await dao.execute(1);
      expect(await governor.owner()).to.equal(await dao.getAddress());

      const callData = governor.interface.encodeFunctionData("setMinRepToBid", [42]);
      await dao.connect(bidder1).propose("SetRep", "d", 0, await governor.getAddress(), callData);
      await dao.connect(bidder1).castVote(2, 1);
      await time.increase(7 * DAY + 1);
      await dao.queue(2);
      await time.increase(2 * DAY + 1);
      await dao.execute(2);
      expect(await governor.minRepToBid()).to.equal(42);
      expect(await dao.getState(2)).to.equal(5);
    });
  });
});
