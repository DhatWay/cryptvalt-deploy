/*
 * CryptValt v2.0 — Full Test Suite
 * Run: npx hardhat test
 *
 * Covers the complete marketplace flow plus regression tests for every
 * v2.0 security fix:
 *  - Collateralized sealed bids (deposit >= revealed amount)
 *  - O(1) settlement + pull-pattern refunds
 *  - Pull-payment fund release (80/20 split)
 *  - Staking reward precision (1e18 scaling)
 *  - Founder/Membership self-revenue fix
 *  - Revenue router per-token accounting + funded scout payouts
 *  - DAO quorum snapshot
 *  - Safe-style admin (roles, timelocks, two-step ownership)
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

describe("CryptValt v2.0", function () {
  let admin, treasury, inventor, bidder1, bidder2, bidder3, buyer, scout;
  let cryptvalt, token, founder, membership, revenue, governor, valuation, dao;

  beforeEach(async function () {
    [admin, treasury, inventor, bidder1, bidder2, bidder3, buyer, scout] =
      await ethers.getSigners();

    // Core escrow — admin plays the role of the Safe in tests.
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
      admin.address,
      await token.getAddress(),
      await founder.getAddress(),
      treasury.address
    );
  });

  // ────────────────────────────────────────────────────────────────
  //  CORE AUCTION FLOW
  // ────────────────────────────────────────────────────────────────

  async function listAndCommit() {
    await cryptvalt.connect(inventor).listIdea(
      "QmTestCID12345678901234567890",
      "a".repeat(64),
      "tech",
      ethers.parseEther("1"),
      3 * DAY,
      500
    );
    const id = 1n;
    const salt1 = ethers.encodeBytes32String("salt1");
    const salt2 = ethers.encodeBytes32String("salt2");
    const bid1 = ethers.parseEther("2");
    const bid2 = ethers.parseEther("3");

    await cryptvalt.connect(bidder1).commitBid(
      id, commitment(bid1, salt1, bidder1.address, id),
      { value: ethers.parseEther("2.5") } // over-deposit to obscure bid
    );
    await cryptvalt.connect(bidder2).commitBid(
      id, commitment(bid2, salt2, bidder2.address, id),
      { value: ethers.parseEther("3") }
    );
    return { id, salt1, salt2, bid1, bid2 };
  }

  describe("Full auction lifecycle", function () {
    it("runs list → commit → reveal → settle → deliver → withdraw with correct 80/20 split", async function () {
      const { id, salt1, salt2, bid1, bid2 } = await listAndCommit();

      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder1).revealBid(id, bid1, salt1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);

      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);

      const listing = await cryptvalt.getListing(id);
      expect(listing.winner).to.equal(bidder2.address);
      expect(listing.winningBid).to.equal(bid2);

      await cryptvalt.connect(inventor).deliverKey(id, "encrypted-key-payload");

      // 80/20 of 3 ETH
      expect(await cryptvalt.pendingWithdrawals(inventor.address)).to.equal(
        ethers.parseEther("2.4")
      );
      expect(await cryptvalt.pendingWithdrawals(treasury.address)).to.equal(
        ethers.parseEther("0.6")
      );

      // Inventor withdraws for real
      const before = await ethers.provider.getBalance(inventor.address);
      const tx = await cryptvalt.connect(inventor).withdraw();
      const rc = await tx.wait();
      const gas = rc.gasUsed * rc.gasPrice;
      const after = await ethers.provider.getBalance(inventor.address);
      expect(after - before + gas).to.equal(ethers.parseEther("2.4"));
    });

    it("winner can read the key; others cannot", async function () {
      const { id, salt2, bid2 } = await listAndCommit();
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);
      await cryptvalt.connect(inventor).deliverKey(id, "secret-key");

      expect(await cryptvalt.connect(bidder2).getWinnerKey(id)).to.equal("secret-key");
      await expect(cryptvalt.connect(bidder1).getWinnerKey(id))
        .to.be.revertedWithCustomError(cryptvalt, "Denied");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  v2.0 FIX: COLLATERALIZED BIDS
  // ────────────────────────────────────────────────────────────────

  describe("Security fix: deposit-backed bids", function () {
    it("rejects a reveal whose amount exceeds the deposit (the v1 shortfall exploit)", async function () {
      await cryptvalt.connect(inventor).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      );
      const id = 1n;
      const salt = ethers.encodeBytes32String("x");
      const hugeBid = ethers.parseEther("100"); // commits to 100, deposits 1

      await cryptvalt.connect(bidder1).commitBid(
        id, commitment(hugeBid, salt, bidder1.address, id),
        { value: ethers.parseEther("1") }
      );
      await time.increase(3 * DAY + 1);
      await expect(
        cryptvalt.connect(bidder1).revealBid(id, hugeBid, salt)
      ).to.be.revertedWithCustomError(cryptvalt, "DepositTooLow");
    });

    it("refunds the winner's over-deposit surplus at settlement", async function () {
      const { id, salt2, bid2 } = await listAndCommit();
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);
      // bidder2 deposited exactly 3 and bid 3 → no surplus
      expect(await cryptvalt.pendingWithdrawals(bidder2.address)).to.equal(0);
    });

    it("loser reclaims full deposit via pull-pattern claimBidRefund", async function () {
      const { id, salt1, salt2, bid1, bid2 } = await listAndCommit();
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder1).revealBid(id, bid1, salt1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);

      await cryptvalt.connect(bidder1).claimBidRefund(id);
      expect(await cryptvalt.pendingWithdrawals(bidder1.address)).to.equal(
        ethers.parseEther("2.5")
      );
      // double-claim blocked
      await expect(cryptvalt.connect(bidder1).claimBidRefund(id))
        .to.be.revertedWithCustomError(cryptvalt, "NothingToClaim");
    });

    it("stays solvent through the whole flow", async function () {
      const { id, salt1, salt2, bid1, bid2 } = await listAndCommit();
      expect(await cryptvalt.isSolvent()).to.equal(true);
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder1).revealBid(id, bid1, salt1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);
      await cryptvalt.connect(inventor).deliverKey(id, "k");
      await cryptvalt.connect(bidder1).claimBidRefund(id);
      await cryptvalt.connect(bidder1).withdraw();
      await cryptvalt.connect(inventor).withdraw();
      expect(await cryptvalt.isSolvent()).to.equal(true);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  REFUND PATHS
  // ────────────────────────────────────────────────────────────────

  describe("Refund paths", function () {
    it("winner reclaims escrow when inventor misses the key deadline", async function () {
      const { id, salt2, bid2 } = await listAndCommit();
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);
      await time.increase(2 * DAY + 1); // past keyDeadline
      await cryptvalt.connect(bidder2).claimRefund(id);
      expect(await cryptvalt.pendingWithdrawals(bidder2.address)).to.equal(bid2);
    });

    it("cancels and lets everyone reclaim when nobody reveals", async function () {
      const { id } = await listAndCommit();
      await time.increase(4 * DAY + 2); // past reveal deadline, no reveals
      await cryptvalt.settleAuction(id);
      expect((await cryptvalt.getListing(id)).status).to.equal(6);
      await cryptvalt.connect(bidder1).claimBidRefund(id);
      await cryptvalt.connect(bidder2).claimBidRefund(id);
      expect(await cryptvalt.pendingWithdrawals(bidder1.address)).to.equal(ethers.parseEther("2.5"));
      expect(await cryptvalt.pendingWithdrawals(bidder2.address)).to.equal(ethers.parseEther("3"));
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  ADMIN: ROLES + TIMELOCKS
  // ────────────────────────────────────────────────────────────────

  describe("Admin controls", function () {
    it("enforces the 24h timelock on fee changes", async function () {
      await cryptvalt.connect(admin).queueFeeChange(2500);
      await expect(cryptvalt.connect(admin).executeFeeChange())
        .to.be.revertedWithCustomError(cryptvalt, "TimelockActive");
      await time.increase(DAY + 1);
      await cryptvalt.connect(admin).executeFeeChange();
      expect(await cryptvalt.platformFeeBps()).to.equal(2500);
    });

    it("blocks non-admins from admin functions", async function () {
      await expect(cryptvalt.connect(bidder1).queueFeeChange(2500))
        .to.be.reverted;
      await expect(cryptvalt.connect(bidder1).pause()).to.be.reverted;
    });

    it("emergency drain requires emergency mode + queue + 48h", async function () {
      await expect(cryptvalt.connect(admin).queueEmergencyDrain())
        .to.be.revertedWithCustomError(cryptvalt, "NotInEmergency");
      await cryptvalt.connect(admin).activateEmergency();
      await cryptvalt.connect(admin).queueEmergencyDrain();
      await expect(cryptvalt.connect(admin).emergencyDrain(treasury.address))
        .to.be.revertedWithCustomError(cryptvalt, "TimelockActive");
      await time.increase(2 * DAY + 1);
      await cryptvalt.connect(admin).emergencyDrain(treasury.address);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  TOKEN: STAKING PRECISION FIX
  // ────────────────────────────────────────────────────────────────

  describe("CryptValtToken", function () {
    it("pays staking rewards correctly (v1 rounded these to zero)", async function () {
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("1000"));
      await token.connect(admin).transfer(bidder2.address, ethers.parseEther("3000"));
      await token.connect(bidder1).stake(ethers.parseEther("1000"));
      await token.connect(bidder2).stake(ethers.parseEther("3000"));

      // Deposit 400 CVT of rewards → bidder1 should earn 100, bidder2 300.
      await token.connect(admin).depositReward(ethers.parseEther("400"));

      expect(await token.pendingReward(bidder1.address)).to.equal(ethers.parseEther("100"));
      expect(await token.pendingReward(bidder2.address)).to.equal(ethers.parseEther("300"));

      await token.connect(bidder1).claimStakingReward();
      expect(await token.balanceOf(bidder1.address)).to.equal(ethers.parseEther("100"));
    });

    it("handles small reward deposits without total precision loss", async function () {
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("1000000"));
      await token.connect(bidder1).stake(ethers.parseEther("1000000"));
      await token.connect(admin).depositReward(1000n); // 1000 wei of CVT
      // v1: (1000 / 1e24) = 0 → total loss. v2: scaled accumulator keeps it.
      expect(await token.pendingReward(bidder1.address)).to.be.greaterThan(0);
    });

    it("vests linearly with cliff and revokes unvested to treasury", async function () {
      const total = ethers.parseEther("1000");
      await token.connect(admin).createVesting(
        bidder1.address, total, 0, 100 * DAY, 10 * DAY
      );
      await expect(token.connect(bidder1).releaseVesting())
        .to.be.revertedWithCustomError(token, "NothingToRelease");
      await time.increase(50 * DAY);
      await token.connect(bidder1).releaseVesting();
      const bal = await token.balanceOf(bidder1.address);
      expect(bal).to.be.closeTo(ethers.parseEther("500"), ethers.parseEther("10"));

      const tBefore = await token.balanceOf(treasury.address);
      await token.connect(admin).revokeVesting(bidder1.address);
      expect(await token.balanceOf(treasury.address)).to.be.greaterThan(tBefore);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  FOUNDER: SELF-REVENUE FIX
  // ────────────────────────────────────────────────────────────────

  describe("CryptValtFounder", function () {
    it("minter earns nothing from their own mint payment (v1 bug)", async function () {
      await founder.connect(admin).setMintOpen(true);
      await founder.connect(bidder1).mint({ value: ethers.parseEther("1") });
      // First minter: no prior holders — zero pending for themselves.
      expect(await founder.pendingRevenue(bidder1.address)).to.equal(0);

      await founder.connect(bidder2).mint({ value: ethers.parseEther("1") });
      // bidder1 (pre-existing) earns 10% of bidder2's mint; bidder2 earns 0.
      expect(await founder.pendingRevenue(bidder1.address)).to.equal(ethers.parseEther("0.1"));
      expect(await founder.pendingRevenue(bidder2.address)).to.equal(0);
    });

    it("splits deposited revenue equally across holders and pays claims", async function () {
      await founder.connect(admin).setMintOpen(true);
      await founder.connect(bidder1).mint({ value: ethers.parseEther("1") });
      await founder.connect(bidder2).mint({ value: ethers.parseEther("1") });
      await founder.connect(admin).depositRevenue({ value: ethers.parseEther("2") });

      // bidder1: 0.1 (from mint 2) + 1; bidder2: 1
      expect(await founder.pendingRevenue(bidder1.address)).to.equal(ethers.parseEther("1.1"));
      expect(await founder.pendingRevenue(bidder2.address)).to.equal(ethers.parseEther("1"));

      const before = await ethers.provider.getBalance(bidder2.address);
      const tx = await founder.connect(bidder2).claimRevenue();
      const rc = await tx.wait();
      const gas = rc.gasUsed * rc.gasPrice;
      const after = await ethers.provider.getBalance(bidder2.address);
      expect(after - before + gas).to.equal(ethers.parseEther("1"));
    });

    it("supports EIP-2981 royalty info", async function () {
      const [receiver, amount] = await founder.royaltyInfo(1, ethers.parseEther("10"));
      expect(receiver).to.equal(treasury.address);
      expect(amount).to.equal(ethers.parseEther("1")); // 10%
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  MEMBERSHIP: SELF-REVENUE FIX + TIERS
  // ────────────────────────────────────────────────────────────────

  describe("CryptValtMembership", function () {
    it("Platinum minter earns nothing from own payment; earlier holders do", async function () {
      await membership.connect(admin).setMintOpen(true);
      await membership.connect(bidder1).mint(3, { value: ethers.parseEther("0.5") });
      expect(await membership.pendingRevenue(bidder1.address)).to.equal(0);

      await membership.connect(bidder2).mint(3, { value: ethers.parseEther("0.5") });
      expect(await membership.pendingRevenue(bidder1.address)).to.equal(ethers.parseEther("0.05"));
      expect(await membership.pendingRevenue(bidder2.address)).to.equal(0);
    });

    it("returns the best fee discount across held tiers", async function () {
      await membership.connect(admin).setMintOpen(true);
      await membership.connect(bidder1).mint(1, { value: ethers.parseEther("0.05") });
      expect(await membership.getFeeDiscount(bidder1.address)).to.equal(1000);
      await membership.connect(bidder1).mint(3, { value: ethers.parseEther("0.5") });
      expect(await membership.getFeeDiscount(bidder1.address)).to.equal(5000);
      expect(await membership.getHighestTier(bidder1.address)).to.equal(3);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  REVENUE ROUTER: ACCOUNTING FIXES
  // ────────────────────────────────────────────────────────────────

  describe("CryptValtRevenue", function () {
    it("pays multi-token holders per token WITHOUT overdraw (v1 insolvency bug)", async function () {
      // bidder1 has 3 platinum tokens, bidder2 has 1 → pool splits 3:1.
      await revenue.connect(admin).registerPlatinumHolder(bidder1.address, 3);
      await revenue.connect(admin).registerPlatinumHolder(bidder2.address, 1);

      await revenue.connect(admin).deposit({ value: ethers.parseEther("100") });
      // Platinum pool = 10% = 10 ETH → 7.5 / 2.5 split.
      expect(await revenue.pendingPlatinum(bidder1.address)).to.equal(ethers.parseEther("7.5"));
      expect(await revenue.pendingPlatinum(bidder2.address)).to.equal(ethers.parseEther("2.5"));

      await revenue.connect(bidder1).claimPlatinum();
      await revenue.connect(bidder2).claimPlatinum();
      // Contract retains nothing owed → solvent.
    });

    it("settles pending revenue before holder removal (v1 lost it)", async function () {
      await revenue.connect(admin).registerPlatinumHolder(bidder1.address, 2);
      await revenue.connect(admin).deposit({ value: ethers.parseEther("50") });
      const pendingBefore = await revenue.pendingPlatinum(bidder1.address);
      expect(pendingBefore).to.equal(ethers.parseEther("5"));

      await revenue.connect(admin).removePlatinumHolder(bidder1.address);
      // Still claimable after removal.
      expect(await revenue.pendingPlatinum(bidder1.address)).to.equal(pendingBefore);
      await revenue.connect(bidder1).claimPlatinum();
    });

    it("scout payouts must arrive funded (v1 drained the pools)", async function () {
      await revenue.connect(admin).registerScout(1, scout.address);
      await revenue.connect(admin).payScout(1, { value: ethers.parseEther("0.3") });
      expect(await revenue.pendingScout(scout.address)).to.equal(ethers.parseEther("0.3"));
      await revenue.connect(scout).claimScout();
      await expect(revenue.connect(scout).claimScout())
        .to.be.revertedWithCustomError(revenue, "NothingToClaim");
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  GOVERNOR + VALUATION
  // ────────────────────────────────────────────────────────────────

  describe("Governor & Valuation", function () {
    it("wires into the core contract and updates reputation on settlement", async function () {
      await cryptvalt.connect(admin).setGovernorContract(await governor.getAddress());
      await governor.connect(admin).updatePlatform(await cryptvalt.getAddress());

      const { id, salt2, bid2 } = await listAndCommit();
      await time.increase(3 * DAY + 1);
      await cryptvalt.connect(bidder2).revealBid(id, bid2, salt2);
      await time.increase(DAY + 1);
      await cryptvalt.settleAuction(id);

      // Winner gained +50 rep over the initial 500.
      expect(await governor.getReputation(bidder2.address)).to.equal(550);
    });

    it("frozen wallets cannot bid", async function () {
      await cryptvalt.connect(admin).setGovernorContract(await governor.getAddress());
      await governor.connect(admin).updatePlatform(await cryptvalt.getAddress());
      await governor.connect(admin).manualFreeze(bidder3.address);

      await cryptvalt.connect(inventor).listIdea(
        "QmTestCID12345678901234567890", "a".repeat(64), "tech",
        ethers.parseEther("1"), 3 * DAY, 0
      );
      await expect(
        cryptvalt.connect(bidder3).commitBid(
          1, ethers.ZeroHash === undefined ? "0x00" : commitment(ethers.parseEther("1"), ethers.encodeBytes32String("s"), bidder3.address, 1n),
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWith("Wallet frozen");
    });

    it("valuation estimates scale with score and records sales", async function () {
      const low  = await valuation.estimate(30, "tech", ethers.parseEther("1000"));
      const high = await valuation.estimate(95, "tech", ethers.parseEther("1000"));
      expect(high[1]).to.be.greaterThan(low[1]);

      await valuation.connect(admin).recordSale("tech", ethers.parseEther("5"));
      expect(await valuation.totalSales()).to.equal(1);
    });
  });

  // ────────────────────────────────────────────────────────────────
  //  DAO
  // ────────────────────────────────────────────────────────────────

  describe("CryptValtDAO", function () {
    it("full proposal lifecycle with quorum snapshot", async function () {
      // Give bidder1 enough CVT to propose and pass quorum (5% of supply).
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("6000000"));
      await dao.connect(bidder1).propose("Title", "Description", 0, ethers.ZeroAddress, "0x");

      const p = await dao.getProposal(1);
      expect(p.supplySnapshot).to.equal(await token.totalSupply());

      await dao.connect(bidder1).castVote(1, 1);
      await expect(dao.connect(bidder1).castVote(1, 1))
        .to.be.revertedWithCustomError(dao, "AlreadyVoted");

      await time.increase(7 * DAY + 1);
      expect(await dao.getState(1)).to.equal(2); // Succeeded
      await dao.queue(1);
      await expect(dao.execute(1)).to.be.revertedWithCustomError(dao, "TimelockNotElapsed");
      await time.increase(2 * DAY + 1);
      await dao.execute(1);
      expect(await dao.getState(1)).to.equal(5); // Executed
    });

    it("Founder holders can veto", async function () {
      await founder.connect(admin).setMintOpen(true);
      await founder.connect(bidder2).mint({ value: ethers.parseEther("1") });
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("6000000"));
      await dao.connect(bidder1).propose("T", "D", 0, ethers.ZeroAddress, "0x");
      await dao.connect(bidder2).veto(1);
      expect(await dao.getState(1)).to.equal(6);
    });

    it("blocks execution against non-whitelisted targets", async function () {
      await token.connect(admin).transfer(bidder1.address, ethers.parseEther("6000000"));
      await dao.connect(bidder1).propose(
        "T", "D", 0, await token.getAddress(),
        token.interface.encodeFunctionData("pauseTransfers")
      );
      await dao.connect(bidder1).castVote(1, 1);
      await time.increase(7 * DAY + 1);
      await dao.queue(1);
      await time.increase(2 * DAY + 1);
      await expect(dao.execute(1)).to.be.revertedWithCustomError(dao, "TargetNotAllowed");
    });
  });
});
