# CryptValt — v1 → v2.0 Security Fix Log (BUGS.md)

Full transparency log of every issue found during the v2.0 security
review, its potential impact, and the implemented fix. Each fix has a
dedicated regression test in `test/cryptvalt.test.js` (28/28 passing).

---

## CRITICAL

### BUG-001 — Under-collateralized sealed bids (CryptValt.sol)
- **Vulnerability:** `commitBid()` only required the deposit to meet the
  reserve price, while the hidden committed bid amount could be
  arbitrarily higher. A bidder could deposit 1 ETH, commit to a 100 ETH
  bid, win, and the escrow would owe the inventor 80% of funds it never
  held.
- **Impact:** Direct fund shortfall; inventors paid from other users'
  escrowed deposits (insolvency).
- **Fix (v2.0):** `revealBid()` reverts with `DepositTooLow` unless
  `depositAmount >= amount`. Bidders over-deposit to obscure their bid;
  the surplus is refunded at settlement.
- **Test:** "rejects a reveal whose amount exceeds the deposit".

### BUG-002 — Revenue pool insolvency via multi-token holders (CryptValtRevenue.sol)
- **Vulnerability:** The revenue accumulator divided by *holder count*
  but payouts multiplied by *token count*. A holder with 3 tokens was
  paid 3× their fair share, drawing from other participants' funds.
- **Impact:** Contract obligations exceeded holdings; later claimants
  could not withdraw.
- **Fix (v2.0):** Accumulator is per-token (divides by total registered
  tokens), matching the per-token payout math.
- **Test:** "pays multi-token holders per token WITHOUT overdraw".

### BUG-003 — Unfunded scout payouts (CryptValtRevenue.sol)
- **Vulnerability:** `payScout()` credited scout earnings without any
  ETH arriving; deposits had already been fully distributed to pools
  and treasury.
- **Impact:** Scout claims drained the Platinum/Founder pools.
- **Fix (v2.0):** `payScout()` is `payable` — the commission must
  physically arrive with the call.
- **Test:** "scout payouts must arrive funded".

## HIGH

### BUG-004 — Self-revenue on mint (CryptValtFounder.sol, CryptValtMembership.sol)
- **Vulnerability:** A minter's revenue baseline allowed their new
  token to claim a share of their own mint payment.
- **Impact:** Systematic over-entitlement diluting earlier holders.
- **Fix (v2.0):** Pool is updated with the mint's holder-share first
  (divided among pre-existing tokens only), and the new token's
  baseline is snapshotted after the update.
- **Note:** The first v2.0 draft ordered these operations incorrectly;
  the regression suite caught it before deployment and the ordering was
  corrected. Kept here for transparency.
- **Tests:** "minter earns nothing from their own mint payment" (both
  contracts).

### BUG-005 — Staking rewards rounded to zero (CryptValtToken.sol)
- **Vulnerability:** `rewardPerToken += amount / totalStaked` divided
  two 18-decimal values without scaling; most deposits rounded to 0.
- **Impact:** Deposited staking rewards permanently stuck; stakers
  earned nothing.
- **Fix (v2.0):** MasterChef-style accumulator scaled by 1e18.
- **Test:** "handles small reward deposits without total precision loss".

### BUG-006 — Unbounded settlement loops (CryptValt.sol)
- **Vulnerability:** `_findWinner` / `_refundAll` / `_refundLosers`
  looped over all bidders at settlement; enough bidders could exceed
  the block gas limit and permanently brick `settleAuction()`.
- **Impact:** Denial of service on settlement; escrowed funds stuck.
- **Fix (v2.0):** Winner is tracked incrementally at reveal time
  (settlement is O(1)); losing bidders reclaim deposits individually
  via pull-pattern `claimBidRefund()`.
- **Test:** full-lifecycle + refund-path tests.

### BUG-007 — Revenue lost on holder removal (CryptValtRevenue.sol)
- **Vulnerability:** `removePlatinumHolder` / `removeFounderHolder`
  zeroed a holder's stake without settling pending revenue.
- **Impact:** Holders silently lost earned but unclaimed revenue.
- **Fix (v2.0):** All registration changes settle pending revenue into
  a claimable credit first.
- **Test:** "settles pending revenue before holder removal".

## MEDIUM

### BUG-008 — Push-payment griefing (CryptValt.sol)
- **Vulnerability:** Fund release pushed ETH via `.call`; a recipient
  contract that reverts could block settlement.
- **Fix (v2.0):** All payouts route through `pendingWithdrawals` +
  `withdraw()` (pull pattern).

### BUG-009 — Single-step ownership transfer (all contracts)
- **Vulnerability:** A typo'd `transferOwnership()` address would
  permanently brick admin control.
- **Fix (v2.0):** OpenZeppelin `Ownable2Step` on 7 contracts;
  `AccessControlDefaultAdminRules` (two-step + 24h delay) on the core.

### BUG-010 — DAO quorum manipulation (CryptValtDAO.sol)
- **Vulnerability:** Quorum was measured against live total supply;
  mint/burn during a vote could move the goalposts.
- **Fix (v2.0):** Total supply snapshotted at proposal creation.
- **Test:** "full proposal lifecycle with quorum snapshot".

## KNOWN LIMITATIONS (documented, not yet fixed)

### KL-001 — Live voting power in the DAO
Voting power is read at vote time rather than from historical
checkpoints, so tokens moved between wallets during a voting period
could vote more than once. Mitigations: one vote per wallet per
proposal, Founder veto, execution target whitelist, 48h execution
timelock, owner pause. Planned fix: migrate CVT to ERC20Votes
checkpoints before the DAO controls treasury funds (v3).
