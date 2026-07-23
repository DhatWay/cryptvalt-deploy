// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                                CRYPTVALT v2.0
            Sealed-Bid Idea Auction Escrow — OpenZeppelin Edition
//////////////////////////////////////////////////////////////////////////*/

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title CryptValt — Sealed-Bid Idea Auction Escrow
/// @author CryptValt
/// @notice Inventors list encrypted ideas, bidders place sealed
///         (commit-reveal) bids, funds are escrowed and released 80/20
///         (inventor/platform) upon decryption-key delivery.
/// @dev v2.0 hardened release, built on OpenZeppelin audited bases:
///      - AccessControlDefaultAdminRules: role system with two-step,
///        time-delayed admin (Safe) transfer — cannot be bricked
///      - ReentrancyGuard: audited nonReentrant modifier
///      - Pausable: audited emergency-stop pattern
///      Security fixes over v1:
///      - Deposit-backed bids: revealed bid must be fully collateralized
///      - O(1) settlement: winner tracked incrementally at reveal time
///      - Pull-payment pattern for ALL payouts (no push transfers)
///      - Timelocked fee & platform-wallet changes
///      - Custom errors, full event coverage, on-chain solvency invariant
///      v2.1 additions:
///      - reauction(): relist a dead auction as a NEW listing that
///        inherits the payload, preserving old bid/refund records
///      - archiveListing(): hide settled listings (status 8) with a
///        guard that blocks archiving while funds are still owed

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

