// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGovernor {
    function onListingCreated(uint256 id, address inventor) external;
    function onBidCommitted(uint256 id, address bidder) external;
    function onAuctionSettled(uint256 id, address winner, uint256 amount) external;
    function onDisputeRaised(address wallet) external;
    function onDisputeResolved(address wallet, bool won) external;
    function canBid(address wallet) external view returns (bool, string memory);
    function canList(address wallet) external view returns (bool, string memory);
}

interface IValuation {
    function recordSale(string calldata category, uint256 price) external;
}

contract CryptValt {

    uint256 public constant INVENTOR_BPS     = 8000;
    uint256 public constant BPS              = 10000;
    uint256 public constant MAX_ROYALTY      = 1000;
    uint256 public constant MIN_FEE          = 1000;
    uint256 public constant MAX_FEE          = 3000;
    uint256 public constant MIN_DUR          = 1 days;
    uint256 public constant MAX_DUR          = 7 days;
    uint256 public constant REVEAL_WIN       = 24 hours;
    uint256 public constant KEY_WIN          = 48 hours;

    bytes32 public constant ROLE_OWNER    = keccak256("OWNER");
    bytes32 public constant ROLE_GOVERNOR = keccak256("GOVERNOR");
    bytes32 public constant ROLE_RESOLVER = keccak256("RESOLVER");
    bytes32 public constant ROLE_PAUSER   = keccak256("PAUSER");

    mapping(bytes32 => mapping(address => bool)) public roles;

    // Lean numeric struct - no strings
    struct Listing {
        address payable inventor;
        address  winner;
        uint128  reservePrice;
        uint128  winningBid;
        uint64   endTime;
        uint64   revealDeadline;
        uint64   keyDeadline;
        uint32   bidCount;
        uint16   royaltyBps;
        uint8    status;
        bool     keyDelivered;
        bool     fundsReleased;
        bool     disputed;
    }

    struct Bid {
        bytes32 commitment;
        uint256 revealedAmount;
        uint256 depositAmount;
        bool    revealed;
        bool    refunded;
        bool    isWinner;
    }

    struct SecondaryListing {
        address payable seller;
        uint256 price;
        bool    active;
    }

    // Strings stored separately to reduce struct size
    mapping(uint256 => string) public listingCID;
    mapping(uint256 => string) public listingKeyHash;
    mapping(uint256 => string) public listingCategory;
    mapping(uint256 => string) public listingEncryptedKey;

    address public owner;
    address public platformWallet;
    address public governorContract;
    address public valuationContract;
    uint256 public platformFeeBps;
    uint256 public listingCount;
    uint256 public totalVolumeWei;
    uint256 public totalListings;
    uint256 public totalBids;
    bool    public paused;
    bool    public emergencyMode;

    uint256 private _status = 1;

    mapping(uint256 => Listing)                 public listings;
    mapping(uint256 => mapping(address => Bid)) public bids;
    mapping(uint256 => address[])               public bidders;
    mapping(uint256 => SecondaryListing)        public secondaryListings;
    mapping(address => uint256[])               public inventorListings;
    mapping(address => uint256[])               public bidderHistory;
    mapping(address => uint256)                 public pendingWithdrawals;
    mapping(address => bool)                    public frozenWallets;

    event Listed(uint256 indexed id, address indexed inventor, uint256 reserve, uint256 endTime);
    event BidCommitted(uint256 indexed id, address indexed bidder, bytes32 commitment);
    event BidRevealed(uint256 indexed id, address indexed bidder, uint256 amount);
    event Settled(uint256 indexed id, address indexed winner, uint256 amount);
    event Cancelled(uint256 indexed id);
    event KeyDelivered(uint256 indexed id, address indexed winner);
    event FundsReleased(uint256 indexed id, uint256 inventorAmt, uint256 platAmt);
    event RoyaltyPaid(uint256 indexed id, address indexed inventor, uint256 amount);
    event DisputeRaised(uint256 indexed id);
    event DisputeResolved(uint256 indexed id, bool inventorFavored);
    event RefundQueued(address indexed wallet, uint256 amount);
    event Withdrawn(address indexed wallet, uint256 amount);
    event WalletFrozen(address indexed wallet);
    event WalletUnfrozen(address indexed wallet);

    modifier role(bytes32 r)  { require(roles[r][msg.sender], "Denied"); _; }
    modifier lock()           { require(_status == 1, "Reentrant"); _status = 2; _; _status = 1; }
    modifier live()           { require(!paused, "Paused"); _; }
    modifier notFrozen()      { require(!frozenWallets[msg.sender], "Frozen"); _; }
    modifier has(uint256 id)  { require(id > 0 && id <= listingCount, "Not found"); _; }

    constructor(address _wallet, uint256 _fee) {
        require(_wallet != address(0));
        require(_fee >= MIN_FEE && _fee <= MAX_FEE);
        owner          = msg.sender;
        platformWallet = _wallet;
        platformFeeBps = _fee;
        roles[ROLE_OWNER][msg.sender]    = true;
        roles[ROLE_GOVERNOR][msg.sender] = true;
        roles[ROLE_RESOLVER][msg.sender] = true;
        roles[ROLE_PAUSER][msg.sender]   = true;
    }

    function grantRole(bytes32 r, address a) external role(ROLE_OWNER) { roles[r][a] = true; }
    function revokeRole(bytes32 r, address a) external role(ROLE_OWNER) { roles[r][a] = false; }

    function listIdea(
        string calldata cid,
        string calldata keyHash,
        string calldata category,
        uint256 reserve,
        uint256 duration,
        uint256 royaltyBps
    ) external live notFrozen returns (uint256) {
        require(bytes(cid).length >= 10,    "Bad CID");
        require(bytes(keyHash).length >= 32,"Bad key hash");
        require(bytes(category).length > 0, "No category");
        require(reserve > 0,                "No reserve");
        require(duration >= MIN_DUR && duration <= MAX_DUR, "Bad duration");
        require(royaltyBps <= MAX_ROYALTY,  "High royalty");

        if (governorContract != address(0)) {
            (bool ok, string memory reason) = IGovernor(governorContract).canList(msg.sender);
            require(ok, reason);
        }

        listingCount++;
        uint256 id = listingCount;
        uint64  end = uint64(block.timestamp + duration);

        listings[id].inventor      = payable(msg.sender);
        listings[id].reservePrice  = uint128(reserve);
        listings[id].endTime       = end;
        listings[id].revealDeadline = uint64(end + REVEAL_WIN);
        listings[id].keyDeadline   = uint64(end + REVEAL_WIN + KEY_WIN);
        listings[id].royaltyBps    = uint16(royaltyBps);

        listingCID[id]      = cid;
        listingKeyHash[id]  = keyHash;
        listingCategory[id] = category;

        inventorListings[msg.sender].push(id);
        totalListings++;

        if (governorContract != address(0)) IGovernor(governorContract).onListingCreated(id, msg.sender);
        emit Listed(id, msg.sender, reserve, end);
        return id;
    }

    function commitBid(uint256 id, bytes32 commitment) external payable live notFrozen has(id) lock {
        Listing storage l = listings[id];
        require(l.status == 0,               "Not active");
        require(block.timestamp < l.endTime, "Ended");
        require(msg.sender != l.inventor,    "Inventor");
        require(l.bidCount < 1000,           "Full");
        require(msg.value >= l.reservePrice, "Low bid");
        require(bids[id][msg.sender].commitment == 0, "Bid exists");

        if (governorContract != address(0)) {
            (bool ok, string memory reason) = IGovernor(governorContract).canBid(msg.sender);
            require(ok, reason);
        }

        bids[id][msg.sender] = Bid(commitment, 0, msg.value, false, false, false);
        bidders[id].push(msg.sender);
        l.bidCount++;
        totalBids++;
        bidderHistory[msg.sender].push(id);

        if (governorContract != address(0)) IGovernor(governorContract).onBidCommitted(id, msg.sender);
        emit BidCommitted(id, msg.sender, commitment);
    }

    function revealBid(uint256 id, uint256 amount, bytes32 salt) external live has(id) {
        Listing storage l = listings[id];
        require(block.timestamp >= l.endTime && block.timestamp <= l.revealDeadline, "Wrong window");
        Bid storage b = bids[id][msg.sender];
        require(b.commitment != 0 && !b.revealed, "Invalid");
        require(amount >= l.reservePrice, "Low amount");
        require(keccak256(abi.encodePacked(amount, salt, msg.sender, id)) == b.commitment, "Bad reveal");
        b.revealed       = true;
        b.revealedAmount = amount;
        if (l.status == 0) l.status = 1;
        if (amount > l.winningBid) l.winningBid = uint128(amount);
        emit BidRevealed(id, msg.sender, amount);
    }

    function settleAuction(uint256 id) external has(id) lock {
        Listing storage l = listings[id];
        require(l.status <= 1, "Cannot settle");
        require(block.timestamp > l.revealDeadline, "Reveal open");

        address winner = _findWinner(id);
        uint256 winBid = winner != address(0) ? bids[id][winner].revealedAmount : 0;

        if (winner == address(0) || winBid < l.reservePrice) {
            l.status = 6;
            _refundAll(id);
            emit Cancelled(id);
            return;
        }

        l.winner   = winner;
        l.winningBid = uint128(winBid);
        l.status   = 2;
        bids[id][winner].isWinner = true;
        _refundLosers(id, winner);
        totalVolumeWei += winBid;

        if (governorContract != address(0)) IGovernor(governorContract).onAuctionSettled(id, winner, winBid);
        emit Settled(id, winner, winBid);
    }

    function _findWinner(uint256 id) internal view returns (address w) {
        address[] storage list = bidders[id];
        uint256 top;
        for (uint256 i = 0; i < list.length; i++) {
            Bid storage b = bids[id][list[i]];
            if (b.revealed && b.revealedAmount > top) {
                top = b.revealedAmount;
                w   = list[i];
            }
        }
    }

    function deliverKey(uint256 id, string calldata encKey) external live has(id) lock {
        Listing storage l = listings[id];
        require(msg.sender == l.inventor,    "Not inventor");
        require(l.status == 2,               "Not awaiting");
        require(bytes(encKey).length > 0,    "Empty key");
        require(!l.keyDelivered,             "Delivered");
        require(block.timestamp <= l.keyDeadline, "Late");

        listingEncryptedKey[id] = encKey;
        l.keyDelivered = true;
        l.status       = 3;
        emit KeyDelivered(id, l.winner);
        _releaseFunds(id);
    }

    function _releaseFunds(uint256 id) internal {
        Listing storage l = listings[id];
        require(!l.fundsReleased && !l.disputed);
        uint256 total   = l.winningBid;
        uint256 inv     = (total * INVENTOR_BPS) / BPS;
        uint256 plat    = total - inv;
        l.fundsReleased = true;
        l.status        = 4;
        if (valuationContract != address(0)) IValuation(valuationContract).recordSale(listingCategory[id], total);
        (bool a,) = l.inventor.call{value: inv}(""); require(a);
        (bool b,) = payable(platformWallet).call{value: plat}(""); require(b);
        emit FundsReleased(id, inv, plat);
    }

    function claimRefund(uint256 id) external has(id) lock {
        Listing storage l = listings[id];
        require(msg.sender == l.winner && l.status == 2);
        require(block.timestamp > l.keyDeadline);
        l.status = 6;
        pendingWithdrawals[msg.sender] += l.winningBid;
        emit RefundQueued(msg.sender, l.winningBid);
    }

    function listSecondary(uint256 id, uint256 price) external has(id) {
        Listing storage l = listings[id];
        require(l.status == 4 && msg.sender == l.winner && price > 0);
        secondaryListings[id] = SecondaryListing(payable(msg.sender), price, true);
    }

    function buySecondary(uint256 id) external payable has(id) lock {
        SecondaryListing storage sl = secondaryListings[id];
        require(sl.active && msg.value >= sl.price);
        Listing storage l = listings[id];
        uint256 roy  = (msg.value * l.royaltyBps) / BPS;
        uint256 plat = (msg.value * platformFeeBps) / BPS;
        uint256 sell = msg.value - roy - plat;
        sl.active = false;
        l.winner  = msg.sender;
        totalVolumeWei += msg.value;
        if (roy > 0) { (bool a,) = l.inventor.call{value: roy}(""); require(a); emit RoyaltyPaid(id, l.inventor, roy); }
        (bool b,) = sl.seller.call{value: sell}(""); require(b);
        (bool c,) = payable(platformWallet).call{value: plat}(""); require(c);
        if (valuationContract != address(0)) IValuation(valuationContract).recordSale(listingCategory[id], msg.value);
    }

    function raiseDispute(uint256 id) external has(id) {
        Listing storage l = listings[id];
        require(msg.sender == l.winner || msg.sender == l.inventor);
        require(l.status == 2 || l.status == 3);
        require(!l.disputed);
        l.disputed = true;
        l.status   = 5;
        if (governorContract != address(0)) IGovernor(governorContract).onDisputeRaised(msg.sender);
        emit DisputeRaised(id);
    }

    function resolveDispute(uint256 id, bool inv) external role(ROLE_RESOLVER) has(id) lock {
        Listing storage l = listings[id];
        require(l.status == 5);
        if (inv) { l.keyDelivered = true; l.disputed = false; _releaseFunds(id); }
        else { l.status = 6; pendingWithdrawals[l.winner] += l.winningBid; emit RefundQueued(l.winner, l.winningBid); }
        if (governorContract != address(0)) { IGovernor(governorContract).onDisputeResolved(l.inventor, inv); IGovernor(governorContract).onDisputeResolved(l.winner, !inv); }
        emit DisputeResolved(id, inv);
    }

    function withdraw() external lock {
        uint256 amt = pendingWithdrawals[msg.sender];
        require(amt > 0);
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amt}(""); require(ok);
        emit Withdrawn(msg.sender, amt);
    }

    function _refundAll(uint256 id) internal {
        address[] storage list = bidders[id];
        for (uint256 i = 0; i < list.length; i++) {
            Bid storage b = bids[id][list[i]];
            if (!b.refunded) { b.refunded = true; pendingWithdrawals[list[i]] += b.depositAmount; emit RefundQueued(list[i], b.depositAmount); }
        }
    }

    function _refundLosers(uint256 id, address winner) internal {
        address[] storage list = bidders[id];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == winner) continue;
            Bid storage b = bids[id][list[i]];
            if (!b.refunded) { b.refunded = true; pendingWithdrawals[list[i]] += b.depositAmount; emit RefundQueued(list[i], b.depositAmount); }
        }
    }

    function freezeWallet(address w, string calldata) external role(ROLE_GOVERNOR) { frozenWallets[w] = true; emit WalletFrozen(w); }
    function unfreezeWallet(address w) external role(ROLE_GOVERNOR) { frozenWallets[w] = false; emit WalletUnfrozen(w); }
    function freezeListing(uint256 id) external role(ROLE_GOVERNOR) has(id) { listings[id].status = 7; }
    function unfreezeListing(uint256 id) external role(ROLE_GOVERNOR) has(id) { listings[id].status = 0; }
    function pause() external role(ROLE_PAUSER) { paused = true; }
    function unpause() external role(ROLE_OWNER) { paused = false; }
    function activateEmergency() external role(ROLE_OWNER) { emergencyMode = true; paused = true; }
    function deactivateEmergency() external role(ROLE_OWNER) { emergencyMode = false; paused = false; }

    function getListing(uint256 id) external view returns (Listing memory) { return listings[id]; }
    function getListingStrings(uint256 id) external view returns (string memory, string memory, string memory) { return (listingCID[id], listingKeyHash[id], listingCategory[id]); }
    function getBidders(uint256 id) external view returns (address[] memory) { return bidders[id]; }
    function getBid(uint256 id, address bidder) external view returns (Bid memory) { return bids[id][bidder]; }
    function getWinnerKey(uint256 id) external view returns (string memory) { require(msg.sender == listings[id].winner && listings[id].keyDelivered); return listingEncryptedKey[id]; }
    function getInventorListings(address a) external view returns (uint256[] memory) { return inventorListings[a]; }
    function getBidderHistory(address a) external view returns (uint256[] memory) { return bidderHistory[a]; }
    function getPlatformStats() external view returns (uint256, uint256, uint256, bool) { return (totalListings, totalVolumeWei, totalBids, paused); }

    function setGovernorContract(address g) external role(ROLE_OWNER) { governorContract = g; }
    function setValuationContract(address v) external role(ROLE_OWNER) { valuationContract = v; }
    function updatePlatformWallet(address w) external role(ROLE_OWNER) { require(w != address(0)); platformWallet = w; }
    function updatePlatformFee(uint256 f) external role(ROLE_OWNER) { require(f >= MIN_FEE && f <= MAX_FEE); platformFeeBps = f; }
    function emergencyDrain(address to) external role(ROLE_OWNER) { require(emergencyMode && to != address(0)); (bool ok,) = payable(to).call{value: address(this).balance}(""); require(ok); }

    receive() external payable {}
}
