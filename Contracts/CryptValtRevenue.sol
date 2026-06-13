// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * CryptValt Revenue Sharing Contract
 *
 * Automatically distributes platform revenue to:
 * 1. Platinum NFT holders      — 10% of all fees
 * 2. Founder NFT holders       — 15% of all fees (2x multiplier vs Platinum)
 * 3. Scout referral payouts    — variable % per successful sale
 * 4. Platform treasury         — remainder
 *
 * Revenue sources:
 * - CryptValt platform fees (20% of every sale)
 * - Secondary market fees
 * - Membership mint proceeds
 * - Founder NFT mint proceeds
 *
 * Distribution on every deposit:
 * - 10% → Platinum pool
 * - 15% → Founder pool
 * - Scout referral → paid out per listing if applicable
 * - Remainder → treasury
 *
 * All distributions are pull-based (claim model) to prevent
 * reentrancy and gas issues with large holder sets.
 */

contract CryptValtRevenue {

    address public owner;
    address public treasury;
    address public cryptvalt;
    address public membershipContract;
    address public founderContract;

    uint256 public constant PLATINUM_SHARE_BPS = 1000; // 10%
    uint256 public constant FOUNDER_SHARE_BPS  = 1500; // 15%
    uint256 public constant SCOUT_BASE_BPS     = 1500; // 15% of platform fee to scout
    uint256 public constant BPS                = 10000;

    uint256 public totalDeposited;
    uint256 public totalPlatinumPool;
    uint256 public totalFounderPool;
    uint256 public totalScoutPaid;
    uint256 public totalTreasuryPaid;

    // Per-token revenue tracking
    uint256 public platinumRevenuePerToken;
    uint256 public founderRevenuePerToken;

    // Platinum holders tracking
    address[] public platinumHolders;
    mapping(address => bool)    public isPlatinumHolder;
    mapping(address => uint256) public platinumTokenCount;
    mapping(address => uint256) public platinumRevenueDebt;
    mapping(address => uint256) public platinumClaimed;

    // Founder holders tracking
    address[] public founderHolders;
    mapping(address => bool)    public isFounderHolder;
    mapping(address => uint256) public founderTokenCount;
    mapping(address => uint256) public founderRevenueDebt;
    mapping(address => uint256) public founderClaimed;

    // Scout referral tracking
    mapping(uint256 => address) public listingScout;      // listingId => scout wallet
    mapping(address => uint256) public scoutEarnings;
    mapping(address => uint256) public scoutClaimed;
    mapping(address => uint256) public scoutListingsCount;
    mapping(address => uint256) public scoutSuccessCount;

    // Tier multipliers (BPS — 10000 = 1x)
    mapping(address => uint256) public scoutMultiplier;

    uint256 public platinumHolderCount;
    uint256 public founderHolderCount;

    event RevenueDeposited(uint256 amount, uint256 platinumShare, uint256 founderShare, uint256 treasuryShare);
    event PlatinumClaimed(address indexed holder, uint256 amount);
    event FounderClaimed(address indexed holder, uint256 amount);
    event ScoutClaimed(address indexed scout, uint256 amount);
    event ScoutRegistered(uint256 indexed listingId, address indexed scout);
    event ScoutPaid(uint256 indexed listingId, address indexed scout, uint256 amount);
    event HolderRegistered(address indexed holder, string tier);
    event HolderRemoved(address indexed holder, string tier);

    modifier onlyOwner()    { require(msg.sender == owner,    "Not owner");    _; }
    modifier onlyAuth()     { require(
        msg.sender == owner ||
        msg.sender == cryptvalt ||
        msg.sender == membershipContract ||
        msg.sender == founderContract,
        "Not authorized"
    ); _; }

    constructor(address _treasury) {
        owner    = msg.sender;
        treasury = _treasury;
    }

    // ── Deposit Revenue ────────────────────────────────────
    function deposit() external payable {
        require(msg.value > 0, "No value");
        _distribute(msg.value);
    }

    function _distribute(uint256 amount) internal {
        uint256 toPlatinum = (amount * PLATINUM_SHARE_BPS) / BPS;
        uint256 toFounder  = (amount * FOUNDER_SHARE_BPS)  / BPS;
        uint256 toTreasury = amount - toPlatinum - toFounder;

        totalDeposited += amount;

        // Platinum pool
        if (platinumHolderCount > 0 && toPlatinum > 0) {
            platinumRevenuePerToken += toPlatinum / platinumHolderCount;
            totalPlatinumPool       += toPlatinum;
        } else {
            toTreasury += toPlatinum;
        }

        // Founder pool
        if (founderHolderCount > 0 && toFounder > 0) {
            founderRevenuePerToken += toFounder / founderHolderCount;
            totalFounderPool       += toFounder;
        } else {
            toTreasury += toFounder;
        }

        totalTreasuryPaid += toTreasury;

        if (toTreasury > 0) {
            (bool ok,) = payable(treasury).call{value: toTreasury}("");
            require(ok, "Treasury transfer failed");
        }

        emit RevenueDeposited(amount, toPlatinum, toFounder, toTreasury);
    }

    // ── Scout Referral Payout ──────────────────────────────
    function registerScout(uint256 listingId, address scout) external onlyAuth {
        require(scout != address(0),               "Zero address");
        require(listingScout[listingId] == address(0), "Scout already set");
        listingScout[listingId] = scout;
        scoutListingsCount[scout]++;

        // Set default multiplier if not set
        if (scoutMultiplier[scout] == 0) scoutMultiplier[scout] = BPS; // 1x

        emit ScoutRegistered(listingId, scout);
    }

    function payScout(uint256 listingId, uint256 saleAmount) external onlyAuth {
        address scout = listingScout[listingId];
        if (scout == address(0)) return;

        // Scout gets SCOUT_BASE_BPS of platform fee (which is 20% of saleAmount)
        uint256 platformFee  = (saleAmount * 2000) / BPS; // 20%
        uint256 scoutBase    = (platformFee * SCOUT_BASE_BPS) / BPS;
        uint256 multiplier   = scoutMultiplier[scout];
        uint256 scoutPayout  = (scoutBase * multiplier) / BPS;

        scoutEarnings[scout]    += scoutPayout;
        scoutSuccessCount[scout]++;
        totalScoutPaid          += scoutPayout;

        emit ScoutPaid(listingId, scout, scoutPayout);
    }

    // ── Claim Functions ────────────────────────────────────
    function claimPlatinum() external {
        require(isPlatinumHolder[msg.sender], "Not a Platinum holder");
        uint256 owed = pendingPlatinum(msg.sender);
        require(owed > 0, "Nothing to claim");
        platinumClaimed[msg.sender]     += owed;
        platinumRevenueDebt[msg.sender]  = platinumRevenuePerToken;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        require(ok, "Transfer failed");
        emit PlatinumClaimed(msg.sender, owed);
    }

    function claimFounder() external {
        require(isFounderHolder[msg.sender], "Not a Founder holder");
        uint256 owed = pendingFounder(msg.sender);
        require(owed > 0, "Nothing to claim");
        founderClaimed[msg.sender]     += owed;
        founderRevenueDebt[msg.sender]  = founderRevenuePerToken;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        require(ok, "Transfer failed");
        emit FounderClaimed(msg.sender, owed);
    }

    function claimScout() external {
        uint256 owed = scoutEarnings[msg.sender] - scoutClaimed[msg.sender];
        require(owed > 0, "Nothing to claim");
        scoutClaimed[msg.sender] += owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        require(ok, "Transfer failed");
        emit ScoutClaimed(msg.sender, owed);
    }

    function claimAll() external {
        uint256 total;

        if (isPlatinumHolder[msg.sender]) {
            uint256 p = pendingPlatinum(msg.sender);
            if (p > 0) {
                platinumClaimed[msg.sender]     += p;
                platinumRevenueDebt[msg.sender]  = platinumRevenuePerToken;
                total += p;
            }
        }

        if (isFounderHolder[msg.sender]) {
            uint256 f = pendingFounder(msg.sender);
            if (f > 0) {
                founderClaimed[msg.sender]     += f;
                founderRevenueDebt[msg.sender]  = founderRevenuePerToken;
                total += f;
            }
        }

        uint256 s = scoutEarnings[msg.sender] - scoutClaimed[msg.sender];
        if (s > 0) {
            scoutClaimed[msg.sender] += s;
            total += s;
        }

        require(total > 0, "Nothing to claim");
        (bool ok,) = payable(msg.sender).call{value: total}("");
        require(ok, "Transfer failed");
    }

    // ── Pending Calculations ───────────────────────────────
    function pendingPlatinum(address holder) public view returns (uint256) {
        if (!isPlatinumHolder[holder]) return 0;
        uint256 perToken = platinumRevenuePerToken - platinumRevenueDebt[holder];
        uint256 tokens   = platinumTokenCount[holder];
        uint256 earned   = perToken * tokens;
        uint256 already  = platinumClaimed[holder];
        return earned > already ? earned - already : 0;
    }

    function pendingFounder(address holder) public view returns (uint256) {
        if (!isFounderHolder[holder]) return 0;
        uint256 perToken = founderRevenuePerToken - founderRevenueDebt[holder];
        uint256 tokens   = founderTokenCount[holder];
        uint256 earned   = perToken * tokens;
        uint256 already  = founderClaimed[holder];
        return earned > already ? earned - already : 0;
    }

    function pendingScout(address scout) public view returns (uint256) {
        return scoutEarnings[scout] - scoutClaimed[scout];
    }

    function pendingAll(address wallet) external view returns (uint256 platinum, uint256 founder, uint256 scout, uint256 total) {
        platinum = pendingPlatinum(wallet);
        founder  = pendingFounder(wallet);
        scout    = pendingScout(wallet);
        total    = platinum + founder + scout;
    }

    // ── Holder Registration ────────────────────────────────
    function registerPlatinumHolder(address holder, uint256 tokenCount) external onlyAuth {
        if (!isPlatinumHolder[holder]) {
            isPlatinumHolder[holder]        = true;
            platinumRevenueDebt[holder]     = platinumRevenuePerToken;
            platinumHolders.push(holder);
            platinumHolderCount++;
            emit HolderRegistered(holder, "PLATINUM");
        }
        platinumTokenCount[holder] += tokenCount;
    }

    function removePlatinumHolder(address holder) external onlyAuth {
        if (isPlatinumHolder[holder]) {
            // Auto-claim pending before removing
            uint256 owed = pendingPlatinum(holder);
            if (owed > 0) {
                platinumClaimed[holder] += owed;
                (bool ok,) = payable(holder).call{value: owed}("");
                if (ok) emit PlatinumClaimed(holder, owed);
            }
            isPlatinumHolder[holder]    = false;
            platinumTokenCount[holder]  = 0;
            platinumHolderCount--;
            emit HolderRemoved(holder, "PLATINUM");
        }
    }

    function registerFounderHolder(address holder, uint256 tokenCount) external onlyAuth {
        if (!isFounderHolder[holder]) {
            isFounderHolder[holder]      = true;
            founderRevenueDebt[holder]   = founderRevenuePerToken;
            founderHolders.push(holder);
            founderHolderCount++;
            emit HolderRegistered(holder, "FOUNDER");
        }
        founderTokenCount[holder] += tokenCount;
    }

    function removeFounderHolder(address holder) external onlyAuth {
        if (isFounderHolder[holder]) {
            uint256 owed = pendingFounder(holder);
            if (owed > 0) {
                founderClaimed[holder] += owed;
                (bool ok,) = payable(holder).call{value: owed}("");
                if (ok) emit FounderClaimed(holder, owed);
            }
            isFounderHolder[holder]    = false;
            founderTokenCount[holder]  = 0;
            founderHolderCount--;
            emit HolderRemoved(holder, "FOUNDER");
        }
    }

    // ── Scout Multiplier ───────────────────────────────────
    function setScoutMultiplier(address scout, uint256 multiplierBPS) external onlyOwner {
        require(multiplierBPS >= BPS && multiplierBPS <= 30000, "Invalid multiplier");
        scoutMultiplier[scout] = multiplierBPS;
    }

    // ── View Functions ─────────────────────────────────────
    function getStats() external view returns (
        uint256 deposited,
        uint256 platPool,
        uint256 foundPool,
        uint256 scoutPaid,
        uint256 treasuryPaid,
        uint256 platHolders,
        uint256 foundHolders
    ) {
        return (
            totalDeposited, totalPlatinumPool, totalFounderPool,
            totalScoutPaid, totalTreasuryPaid,
            platinumHolderCount, founderHolderCount
        );
    }

    function getScoutStats(address scout) external view returns (
        uint256 listings, uint256 successes, uint256 earnings,
        uint256 claimedAmt, uint256 pending, uint256 multiplier
    ) {
        return (
            scoutListingsCount[scout],
            scoutSuccessCount[scout],
            scoutEarnings[scout],
            scoutClaimed[scout],
            pendingScout(scout),
            scoutMultiplier[scout]
        );
    }

    // ── Admin ──────────────────────────────────────────────
    function setCryptValt(address c)    external onlyOwner { cryptvalt          = c; }
    function setMembership(address m)   external onlyOwner { membershipContract = m; }
    function setFounder(address f)      external onlyOwner { founderContract    = f; }
    function updateTreasury(address t)  external onlyOwner { treasury           = t; }

    function emergencyWithdraw() external onlyOwner {
        (bool ok,) = payable(treasury).call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable { _distribute(msg.value); }
}
