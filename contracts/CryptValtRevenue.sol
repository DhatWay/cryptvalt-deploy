// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract CryptValtRevenue {

    address public owner;
    address public treasury;
    address public cryptvalt;
    address public membershipContract;
    address public founderContract;

    uint256 public constant PLATINUM_SHARE_BPS = 1000;
    uint256 public constant FOUNDER_SHARE_BPS  = 1500;
    uint256 public constant SCOUT_BASE_BPS     = 1500;
    uint256 public constant BPS                = 10000;
    uint256 public constant EMERGENCY_DELAY    = 48 hours;
    uint256 public emergencyWithdrawQueuedAt;

    uint256 public totalDeposited;
    uint256 public totalPlatinumPool;
    uint256 public totalFounderPool;
    uint256 public totalScoutPaid;
    uint256 public totalTreasuryPaid;

    uint256 public platinumRevenuePerToken;
    uint256 public founderRevenuePerToken;

    address[] public platinumHolders;
    mapping(address => bool)    public isPlatinumHolder;
    mapping(address => uint256) public platinumTokenCount;
    mapping(address => uint256) public platinumRevenueDebt;
    mapping(address => uint256) public platinumClaimed;

    address[] public founderHolders;
    mapping(address => bool)    public isFounderHolder;
    mapping(address => uint256) public founderTokenCount;
    mapping(address => uint256) public founderRevenueDebt;
    mapping(address => uint256) public founderClaimed;

    mapping(uint256 => address) public listingScout;
    mapping(address => uint256) public scoutEarnings;
    mapping(address => uint256) public scoutClaimed;
    mapping(address => uint256) public scoutListingsCount;
    mapping(address => uint256) public scoutSuccessCount;
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
    event TreasuryUpdated(address indexed newTreasury);
    event ContractsSet(address indexed cryptvalt, address indexed membership, address indexed founder);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event EmergencyWithdrawQueued(uint256 executableAt);

    modifier onlyOwner()    { require(msg.sender == owner, "Not owner");    _; }
    modifier onlyAuth()     { require(
        msg.sender == owner ||
        msg.sender == cryptvalt ||
        msg.sender == membershipContract ||
        msg.sender == founderContract,
        "Not authorized"
    ); _; }

    constructor(address _treasury) {
        require(_treasury != address(0), "Zero treasury");
        owner    = msg.sender;
        treasury = _treasury;
    }

    function deposit() external payable {
        require(msg.value > 0, "No value");
        _distribute(msg.value);
    }

    function _distribute(uint256 amount) internal {
        uint256 toPlatinum = (amount * PLATINUM_SHARE_BPS) / BPS;
        uint256 toFounder  = (amount * FOUNDER_SHARE_BPS)  / BPS;
        uint256 toTreasury = amount - toPlatinum - toFounder;

        totalDeposited += amount;

        if (platinumHolderCount > 0 && toPlatinum > 0) {
            platinumRevenuePerToken += toPlatinum / platinumHolderCount;
            totalPlatinumPool       += toPlatinum;
        } else {
            toTreasury += toPlatinum;
        }

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

    function registerScout(uint256 listingId, address scout) external onlyAuth {
        require(scout != address(0), "Zero address");
        require(listingScout[listingId] == address(0), "Scout already set");
        listingScout[listingId] = scout;
        scoutListingsCount[scout]++;
        if (scoutMultiplier[scout] == 0) scoutMultiplier[scout] = BPS;
        emit ScoutRegistered(listingId, scout);
    }

    function payScout(uint256 listingId, uint256 saleAmount) external onlyAuth {
        address scout = listingScout[listingId];
        if (scout == address(0)) return;

        uint256 platformFee  = (saleAmount * 2000) / BPS;
        uint256 scoutBase    = (platformFee * SCOUT_BASE_BPS) / BPS;
        uint256 multiplier   = scoutMultiplier[scout];
        uint256 scoutPayout  = (scoutBase * multiplier) / BPS;

        scoutEarnings[scout]    += scoutPayout;
        scoutSuccessCount[scout]++;
        totalScoutPaid          += scoutPayout;

        emit ScoutPaid(listingId, scout, scoutPayout);
    }

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

    function registerPlatinumHolder(address holder, uint256 tokenCount) external onlyAuth {
        require(holder != address(0), "Zero address");
        if (!isPlatinumHolder[holder]) {
            isPlatinumHolder[holder]        = true;
            platinumRevenueDebt[holder]     = platinumRevenuePerToken;
            platinumHolders.push(holder);
            platinumHolderCount++;
            emit HolderRegistered(holder, "PLATINUM");
        }
        platinumTokenCount[holder] += tokenCount;
    }

    // FIXED: removed auto-claim to prevent loss if transfer fails
    function removePlatinumHolder(address holder) external onlyAuth {
        require(isPlatinumHolder[holder], "Not holder");
        isPlatinumHolder[holder]    = false;
        platinumTokenCount[holder]  = 0;
        platinumHolderCount--;
        emit HolderRemoved(holder, "PLATINUM");
    }

    function registerFounderHolder(address holder, uint256 tokenCount) external onlyAuth {
        require(holder != address(0), "Zero address");
        if (!isFounderHolder[holder]) {
            isFounderHolder[holder]      = true;
            founderRevenueDebt[holder]   = founderRevenuePerToken;
            founderHolders.push(holder);
            founderHolderCount++;
            emit HolderRegistered(holder, "FOUNDER");
        }
        founderTokenCount[holder] += tokenCount;
    }

    // FIXED: removed auto-claim
    function removeFounderHolder(address holder) external onlyAuth {
        require(isFounderHolder[holder], "Not holder");
        isFounderHolder[holder]    = false;
        founderTokenCount[holder]  = 0;
        founderHolderCount--;
        emit HolderRemoved(holder, "FOUNDER");
    }

    function setScoutMultiplier(address scout, uint256 multiplierBPS) external onlyOwner {
        require(scout != address(0), "Zero address");
        require(multiplierBPS >= BPS && multiplierBPS <= 30000, "Invalid multiplier");
        scoutMultiplier[scout] = multiplierBPS;
    }

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

    function setCryptValt(address c)    external onlyOwner { require(c != address(0), "Zero"); cryptvalt = c; emit ContractsSet(c, membershipContract, founderContract); }
    function setMembership(address m)   external onlyOwner { require(m != address(0), "Zero"); membershipContract = m; emit ContractsSet(cryptvalt, m, founderContract); }
    function setFounder(address f)      external onlyOwner { require(f != address(0), "Zero"); founderContract = f; emit ContractsSet(cryptvalt, membershipContract, f); }
    function updateTreasury(address t)  external onlyOwner { require(t != address(0), "Zero"); treasury = t; emit TreasuryUpdated(t); }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function queueEmergencyWithdraw() external onlyOwner {
        emergencyWithdrawQueuedAt = block.timestamp;
        emit EmergencyWithdrawQueued(block.timestamp + EMERGENCY_DELAY);
    }

    function cancelEmergencyWithdraw() external onlyOwner { emergencyWithdrawQueuedAt = 0; }

    function emergencyWithdraw() external onlyOwner {
        require(emergencyWithdrawQueuedAt != 0, "Not queued");
        require(block.timestamp >= emergencyWithdrawQueuedAt + EMERGENCY_DELAY, "Timelock active");
        emergencyWithdrawQueuedAt = 0;
        (bool ok,) = payable(treasury).call{value: address(this).balance}("");
        require(ok, "Emergency withdraw failed");
    }

    receive() external payable { _distribute(msg.value); }
}