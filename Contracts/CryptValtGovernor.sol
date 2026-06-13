// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract CryptValtGovernor {

    address public owner;
    address public platform;
    bool    public active = true;

    uint256 public constant INITIAL_REP   = 500;
    uint256 public constant MAX_REP       = 1000;
    uint256 public constant FREEZE_THRESH = 50;

    uint256 public minRepToBid  = 100;
    uint256 public minRepToList = 150;
    uint256 public maxBidsPerHr = 20;
    uint256 public totalFlags;
    uint256 public totalFreezes;

    mapping(address => uint256) public reputation;
    mapping(address => uint256) public firstSeen;
    mapping(address => uint256) public lastActive;
    mapping(address => uint256) public totalBids;
    mapping(address => uint256) public totalListings;
    mapping(address => uint256) public purchases;
    mapping(address => uint256) public disputesRaised;
    mapping(address => uint256) public disputesLost;
    mapping(address => uint256) public flagCount;
    mapping(address => uint256) public bidWindowStart;
    mapping(address => uint256) public bidWindowCount;
    mapping(address => bool)    public verified;
    mapping(address => bool)    public frozen;

    event ReputationChanged(address indexed wallet, uint256 oldRep, uint256 newRep);
    event FraudFlagged(address indexed wallet, uint256 listingId, string reason);
    event AutoFrozen(address indexed wallet, string reason);
    event WalletVerified(address indexed wallet);
    event ParamUpdated(string param, uint256 value);

    modifier onlyOwner()    { require(msg.sender == owner,                          "Not owner");    _; }
    modifier onlyPlatform() { require(msg.sender == platform || msg.sender == owner,"Not platform"); _; }
    modifier isActive()     { require(active,                                       "Inactive");     _; }

    constructor(address _platform) {
        owner    = msg.sender;
        platform = _platform;
    }

    // ── Profile ────────────────────────────────────────────
    function _init(address w) internal {
        if (firstSeen[w] == 0) {
            reputation[w] = INITIAL_REP;
            firstSeen[w]  = block.timestamp;
            lastActive[w] = block.timestamp;
        }
    }

    function _addRep(address w, uint256 delta) internal {
        uint256 old = reputation[w];
        reputation[w] = old + delta > MAX_REP ? MAX_REP : old + delta;
        emit ReputationChanged(w, old, reputation[w]);
    }

    function _subRep(address w, uint256 delta) internal {
        uint256 old = reputation[w];
        reputation[w] = delta > old ? 0 : old - delta;
        emit ReputationChanged(w, old, reputation[w]);
        if (reputation[w] <= FREEZE_THRESH && old > FREEZE_THRESH) {
            _freeze(w, "Reputation critically low");
        }
    }

    function _freeze(address w, string memory reason) internal {
        frozen[w] = true;
        totalFreezes++;
        emit AutoFrozen(w, reason);
    }

    // ── Platform Callbacks ─────────────────────────────────
    function onListingCreated(uint256, address inventor) external onlyPlatform isActive {
        _init(inventor);
        totalListings[inventor]++;
        lastActive[inventor] = block.timestamp;
        if (totalListings[inventor] > 25 && reputation[inventor] < 300) {
            emit FraudFlagged(inventor, 0, "Listing spam");
            _subRep(inventor, 20);
        }
    }

    function onBidCommitted(uint256 listingId, address bidder) external onlyPlatform isActive {
        _init(bidder);
        totalBids[bidder]++;
        lastActive[bidder] = block.timestamp;
        _checkVelocity(bidder, listingId);
    }

    function onAuctionSettled(uint256, address winner, uint256) external onlyPlatform isActive {
        _init(winner);
        purchases[winner]++;
        _addRep(winner, 50);
    }

    function onDisputeRaised(address wallet) external onlyPlatform {
        _init(wallet);
        disputesRaised[wallet]++;
        _subRep(wallet, 30);
    }

    function onDisputeResolved(address wallet, bool won) external onlyPlatform {
        _init(wallet);
        if (won) {
            _addRep(wallet, 25);
        } else {
            disputesLost[wallet]++;
            _subRep(wallet, 150);
        }
    }

    // ── Velocity Check ─────────────────────────────────────
    function _checkVelocity(address bidder, uint256 listingId) internal {
        if (block.timestamp - bidWindowStart[bidder] > 1 hours) {
            bidWindowStart[bidder] = block.timestamp;
            bidWindowCount[bidder] = 0;
        }
        bidWindowCount[bidder]++;
        if (bidWindowCount[bidder] > maxBidsPerHr) {
            emit FraudFlagged(bidder, listingId, "Bid velocity abuse");
            _subRep(bidder, 50);
            flagCount[bidder]++;
            totalFlags++;
        }
    }

    // ── Platform Interface ─────────────────────────────────
    function canBid(address wallet) external view returns (bool, string memory) {
        if (!active)          return (true,  "");
        if (frozen[wallet])   return (false, "Wallet frozen");
        if (firstSeen[wallet] == 0) return (true, "");
        if (reputation[wallet] < minRepToBid) return (false, "Reputation too low");
        return (true, "");
    }

    function canList(address wallet) external view returns (bool, string memory) {
        if (!active)          return (true,  "");
        if (frozen[wallet])   return (false, "Wallet frozen");
        if (firstSeen[wallet] == 0) return (true, "");
        if (reputation[wallet] < minRepToList) return (false, "Reputation too low");
        return (true, "");
    }

    // ── View ───────────────────────────────────────────────
    function getReputation(address wallet) external view returns (uint256) {
        return firstSeen[wallet] == 0 ? INITIAL_REP : reputation[wallet];
    }

    function getTier(address wallet) external view returns (string memory) {
        uint256 rep = reputation[wallet];
        if (rep >= 900) return "PLATINUM";
        if (rep >= 700) return "GOLD";
        if (rep >= 500) return "SILVER";
        if (rep >= 300) return "BRONZE";
        if (rep >= 100) return "PROBATION";
        return "SUSPENDED";
    }

    function getStats() external view returns (uint256, uint256, bool) {
        return (totalFlags, totalFreezes, active);
    }

    // ── Admin ──────────────────────────────────────────────
    function verifyWallet(address wallet) external onlyOwner {
        _init(wallet);
        verified[wallet] = true;
        _addRep(wallet, 150);
        emit WalletVerified(wallet);
    }

    function manualFreeze(address wallet) external onlyOwner {
        _init(wallet);
        _freeze(wallet, "Manual freeze by admin");
    }

    function manualUnfreeze(address wallet) external onlyOwner {
        frozen[wallet] = false;
    }

    function setMinRepToBid(uint256 val) external onlyOwner {
        minRepToBid = val;
        emit ParamUpdated("minRepToBid", val);
    }

    function setMinRepToList(uint256 val) external onlyOwner {
        minRepToList = val;
        emit ParamUpdated("minRepToList", val);
    }

    function setMaxBidsPerHr(uint256 val) external onlyOwner {
        maxBidsPerHr = val;
        emit ParamUpdated("maxBidsPerHr", val);
    }

    function setActive(bool val) external onlyOwner { active = val; }
    function updatePlatform(address p) external onlyOwner { platform = p; }
}
