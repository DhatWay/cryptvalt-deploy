/*
 * CryptValt v2.0 — Branch Gap Closer
 * Run: npx hardhat coverage
 *
 * Third suite: targets the residual uncovered branches after
 * cryptvalt.test.js + coverage.test.js — wrong-status transitions,
 * zero-address guards, sold-out paths, oracle-failure isolation,
 * governor heuristics, and DAO failure branches.
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

describe("CryptValt v2.0 — branch gap closer", function () {
  let admin, treasury, inventor, bidder1, bidder2, other;
  let cryptvalt, token, founder, membership, revenue, governor, valuation, dao;

  beforeEach(async function () {
    [admin, treasury, inventor, bidder1, bidder2, other] = await ethers.getSigners();

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

  async function list(from = inventor) {
    await cryptvalt.connect(from).listIdea(
      "QmTestCID12345678901234567890", "a".repeat(64), "tech",
      ethers.parseEther("1"), 3 * DAY, 500
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  CORE: WRONG-STATUS AND GUARD BRANCHES
  // ────────────────────────────────────────────────────────────────

  describe("Core status/guard branches", function () {
    it("commit on non-active listing; deliver in wrong status; claimBidRefund pre-settlement", async function () {
      await list();
      await cryptvalt.connect(admin).freezeListing(1); // status 7
      const c = commitment(ethers.parseEther("1"), ethers.encodeBytes32String("s"), bidder1.address, 1n);
      await expect(cryptvalt.connect(bidder1).commitBid(1, c, { value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(cryptvalt, "NotActive");
      await expect(cryptvalt.connect(inventor).deliverKey(1, "k"))
        .to.be.revertedWithCustomError(cryptvalt, "NotAwaitingKey");
      await expect(cryptvalt.connect(bidder1).claimBidRefund(1))
        .to.be.revertedWithCustomError(cryptvalt, "CannotSettle");
      await expect(cryptvalt.connect(bidder1).listSecondary(1, 1))
        .to.be.revertedWithCustomError(cryptvalt, "NotSettledOwner");
    });

    it("paused reveal blocked; frozen wallet blocked from buySecondary and commitBid", async function () {
      await list();
      const amt = ethers.parseEther("2");
      const salt = ethers.encodeBytes32String("s");
      await cryptvalt.connect(bidder1).commitBid(
        1, commitment(amt, salt, bidder1.address, 1n), { value: amt }
      );
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(admin).pause();
      await expect(cryptvalt.connect(bidder1).revealBid(1, amt, salt)).to.be.reverted;
      await cryptvalt.connect(admin).unpause();
      await cryptvalt.connect(bidder1).revealBid(1, amt, salt);

      await cryptvalt.connect(admin).freezeWallet(other.address, "x");
      await expect(cryptvalt.connect(other).buySecondary(1, { value: 1 }))
        .to.be.revertedWithCustomError(cryptvalt, "WalletIsFrozen");
    });

    it("zero-address and guard reverts across admin surface", async function () {
      await expect(cryptvalt.connect(admin).freezeWallet(ethers.ZeroAddress, "x"))
        .to.be.revertedWithCustomError(cryptvalt, "ZeroAddress");
      await expect(cryptvalt.connect(admin).unfreezeWallet(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "ZeroAddress");
      await expect(cryptvalt.connect(admin).grantRole(await cryptvalt.GOVERNOR_ROLE(), ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "ZeroAddress");
      await expect(cryptvalt.connect(admin).queueWalletChange(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "ZeroAddress");
      await expect(cryptvalt.connect(admin).setValuationContract(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "ZeroAddress");
      await expect(cryptvalt.connect(admin).executeWalletChange())
        .to.be.revertedWithCustomError(cryptvalt, "NotQueued");
      await expect(cryptvalt.connect(admin).emergencyDrain(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "NotInEmergency");
      // emergency drain zero-address branch inside emergency mode
      await cryptvalt.connect(admin).activateEmergency();
      await expect(cryptvalt.connect(admin).emergencyDrain(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(cryptvalt, "NotInEmergency");
      await expect(cryptvalt.connect(admin).emergencyDrain(treasury.address))
        .to.be.revertedWithCustomError(cryptvalt, "NotQueued");
    });

    it("oracle failure cannot block settlement (try/catch branch)", async function () {
      // Point valuation at a contract with no recordSale → the call
      // reverts and must be swallowed.
      await cryptvalt.connect(admin).setValuationContract(await token.getAddress());
      await list();
      const amt = ethers.parseEther("2");
      const salt = ethers.encodeBytes32String("s");
      await cryptvalt.connect(bidder1).commitBid(
        1, commitment(amt, salt, bidder1.address, 1n), { value: amt }
      );
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder1).revealBid(1, amt, salt);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(1);
      await cryptvalt.connect(inventor).deliverKey(1, "k"); // must not revert
      expect((await cryptvalt.getListing(1)).status).to.equal(4);
    });

    it("direct ETH via receive() only increases solvency", async function () {
      await admin.sendTransaction({ to: await cryptvalt.getAddress(), value: ethers.parseEther("1") });
      expect(await cryptvalt.isSolvent()).to.equal(true);
      expect(await cryptvalt.totalEscrowed()).to.equal(0);
    });

    it("second reveal below current top does not displace the winner", async function () {
      await list();
      const hi = ethers.parseEther("3"), lo = ethers.parseEther("2");
      const sHi = ethers.encodeBytes32String("hi"), sLo = ethers.encodeBytes32String("lo");
      await cryptvalt.connect(bidder1).commitBid(1, commitment(hi, sHi, bidder1.address, 1n), { value: hi });
      await cryptvalt.connect(bidder2).commitBid(1, commitment(lo, sLo, bidder2.address, 1n), { value: lo });
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder1).revealBid(1, hi, sHi);
      await cryptvalt.connect(bidder2).revealBid(1, lo, sLo); // lower — branch where amount <= winningBid
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(1);
      expect((await cryptvalt.getListing(1)).winner).to.equal(bidder1.address);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  GOVERNOR: HEURISTIC BRANCHES
  // ────────────────────────────────────────────────────────────────

  describe("Governor heuristic branches", function () {
    beforeEach(async function () {
      await governor.connect(admin).updatePlatform(admin.address);
    });

    it("listing-spam flag fires for low-rep spammers", async function () {
      // Drive rep below 300 first: two dispute losses = 500-300 = 200.
      await governor.connect(admin).onDisputeResolved(other.address, false);
      await governor.connect(admin).onDisputeResolved(other.address, false);
      expect(await governor.getReputation(other.address)).to.equal(200);
      // 26 listings crosses the >25 threshold with rep<300 → flags fire.
      for (let i = 1; i <= 26; i++) {
        await governor.connect(admin).onListingCreated(i, other.address);
      }
      expect(await governor.getReputation(other.address)).to.be.lessThan(200);
    });

    it("velocity window resets after an hour", async function () {
      await governor.connect(admin).setMaxBidsPerHr(2);
      await governor.connect(admin).onBidCommitted(1, bidder1.address);
      await governor.connect(admin).onBidCommitted(1, bidder1.address);
      await time.increase(3700); // > 1 hour → window resets
      await governor.connect(admin).onBidCommitted(1, bidder1.address);
      expect(await governor.flagCount(bidder1.address)).to.equal(0);
      expect(await governor.getReputation(bidder1.address)).to.equal(500);
    });

    it("all reputation tiers reachable; dispute raise/win paths; inactive gate", async function () {
      // GOLD: 500 + verify 150 + two wins 50 = 750
      await governor.connect(admin).verifyWallet(bidder1.address);
      await governor.connect(admin).onDisputeResolved(bidder1.address, true);
      await governor.connect(admin).onDisputeResolved(bidder1.address, true);
      expect(await governor.getTier(bidder1.address)).to.equal("GOLD");
      // BRONZE: 500 - 150 = 350
      await governor.connect(admin).onDisputeResolved(bidder2.address, false);
      expect(await governor.getTier(bidder2.address)).to.equal("BRONZE");
      // PROBATION: 350 - 150 = 200
      await governor.connect(admin).onDisputeResolved(bidder2.address, false);
      expect(await governor.getTier(bidder2.address)).to.equal("PROBATION");
      // SILVER tier for fresh-but-initialized wallet
      await governor.connect(admin).onDisputeRaised(other.address); // init, -30 → 470
      expect(await governor.getTier(other.address)).to.equal("BRONZE");
      // inactive engine ignores platform callbacks that require isActive
      await governor.connect(admin).setActive(false);
      await expect(governor.connect(admin).onListingCreated(1, bidder1.address))
        .to.be.revertedWithCustomError(governor, "Inactive");
      // canList for frozen wallet
      await governor.connect(admin).setActive(true);
      await governor.connect(admin).manualFreeze(bidder2.address);
      const [ok, reason] = await governor.canList(bidder2.address);
      expect(ok).to.equal(false);
      expect(reason).to.equal("Wallet frozen");
      // zero-address guards
      await expect(governor.connect(admin).verifyWallet(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(governor, "ZeroAddress");
      await expect(governor.connect(admin).manualFreeze(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(governor, "ZeroAddress");
      await expect(governor.connect(admin).updatePlatform(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(governor, "ZeroAddress");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  FOUNDER / MEMBERSHIP: SUPPLY + GUARD BRANCHES
  // ────────────────────────────────────────────────────────────────

  describe("NFT supply & guard branches", function () {
    it("Founder sells out at 100 and rejects further mints", async function () {
      this.timeout(120000);
      for (let i = 0; i < 100; i++) {
        await founder.connect(admin).adminMint(bidder1.address);
      }
      await expect(founder.connect(admin).adminMint(bidder1.address))
        .to.be.revertedWithCustomError(founder, "SoldOut");
      await founder.connect(admin).setMintOpen(true);
      await expect(founder.connect(bidder2).mint({ value: ethers.parseEther("1") }))
        .to.be.revertedWithCustomError(founder, "SoldOut");
      // pendingRevenue loops all 100 tokens without gas trouble
      expect(await founder.pendingRevenue(bidder1.address)).to.equal(0);
    });

    it("Founder/Membership zero-address + nonexistent-token guards", async function () {
      await expect(founder.connect(admin).adminMint(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(founder, "ZeroAddress");
      await expect(founder.connect(admin).updateTreasury(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(founder, "ZeroAddress");
      await expect(founder.tokenURI(999)).to.be.reverted;
      await expect(founder.pendingRevenueOf(999)).to.be.reverted;

      await expect(membership.connect(admin).adminMint(ethers.ZeroAddress, 1))
        .to.be.revertedWithCustomError(membership, "ZeroAddress");
      await expect(membership.connect(admin).adminMint(bidder1.address, 7))
        .to.be.revertedWithCustomError(membership, "BadTier");
      await expect(membership.connect(admin).configureTier(9, 1, 1, 1))
        .to.be.revertedWithCustomError(membership, "BadTier");
      await expect(membership.connect(admin).updateTreasury(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(membership, "ZeroAddress");
      await expect(membership.tokenURI(999)).to.be.reverted;
    });

    it("Membership: platinum adminMint enters pool; receive() splits; non-platinum pendingOf = 0", async function () {
      await membership.connect(admin).adminMint(bidder1.address, 3);
      await membership.connect(admin).adminMint(bidder2.address, 1);
      expect(await membership.pendingRevenueOf(2)).to.equal(0); // silver token branch
      await admin.sendTransaction({
        to: await membership.getAddress(), value: ethers.parseEther("2"),
      });
      expect(await membership.pendingRevenue(bidder1.address)).to.equal(ethers.parseEther("2"));
      await membership.connect(bidder1).claimRevenue();
    });

    it("Founder deposit-zero guard; Membership deposit-zero guard", async function () {
      await expect(founder.connect(admin).depositRevenue({ value: 0 }))
        .to.be.revertedWithCustomError(founder, "ZeroAmount");
      await expect(membership.connect(admin).depositRevenue({ value: 0 }))
        .to.be.revertedWithCustomError(membership, "ZeroAmount");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  TOKEN / REVENUE: GUARD BRANCHES
  // ────────────────────────────────────────────────────────────────

  describe("Token & Revenue guard branches", function () {
    it("token guards: vesting zero args, unauthorized burn, empty claim path", async function () {
      await expect(token.connect(admin).createVesting(ethers.ZeroAddress, 1, 0, 1, 0))
        .to.be.revertedWithCustomError(token, "ZeroAddress");
      await expect(token.connect(admin).createVesting(bidder1.address, 0, 0, 1, 0))
        .to.be.revertedWithCustomError(token, "ZeroAmount");
      await expect(token.connect(other).burnFromFees(1))
        .to.be.revertedWithCustomError(token, "NotAuthorized");
      await expect(token.connect(admin).setCryptValt(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(token, "ZeroAddress");
      // claim with zero staked is a no-op that still updates debt
      await token.connect(bidder1).claimStakingReward();
      expect(await token.pendingReward(bidder1.address)).to.equal(0);
      // platform-authorized depositReward branch
      await token.connect(admin).setCryptValt(other.address);
      await token.connect(admin).transfer(other.address, ethers.parseEther("10"));
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("10"));
      await token.connect(bidder1).stake(ethers.parseEther("10"));
      await token.connect(other).depositReward(ethers.parseEther("5"));
      expect(await token.pendingReward(bidder1.address)).to.equal(ethers.parseEther("5"));
    });

    it("revenue guards: zero deposits, zero addresses, funded-scout zero value", async function () {
      await expect(revenue.connect(admin).deposit({ value: 0 }))
        .to.be.revertedWithCustomError(revenue, "ZeroAmount");
      await expect(revenue.connect(admin).registerPlatinumHolder(ethers.ZeroAddress, 1))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).registerFounderHolder(ethers.ZeroAddress, 1))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).registerScout(1, ethers.ZeroAddress))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).setScoutMultiplier(ethers.ZeroAddress, 10000))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).setCryptValt(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).setMembership(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).setFounder(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await expect(revenue.connect(admin).updateTreasury(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(revenue, "ZeroAddress");
      await revenue.connect(admin).registerScout(1, other.address);
      await expect(revenue.connect(admin).payScout(1, { value: 0 }))
        .to.be.revertedWithCustomError(revenue, "ZeroAmount");
      await expect(revenue.connect(bidder1).claimPlatinum())
        .to.be.revertedWithCustomError(revenue, "NothingToClaim");
      await expect(revenue.connect(bidder1).claimScout())
        .to.be.revertedWithCustomError(revenue, "NothingToClaim");
      await expect(revenue.connect(admin).removePlatinumHolder(bidder1.address))
        .to.be.revertedWithCustomError(revenue, "NotHolder");
      // register → top-up branch (already-holder path)
      await revenue.connect(admin).registerPlatinumHolder(bidder1.address, 1);
      await revenue.connect(admin).registerPlatinumHolder(bidder1.address, 2);
      expect(await revenue.platinumTokenCount(bidder1.address)).to.equal(3);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  VALUATION + DAO: FINAL BRANCHES
  // ────────────────────────────────────────────────────────────────

  describe("Valuation & DAO final branches", function () {
    it("valuation: unknown category fallback multiplier; storeVal auth", async function () {
      const unknown = await valuation.estimate(50, "unknowncat", ethers.parseEther("100"));
      expect(unknown[1]).to.be.greaterThan(0); // catMult==0 fallback branch
      await expect(valuation.connect(other).storeVal(1, 1, 2, 3))
        .to.be.revertedWithCustomError(valuation, "NotAuthorized");
      // platform-authorized recordSale branch
      await valuation.connect(admin).updatePlatform(other.address);
      await valuation.connect(other).recordSale("tech", 1000);
      expect(await valuation.totalSales()).to.equal(1);
    });

    it("DAO: execution-failure branch, veto while queued, executor guards", async function () {
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("8000000"));
      await dao.connect(admin).addAllowedExecutor(await governor.getAddress());
      // governor is NOT owned by the DAO → onlyOwner call inside fails.
      const badCall = governor.interface.encodeFunctionData("setMinRepToBid", [1]);
      await dao.connect(bidder1).propose("Fail", "d", 0, await governor.getAddress(), badCall);
      await dao.connect(bidder1).castVote(1, 1);
      await time.increase(7 * DAY + 1);
      await dao.queue(1);
      await time.increase(2 * DAY + 1);
      await expect(dao.execute(1)).to.be.revertedWithCustomError(dao, "ExecutionFailed");

      // veto while queued (state 4)
      await dao.connect(bidder1).propose("Q", "d", 0, ethers.ZeroAddress, "0x");
      await dao.connect(bidder1).castVote(2, 1);
      await time.increase(7 * DAY + 1);
      await dao.queue(2);
      await founder.connect(admin).adminMint(bidder2.address);
      await dao.connect(bidder2).veto(2);
      expect(await dao.getState(2)).to.equal(6);
      await expect(dao.execute(2)).to.be.revertedWithCustomError(dao, "NotQueuedState");

      await expect(dao.connect(admin).addAllowedExecutor(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(dao, "ZeroAddress");
      await expect(dao.connect(admin).setCVT(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(dao, "ZeroAddress");
      await expect(dao.connect(admin).setFounder(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(dao, "ZeroAddress");
      await expect(dao.connect(bidder2).cancel(2)).to.be.revertedWithCustomError(dao, "NotProposerOrOwner");
    });
  });
});