contract CryptValt is AccessControlDefaultAdminRules, ReentrancyGuard, Pausable {

    /*////////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////////*/

    uint256 public constant BPS             = 10_000;
    uint256 public constant MAX_ROYALTY     = 1_000;  // 10%
    uint256 public constant MIN_FEE         = 1_000;  // 10%
    uint256 public constant MAX_FEE         = 3_000;  // 30%
    uint256 public constant MIN_DUR         = 1 days;
    uint256 public constant MAX_DUR         = 7 days;
    uint256 public constant REVEAL_WIN      = 24 hours;
    uint256 public constant KEY_WIN         = 48 hours;
    uint256 public constant MAX_BIDDERS     = 500;
    uint256 public constant ADMIN_TIMELOCK  = 24 hours;
    uint256 public constant EMERGENCY_DELAY = 48 hours;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error Denied();
    error ZeroAddress();
    error BadFee();
    error BadCID();
    error BadKeyHash();
    error NoCategory();
    error NoReserve();
    error BadDuration();
    error HighRoyalty();
    error NotFound();
    error NotActive();
    error AuctionEnded();
    error InventorCannotBid();
    error AuctionFull();
    error DepositBelowReserve();
    error BidExists();
    error WalletIsFrozen();
    error WrongWindow();
    error InvalidBid();
    error AmountBelowReserve();
    error BadReveal();
    error DepositTooLow();
    error CannotSettle();
    error RevealStillOpen();
    error NotInventor();
    error NotAwaitingKey();
    error EmptyKey();
    error PastDeadline();
    error NotWinner();
    error DeadlineNotPassed();
    error NotSettledOwner();
    error BadPrice();
    error NotForSale();
    error PaymentTooLow();
    error NotParty();
    error WrongStatus();
    error AlreadyDisputed();
    error NothingToWithdraw();
    error TransferFailed();
    error NothingToClaim();
    error NotQueued();
    error TimelockActive();
    error NotInEmergency();
    error NotFrozenListing();
    error NotReauctionable();
    error AlreadyArchived();
    error FundsStillOwed();
    error CannotArchiveActive();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    /// @dev status: 0=Active 1=Revealing 2=AwaitingKey 3=KeyDelivered
    ///              4=Complete 5=Disputed 6=Cancelled/Refunded 7=Frozen
    ///              8=Archived (settled, hidden from active views)
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

    struct PendingAdminChange {
        uint256 newValue;
        address newAddress;
        uint256 executableAt;
    }

    address public platformWallet;
    address public governorContract;
    address public valuationContract;
    uint256 public platformFeeBps;
    uint256 public listingCount;
    uint256 public totalVolumeWei;
    uint256 public totalListings;
    uint256 public totalBids;
    bool    public emergencyMode;
    uint256 public emergencyDrainQueuedAt;

    /// @notice Sum of all ETH the contract is obligated to pay out
    ///         (active bid deposits + queued withdrawals).
    uint256 public totalEscrowed;

    PendingAdminChange public pendingFeeChange;
    PendingAdminChange public pendingWalletChange;

    mapping(uint256 => Listing)                 public listings;
    mapping(uint256 => string)                  public listingCID;
    mapping(uint256 => string)                  public listingKeyHash;
    mapping(uint256 => string)                  public listingCategory;
    mapping(uint256 => string)                  private _listingEncryptedKey;
    mapping(uint256 => mapping(address => Bid)) public bids;
    mapping(uint256 => address[])               public bidders;
    mapping(uint256 => SecondaryListing)        public secondaryListings;
    mapping(address => uint256[])               public inventorListings;
    mapping(address => uint256[])               public bidderHistory;
    mapping(address => uint256)                 public pendingWithdrawals;
    mapping(address => bool)                    public frozenWallets;

    /// @notice For a relisted idea: the listing it was reauctioned from.
    mapping(uint256 => uint256) public reauctionedFrom;
    /// @notice For an original listing: its most recent relisting.
    mapping(uint256 => uint256) public reauctionedTo;
    /// @notice How many times an idea has been put back to auction.
    mapping(uint256 => uint32)  public reauctionCount;

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event Listed(uint256 indexed id, address indexed inventor, uint256 reserve, uint256 endTime);
    event BidCommitted(uint256 indexed id, address indexed bidder, bytes32 commitment);
    event BidRevealed(uint256 indexed id, address indexed bidder, uint256 amount);
    event Settled(uint256 indexed id, address indexed winner, uint256 amount);
    event Cancelled(uint256 indexed id);
    event KeyDelivered(uint256 indexed id, address indexed winner);
    event FundsReleased(uint256 indexed id, uint256 inventorAmt, uint256 platformAmt);
    event RoyaltyPaid(uint256 indexed id, address indexed inventor, uint256 amount);
    event SecondaryListed(uint256 indexed id, address indexed seller, uint256 price);
    event SecondarySold(uint256 indexed id, address indexed buyer, uint256 price);
    event DisputeRaised(uint256 indexed id, address indexed by);
    event DisputeResolved(uint256 indexed id, bool inventorFavored);
    event RefundQueued(address indexed wallet, uint256 amount);
    event BidRefundClaimed(uint256 indexed id, address indexed bidder, uint256 amount);
    event Withdrawn(address indexed wallet, uint256 amount);
    event WalletFrozen(address indexed wallet, string reason);
    event WalletUnfrozen(address indexed wallet);
    event ListingFrozen(uint256 indexed id);
    event ListingUnfrozen(uint256 indexed id);
    event Reauctioned(uint256 indexed oldId, uint256 indexed newId, address indexed inventor, uint256 reserve, uint256 endTime);
    event Archived(uint256 indexed id, address indexed by);
    event EmergencyActivated(address indexed by);
    event EmergencyDeactivated(address indexed by);
    event EmergencyDrainQueued(uint256 executableAt);
    event EmergencyDrainCancelled();
    event EmergencyDrained(address indexed to, uint256 amount);
    event FeeChangeQueued(uint256 newFee, uint256 executableAt);
    event FeeChanged(uint256 oldFee, uint256 newFee);
    event WalletChangeQueued(address indexed newWallet, uint256 executableAt);
    event PlatformWalletChanged(address indexed oldWallet, address indexed newWallet);
    event GovernorContractSet(address indexed governor);
    event ValuationContractSet(address indexed valuation);

    /*////////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    modifier notFrozen() {
        if (frozenWallets[msg.sender]) revert WalletIsFrozen();
        _;
    }

    modifier exists(uint256 id) {
        if (id == 0 || id > listingCount) revert NotFound();
        _;
    }

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param admin    Initial admin — set this to the 2-of-2 Safe address
    ///                 at deployment so the multisig controls everything
    ///                 from block one.
    /// @param _wallet  Platform fee recipient (also the Safe, typically)
    /// @param _fee     Platform fee in basis points (1000–3000)
    /// @dev AccessControlDefaultAdminRules enforces a 24h delay + two-step
    ///      acceptance on any future admin (Safe) handover — the audited
    ///      OpenZeppelin equivalent of Ownable2Step for role systems.
    constructor(address admin, address _wallet, uint256 _fee)
        AccessControlDefaultAdminRules(uint48(ADMIN_TIMELOCK), admin)
    {
        if (_wallet == address(0)) revert ZeroAddress();
        if (_fee < MIN_FEE || _fee > MAX_FEE) revert BadFee();
        platformWallet = _wallet;
        platformFeeBps = _fee;
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(RESOLVER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /*////////////////////////////////////////////////////////////////
                                 LISTING
    ////////////////////////////////////////////////////////////////*/

    /// @notice List an encrypted idea for sealed-bid auction.
    /// @param cid        IPFS CID of the encrypted idea payload
    /// @param keyHash    Hash of the decryption key (integrity check)
    /// @param category   Idea category (used by valuation oracle)
    /// @param reserve    Minimum acceptable bid in wei
    /// @param duration   Auction length (1–7 days)
    /// @param royaltyBps Secondary-sale royalty to inventor (max 10%)
    /// @return id        The new listing's id
    function listIdea(
        string calldata cid,
        string calldata keyHash,
        string calldata category,
        uint256 reserve,
        uint256 duration,
        uint256 royaltyBps
    ) external whenNotPaused notFrozen returns (uint256 id) {
        if (bytes(cid).length < 10)      revert BadCID();
        if (bytes(keyHash).length < 32)  revert BadKeyHash();
        if (bytes(category).length == 0) revert NoCategory();
        if (reserve == 0)                revert NoReserve();
        if (duration < MIN_DUR || duration > MAX_DUR) revert BadDuration();
        if (royaltyBps > MAX_ROYALTY)    revert HighRoyalty();

        if (governorContract != address(0)) {
            (bool ok, string memory reason) = IGovernor(governorContract).canList(msg.sender);
            require(ok, reason);
        }

        id = ++listingCount;
        uint64 end = uint64(block.timestamp + duration);

        Listing storage l = listings[id];
        l.inventor       = payable(msg.sender);
        l.reservePrice   = uint128(reserve);
        l.endTime        = end;
        l.revealDeadline = end + uint64(REVEAL_WIN);
        l.keyDeadline    = end + uint64(REVEAL_WIN + KEY_WIN);
        l.royaltyBps     = uint16(royaltyBps);

        listingCID[id]      = cid;
        listingKeyHash[id]  = keyHash;
        listingCategory[id] = category;

        inventorListings[msg.sender].push(id);
        totalListings++;

        if (governorContract != address(0)) {
            IGovernor(governorContract).onListingCreated(id, msg.sender);
        }
        emit Listed(id, msg.sender, reserve, end);
    }

    /*////////////////////////////////////////////////////////////////
                                 BIDDING
    ////////////////////////////////////////////////////////////////*/

    /// @notice Commit a sealed bid backed by a deposit. Deposit must be
    ///         >= your actual bid (over-deposit to obscure it; surplus
    ///         is refunded after settlement).
    /// @dev commitment = keccak256(abi.encodePacked(amount, salt, msg.sender, id))
    function commitBid(uint256 id, bytes32 commitment)
        external payable whenNotPaused notFrozen exists(id) nonReentrant
    {
        Listing storage l = listings[id];
        if (l.status != 0)                 revert NotActive();
        if (block.timestamp >= l.endTime)  revert AuctionEnded();
        if (msg.sender == l.inventor)      revert InventorCannotBid();
        if (l.bidCount >= MAX_BIDDERS)     revert AuctionFull();
        if (msg.value < l.reservePrice)    revert DepositBelowReserve();
        if (bids[id][msg.sender].commitment != bytes32(0)) revert BidExists();

        if (governorContract != address(0)) {
            (bool ok, string memory reason) = IGovernor(governorContract).canBid(msg.sender);
            require(ok, reason);
        }

        bids[id][msg.sender] = Bid({
            commitment:     commitment,
            revealedAmount: 0,
            depositAmount:  msg.value,
            revealed:       false,
            refunded:       false,
            isWinner:       false
        });
        bidders[id].push(msg.sender);
        l.bidCount++;
        totalBids++;
        totalEscrowed += msg.value;
        bidderHistory[msg.sender].push(id);

        if (governorContract != address(0)) {
            IGovernor(governorContract).onBidCommitted(id, msg.sender);
        }
        emit BidCommitted(id, msg.sender, commitment);
    }

    /// @notice Reveal a committed bid during the reveal window.
    /// @dev SECURITY FIX (v2.0): revealed amount must be fully covered
    ///      by the deposit, so the contract always holds the winning bid
    ///      in full. Winner is tracked incrementally here, making
    ///      settlement O(1) and immune to bidder-count gas limits.
    function revealBid(uint256 id, uint256 amount, bytes32 salt)
        external whenNotPaused exists(id)
    {
        Listing storage l = listings[id];
        if (block.timestamp < l.endTime || block.timestamp > l.revealDeadline) revert WrongWindow();
        Bid storage b = bids[id][msg.sender];
        if (b.commitment == bytes32(0) || b.revealed) revert InvalidBid();
        if (amount < l.reservePrice) revert AmountBelowReserve();
        if (keccak256(abi.encodePacked(amount, salt, msg.sender, id)) != b.commitment) revert BadReveal();
        if (b.depositAmount < amount) revert DepositTooLow();

        b.revealed       = true;
        b.revealedAmount = amount;
        if (l.status == 0) l.status = 1;

        // Incremental winner tracking — no settlement loop needed.
        if (amount > l.winningBid) {
            l.winningBid = uint128(amount);
            l.winner     = msg.sender;
        }
        emit BidRevealed(id, msg.sender, amount);
    }

    /// @notice Finalize the auction after the reveal window closes.
    /// @dev O(1): winner was tracked at reveal time. Losers and
    ///      non-revealers claim deposits via claimBidRefund().
    function settleAuction(uint256 id) external exists(id) nonReentrant {
        Listing storage l = listings[id];
        if (l.status > 1)                        revert CannotSettle();
        if (block.timestamp <= l.revealDeadline) revert RevealStillOpen();

        address winner = l.winner;
        uint256 winBid = l.winningBid;

        if (winner == address(0) || winBid < l.reservePrice) {
            l.status = 6;
            emit Cancelled(id);
            return; // all bidders reclaim via claimBidRefund()
        }

        l.status = 2;
        Bid storage wb = bids[id][winner];
        wb.isWinner = true;

        // Refund the winner's surplus deposit (deposit − bid).
        uint256 surplus = wb.depositAmount - winBid;
        if (surplus > 0) {
            wb.depositAmount = winBid;
            pendingWithdrawals[winner] += surplus;
            emit RefundQueued(winner, surplus);
        }

        totalVolumeWei += winBid;

        if (governorContract != address(0)) {
            IGovernor(governorContract).onAuctionSettled(id, winner, winBid);
        }
        emit Settled(id, winner, winBid);
    }

    /// @notice Claim back your bid deposit after settlement or
    ///         cancellation (losing bidders and non-revealers).
    /// @dev Pull-pattern replacement for v1's refund loops — removes the
    ///      unbounded-gas settlement risk entirely.
    function claimBidRefund(uint256 id) external exists(id) nonReentrant {
        Listing storage l = listings[id];
        if (l.status < 2) revert CannotSettle();
        Bid storage b = bids[id][msg.sender];
        if (b.commitment == bytes32(0) || b.refunded || b.isWinner) revert NothingToClaim();

        b.refunded = true;
        uint256 amt = b.depositAmount;
        pendingWithdrawals[msg.sender] += amt;
        emit BidRefundClaimed(id, msg.sender, amt);
    }

    /*////////////////////////////////////////////////////////////////
                          KEY DELIVERY & FUNDS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Inventor delivers the encrypted decryption key to the
    ///         winner, releasing escrowed funds (80/20 split).
    function deliverKey(uint256 id, string calldata encKey)
        external whenNotPaused exists(id) nonReentrant
    {
        Listing storage l = listings[id];
        if (msg.sender != l.inventor)        revert NotInventor();
        if (l.status != 2)                   revert NotAwaitingKey();
        if (bytes(encKey).length == 0)       revert EmptyKey();
        if (block.timestamp > l.keyDeadline) revert PastDeadline();

        _listingEncryptedKey[id] = encKey;
        l.keyDelivered = true;
        l.status       = 3;
        emit KeyDelivered(id, l.winner);
        _releaseFunds(id);
    }

    /// @dev Pull-pattern release: amounts are queued to
    ///      pendingWithdrawals, so a reverting recipient can never
    ///      block settlement.
    function _releaseFunds(uint256 id) internal {
        Listing storage l = listings[id];
        if (l.fundsReleased || l.disputed) return;
        uint256 total = l.winningBid;
        uint256 plat  = (total * platformFeeBps) / BPS;
        uint256 inv   = total - plat;
        l.fundsReleased = true;
        l.status        = 4;

        // Winning-deposit obligation converts into withdrawal
        // obligations (−total +inv +plat = 0) → totalEscrowed unchanged.
        pendingWithdrawals[l.inventor]     += inv;
        pendingWithdrawals[platformWallet] += plat;

        if (valuationContract != address(0)) {
            try IValuation(valuationContract).recordSale(listingCategory[id], total) {} catch {}
        }
        emit FundsReleased(id, inv, plat);
    }

    /// @notice Winner reclaims escrow if the inventor missed the key
    ///         deadline.
    function claimRefund(uint256 id) external exists(id) nonReentrant {
        Listing storage l = listings[id];
        if (msg.sender != l.winner || l.status != 2) revert NotWinner();
        if (block.timestamp <= l.keyDeadline)        revert DeadlineNotPassed();
        l.status = 6;
        pendingWithdrawals[msg.sender] += l.winningBid;
        emit RefundQueued(msg.sender, l.winningBid);
    }

    /// @notice Withdraw everything owed to you (refunds, proceeds,
    ///         platform fees, royalties).
    function withdraw() external nonReentrant {
        uint256 amt = pendingWithdrawals[msg.sender];
        if (amt == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        totalEscrowed -= amt;
        (bool ok,) = payable(msg.sender).call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amt);
    }

    /*////////////////////////////////////////////////////////////////
                            SECONDARY MARKET
    ////////////////////////////////////////////////////////////////*/

    /// @notice Winner of a completed auction lists the idea for resale.
    function listSecondary(uint256 id, uint256 price) external exists(id) {
        Listing storage l = listings[id];
        if (l.status != 4 || msg.sender != l.winner) revert NotSettledOwner();
        if (price == 0) revert BadPrice();
        secondaryListings[id] = SecondaryListing(payable(msg.sender), price, true);
        emit SecondaryListed(id, msg.sender, price);
    }

    /// @notice Buy a secondary-market listing. Royalty and platform fee
    ///         are deducted; all payouts are pull-pattern.
    function buySecondary(uint256 id)
        external payable whenNotPaused notFrozen exists(id) nonReentrant
    {
        SecondaryListing storage sl = secondaryListings[id];
        if (!sl.active)           revert NotForSale();
        if (msg.value < sl.price) revert PaymentTooLow();
        Listing storage l = listings[id];

        uint256 roy  = (msg.value * l.royaltyBps) / BPS;
        uint256 plat = (msg.value * platformFeeBps) / BPS;
        uint256 sell = msg.value - roy - plat;

        sl.active = false;
        l.winner  = msg.sender;
        totalVolumeWei += msg.value;
        totalEscrowed  += msg.value;

        if (roy > 0) {
            pendingWithdrawals[l.inventor] += roy;
            emit RoyaltyPaid(id, l.inventor, roy);
        }
        pendingWithdrawals[sl.seller]      += sell;
        pendingWithdrawals[platformWallet] += plat;

        if (valuationContract != address(0)) {
            try IValuation(valuationContract).recordSale(listingCategory[id], msg.value) {} catch {}
        }
        emit SecondarySold(id, msg.sender, msg.value);
    }

    /*////////////////////////////////////////////////////////////////
                                DISPUTES
    ////////////////////////////////////////////////////////////////*/

    function raiseDispute(uint256 id) external exists(id) {
        Listing storage l = listings[id];
        if (msg.sender != l.winner && msg.sender != l.inventor) revert NotParty();
        if (l.status != 2 && l.status != 3) revert WrongStatus();
        if (l.disputed) revert AlreadyDisputed();
        l.disputed = true;
        l.status   = 5;
        if (governorContract != address(0)) {
            IGovernor(governorContract).onDisputeRaised(msg.sender);
        }
        emit DisputeRaised(id, msg.sender);
    }

    function resolveDispute(uint256 id, bool inventorFavored)
        external onlyRole(RESOLVER_ROLE) exists(id) nonReentrant
    {
        Listing storage l = listings[id];
        if (l.status != 5) revert WrongStatus();
        if (inventorFavored) {
            l.keyDelivered = true;
            l.disputed = false;
            _releaseFunds(id);
        } else {
            l.status = 6;
            pendingWithdrawals[l.winner] += l.winningBid;
            emit RefundQueued(l.winner, l.winningBid);
        }
        if (governorContract != address(0)) {
            IGovernor(governorContract).onDisputeResolved(l.inventor, inventorFavored);
            IGovernor(governorContract).onDisputeResolved(l.winner, !inventorFavored);
        }
        emit DisputeResolved(id, inventorFavored);
    }

    /*////////////////////////////////////////////////////////////////
                           GOVERNANCE / ADMIN
    ////////////////////////////////////////////////////////////////*/

    function freezeWallet(address w, string calldata reason) external onlyRole(GOVERNOR_ROLE) {
        if (w == address(0)) revert ZeroAddress();
        frozenWallets[w] = true;
        emit WalletFrozen(w, reason);
    }

    function unfreezeWallet(address w) external onlyRole(GOVERNOR_ROLE) {
        frozenWallets[w] = false;
        emit WalletUnfrozen(w);
    }

    function freezeListing(uint256 id) external onlyRole(GOVERNOR_ROLE) exists(id) {
        listings[id].status = 7;
        emit ListingFrozen(id);
    }

    function unfreezeListing(uint256 id) external onlyRole(GOVERNOR_ROLE) exists(id) {
        if (listings[id].status != 7) revert NotFrozenListing();
        listings[id].status = 0;
        emit ListingUnfrozen(id);
    }

    /*////////////////////////////////////////////////////////////////
                        REAUCTION  &  ARCHIVE
    ////////////////////////////////////////////////////////////////*/

    /// @notice Put a finished-but-unsold idea back up for auction.
    /// @dev Admin-triggered (inventors submit requests off-chain, an
    ///      admin approves and calls this). Creates a NEW listing that
    ///      inherits the original's CID, key hash, category and
    ///      inventor, rather than resetting the old one — the old
    ///      auction's bid records stay intact so past bidders can
    ///      always still claim refunds.
    /// @param oldId       Listing being relisted. Must be Cancelled (6)
    ///                    or Archived (8) — never an in-flight or
    ///                    successfully completed auction.
    /// @param reserve     New reserve price in wei.
    /// @param duration    New auction length (1–7 days).
    /// @param royaltyBps  New secondary royalty (max 10%).
    /// @return newId      The newly created listing id.
    function reauction(
        uint256 oldId,
        uint256 reserve,
        uint256 duration,
        uint256 royaltyBps
    ) external onlyRole(GOVERNOR_ROLE) whenNotPaused exists(oldId) returns (uint256 newId) {
        Listing storage o = listings[oldId];

        // Only dead auctions may be relisted: cancelled/refunded (6) or
        // archived (8). A completed sale (4) belongs to its buyer.
        if (o.status != 6 && o.status != 8) revert NotReauctionable();
        if (reserve == 0)                   revert NoReserve();
        if (duration < MIN_DUR || duration > MAX_DUR) revert BadDuration();
        if (royaltyBps > MAX_ROYALTY)       revert HighRoyalty();
        if (frozenWallets[o.inventor])      revert WalletIsFrozen();

        newId = ++listingCount;
        uint64 end = uint64(block.timestamp + duration);

        Listing storage n = listings[newId];
        n.inventor       = o.inventor;
        n.reservePrice   = uint128(reserve);
        n.endTime        = end;
        n.revealDeadline = end + uint64(REVEAL_WIN);
        n.keyDeadline    = end + uint64(REVEAL_WIN + KEY_WIN);
        n.royaltyBps     = uint16(royaltyBps);

        // Carry the encrypted payload references across.
        listingCID[newId]      = listingCID[oldId];
        listingKeyHash[newId]  = listingKeyHash[oldId];
        listingCategory[newId] = listingCategory[oldId];

        // Provenance links, so the full history of an idea is readable.
        reauctionedFrom[newId] = oldId;
        reauctionedTo[oldId]   = newId;
        reauctionCount[newId]  = reauctionCount[oldId] + 1;

        inventorListings[o.inventor].push(newId);
        totalListings++;

        if (governorContract != address(0)) {
            IGovernor(governorContract).onListingCreated(newId, o.inventor);
        }
        emit Reauctioned(oldId, newId, o.inventor, reserve, end);
        emit Listed(newId, o.inventor, reserve, end);
    }

    /// @notice Archive a finished listing so it no longer appears in
    ///         active views and can take no further interaction.
    /// @dev On-chain data is permanent — this is a status change, not
    ///      erasure, and the record stays publicly readable forever.
    ///      Blocked while anything is still owed on the listing, so an
    ///      archive can never hide an unsettled obligation.
    ///      Status 8 = Archived.
    function archiveListing(uint256 id) external onlyRole(GOVERNOR_ROLE) exists(id) {
        Listing storage l = listings[id];

        if (l.status == 8) revert AlreadyArchived();

        // Only settled outcomes may be archived: Complete (4) or
        // Cancelled/Refunded (6).
        if (l.status != 4 && l.status != 6) revert CannotArchiveActive();

        // A completed sale must have actually paid out.
        if (l.status == 4 && !l.fundsReleased) revert FundsStillOwed();

        // Any bidder deposit still unclaimed blocks the archive.
        address[] storage bs = bidders[id];
        uint256 n = bs.length;
        for (uint256 i; i < n; ++i) {
            Bid storage b = bids[id][bs[i]];
            if (b.commitment != bytes32(0) && !b.refunded && !b.isWinner) {
                revert FundsStillOwed();
            }
        }

        l.status = 8;
        emit Archived(id, msg.sender);
    }

    /// @notice Full relisting chain for an idea, oldest first.
    function getReauctionHistory(uint256 id) external view returns (uint256[] memory chain) {
        // Walk back to the original.
        uint256 root = id;
        while (reauctionedFrom[root] != 0) root = reauctionedFrom[root];
        // Count forward.
        uint256 len = 1;
        uint256 cur = root;
        while (reauctionedTo[cur] != 0) { cur = reauctionedTo[cur]; len++; }
        // Fill.
        chain = new uint256[](len);
        cur = root;
        for (uint256 i; i < len; ++i) {
            chain[i] = cur;
            cur = reauctionedTo[cur];
        }
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function activateEmergency() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = true;
        _pause();
        emit EmergencyActivated(msg.sender);
    }

    function deactivateEmergency() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = false;
        _unpause();
        emit EmergencyDeactivated(msg.sender);
    }

    /*////////////////////////////////////////////////////////////////
                   TIMELOCKED ADMIN PARAMETER CHANGES
    ////////////////////////////////////////////////////////////////*/

    /// @notice Queue a platform fee change (24h timelock).
    function queueFeeChange(uint256 f) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (f < MIN_FEE || f > MAX_FEE) revert BadFee();
        uint256 at = block.timestamp + ADMIN_TIMELOCK;
        pendingFeeChange = PendingAdminChange(f, address(0), at);
        emit FeeChangeQueued(f, at);
    }

    function executeFeeChange() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingAdminChange memory p = pendingFeeChange;
        if (p.executableAt == 0)              revert NotQueued();
        if (block.timestamp < p.executableAt) revert TimelockActive();
        uint256 old = platformFeeBps;
        platformFeeBps = p.newValue;
        delete pendingFeeChange;
        emit FeeChanged(old, p.newValue);
    }

    /// @notice Queue a platform-wallet change (24h timelock).
    function queueWalletChange(address w) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (w == address(0)) revert ZeroAddress();
        uint256 at = block.timestamp + ADMIN_TIMELOCK;
        pendingWalletChange = PendingAdminChange(0, w, at);
        emit WalletChangeQueued(w, at);
    }

    function executeWalletChange() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingAdminChange memory p = pendingWalletChange;
        if (p.executableAt == 0)              revert NotQueued();
        if (block.timestamp < p.executableAt) revert TimelockActive();
        address old = platformWallet;
        platformWallet = p.newAddress;
        delete pendingWalletChange;
        emit PlatformWalletChanged(old, p.newAddress);
    }

    function setGovernorContract(address g) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (g == address(0)) revert ZeroAddress();
        governorContract = g;
        emit GovernorContractSet(g);
    }

    function setValuationContract(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (v == address(0)) revert ZeroAddress();
        valuationContract = v;
        emit ValuationContractSet(v);
    }

    /*////////////////////////////////////////////////////////////////
                     EMERGENCY DRAIN (TIMELOCKED)
    ////////////////////////////////////////////////////////////////*/

    function queueEmergencyDrain() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!emergencyMode) revert NotInEmergency();
        emergencyDrainQueuedAt = block.timestamp;
        emit EmergencyDrainQueued(block.timestamp + EMERGENCY_DELAY);
    }

    function cancelEmergencyDrain() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyDrainQueuedAt = 0;
        emit EmergencyDrainCancelled();
    }

    function emergencyDrain(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!emergencyMode) revert NotInEmergency();
        if (to == address(0)) revert ZeroAddress();
        if (emergencyDrainQueuedAt == 0) revert NotQueued();
        if (block.timestamp < emergencyDrainQueuedAt + EMERGENCY_DELAY) revert TimelockActive();
        emergencyDrainQueuedAt = 0;
        uint256 bal = address(this).balance;
        (bool ok,) = payable(to).call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit EmergencyDrained(to, bal);
    }

    /*////////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Public solvency invariant: the contract must always hold
    ///         at least its total outstanding obligations.
    function isSolvent() external view returns (bool) {
        return address(this).balance >= totalEscrowed;
    }

    function getListing(uint256 id) external view returns (Listing memory) {
        return listings[id];
    }

    function getListingStrings(uint256 id)
        external view returns (string memory cid, string memory keyHash, string memory category)
    {
        return (listingCID[id], listingKeyHash[id], listingCategory[id]);
    }

    function getBidders(uint256 id) external view returns (address[] memory) {
        return bidders[id];
    }

    function getBid(uint256 id, address bidder) external view returns (Bid memory) {
        return bids[id][bidder];
    }

    /// @notice Only the auction winner can read the delivered key.
    function getWinnerKey(uint256 id) external view returns (string memory) {
        Listing storage l = listings[id];
        if (msg.sender != l.winner || !l.keyDelivered) revert Denied();
        return _listingEncryptedKey[id];
    }

    function getInventorListings(address a) external view returns (uint256[] memory) {
        return inventorListings[a];
    }

    function getBidderHistory(address a) external view returns (uint256[] memory) {
        return bidderHistory[a];
    }

    function getPlatformStats()
        external view returns (uint256 listed, uint256 volume, uint256 bidCount, bool isPaused)
    {
        return (totalListings, totalVolumeWei, totalBids, paused());
    }

    receive() external payable {}
}
