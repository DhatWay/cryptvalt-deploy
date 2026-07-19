// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                        CRYPTVALT REVENUE ROUTER v2.0
        Platinum / Founder / Scout / Treasury Distribution — OZ Edition
//////////////////////////////////////////////////////////////////////////*/

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CryptValt Revenue Router
/// @author CryptValt
/// @notice Splits platform revenue between Platinum members (10%),
///         Founder holders (15%), and the treasury; routes scout
///         referral commissions.
/// @dev v2.0 hardened release on OpenZeppelin audited bases
///      (Ownable2Step, ReentrancyGuard). Security fixes over v1:
///      - INSOLVENCY FIX: accumulator is now per-TOKEN (divides by total
///        token count, matching the per-token multiplication in pending
///        calculations). v1 divided by holder count but multiplied by
///        token count, overpaying multi-token holders from other
///        people's pools.
///      - SCOUT FUNDING FIX: payScout is now payable — the scout's
///        commission ETH must arrive with the call, so scout claims can
///        never drain the Platinum/Founder pools.
///      - SETTLEMENT FIX: holder registration changes settle pending
///        revenue to the holder's credit first, so no revenue is lost
///        on removal or diluted on top-up.
///      - Precision: accumulators scaled by 1e18.
contract CryptValtRevenue is Ownable2Step, ReentrancyGuard {

    /*////////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////////*/

    uint256 public constant PLATINUM_SHARE_BPS = 1000; // 10%
    uint256 public constant FOUNDER_SHARE_BPS  = 1500; // 15%
    uint256 public constant BPS                = 10_000;
    uint256 public constant EMERGENCY_DELAY    = 48 hours;
    uint256 private constant ACC_PRECISION     = 1e18;

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized();
    error ScoutAlreadySet();
    error NotHolder();
    error NothingToClaim();
    error TransferFailed();
    error BadMultiplier();
    error NotQueued();
    error TimelockActive();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    address public treasury;
    address public cryptvalt;
    address public membershipContract;
    address public founderContract;

    uint256 public totalDeposited;
    uint256 public totalScoutPaid;
    uint256 public totalTreasuryPaid;
    uint256 public emergencyWithdrawQueuedAt;

    // ── Platinum pool ──
    uint256 public platinumTokenTotal;              // total Platinum tokens registered
    uint256 public accPerPlatinumToken;             // scaled 1e18
    mapping(address => bool)    public isPlatinumHolder;
    mapping(address => uint256) public platinumTokenCount;
    mapping(address => uint256) public platinumDebt;     // scaled snapshot × count
    mapping(address => uint256) public platinumCredit;   // settled, claimable wei
    mapping(address => uint256) public platinumClaimed;

    // ── Founder pool ──
    uint256 public founderTokenTotal;
    uint256 public accPerFounderToken;              // scaled 1e18
    mapping(address => bool)    public isFounderHolder;
    mapping(address => uint256) public founderTokenCount;
    mapping(address => uint256) public founderDebt;
    mapping(address => uint256) public founderCredit;
    mapping(address => uint256) public founderClaimed;

    // ── Scouts ──
    mapping(uint256 => address) public listingScout;
    mapping(address => uint256) public scoutCredit;      // funded, claimable wei
    mapping(address => uint256) public scoutClaimed;
    mapping(address => uint256) public scoutListingsCount;
    mapping(address => uint256) public scoutSuccessCount;
    mapping(address => uint256) public scoutMultiplier;  // informational, BPS

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event RevenueDeposited(uint256 amount, uint256 platinumShare, uint256 founderShare, uint256 treasuryShare);
    event PlatinumClaimed(address indexed holder, uint256 amount);
    event FounderClaimed(address indexed holder, uint256 amount);
    event ScoutClaimed(address indexed scout, uint256 amount);
    event ScoutRegistered(uint256 indexed listingId, address indexed scout);
    event ScoutPaid(uint256 indexed listingId, address indexed scout, uint256 amount);
    event HolderRegistered(address indexed holder, string tier, uint256 tokenCount);
    event HolderRemoved(address indexed holder, string tier);
    event ScoutMultiplierSet(address indexed scout, uint256 multiplierBPS);
    event TreasuryUpdated(address indexed newTreasury);
    event ContractsSet(address indexed cryptvalt, address indexed membership, address indexed founder);
    event EmergencyWithdrawQueued(uint256 executableAt);
    event EmergencyWithdrawCancelled();
    event EmergencyWithdrawn(uint256 amount);

    /*////////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    modifier onlyAuth() {
        if (
            msg.sender != owner() &&
            msg.sender != cryptvalt &&
            msg.sender != membershipContract &&
            msg.sender != founderContract
        ) revert NotAuthorized();
        _;
    }

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param initialOwner Deployer/admin — transfer to the Safe via
    ///                     transferOwnership + acceptOwnership.
    /// @param _treasury    Receives the residual share of deposits.
    constructor(address initialOwner, address _treasury) Ownable(initialOwner) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /*////////////////////////////////////////////////////////////////
                              DISTRIBUTION
    ////////////////////////////////////////////////////////////////*/

    /// @notice Deposit platform revenue: 10% Platinum pool, 15% Founder
    ///         pool, remainder to treasury. Empty pools' shares fall
    ///         through to treasury.
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        _distribute(msg.value);
    }

    function _distribute(uint256 amount) internal {
        uint256 toPlatinum = (amount * PLATINUM_SHARE_BPS) / BPS;
        uint256 toFounder  = (amount * FOUNDER_SHARE_BPS)  / BPS;
        uint256 toTreasury = amount - toPlatinum - toFounder;

        totalDeposited += amount;

        // v2.0 fix: divide by TOKEN totals (matches per-token payout math).
        if (platinumTokenTotal > 0 && toPlatinum > 0) {
            accPerPlatinumToken += (toPlatinum * ACC_PRECISION) / platinumTokenTotal;
        } else {
            toTreasury += toPlatinum;
            toPlatinum = 0;
        }

        if (founderTokenTotal > 0 && toFounder > 0) {
            accPerFounderToken += (toFounder * ACC_PRECISION) / founderTokenTotal;
        } else {
            toTreasury += toFounder;
            toFounder = 0;
        }

        totalTreasuryPaid += toTreasury;
        if (toTreasury > 0) {
            (bool ok,) = payable(treasury).call{value: toTreasury}("");
            if (!ok) revert TransferFailed();
        }
        emit RevenueDeposited(amount, toPlatinum, toFounder, toTreasury);
    }

    /*////////////////////////////////////////////////////////////////
                                 SCOUTS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Attach a scout (referrer) to a listing.
    function registerScout(uint256 listingId, address scout) external onlyAuth {
        if (scout == address(0)) revert ZeroAddress();
        if (listingScout[listingId] != address(0)) revert ScoutAlreadySet();
        listingScout[listingId] = scout;
        scoutListingsCount[scout]++;
        if (scoutMultiplier[scout] == 0) scoutMultiplier[scout] = BPS;
        emit ScoutRegistered(listingId, scout);
    }

    /// @notice Fund a scout's commission for a settled listing.
    /// @dev v2.0 FUNDING FIX: payable — commission ETH arrives with the
    ///      call, so scout claims are always backed 1:1 by real funds
    ///      and can never draw on the Platinum/Founder pools.
    function payScout(uint256 listingId) external payable onlyAuth {
        address scout = listingScout[listingId];
        if (scout == address(0)) {
            // No scout attached — forward funds to treasury.
            if (msg.value > 0) {
                (bool ok,) = payable(treasury).call{value: msg.value}("");
                if (!ok) revert TransferFailed();
            }
            return;
        }
        if (msg.value == 0) revert ZeroAmount();
        scoutCredit[scout] += msg.value;
        scoutSuccessCount[scout]++;
        totalScoutPaid += msg.value;
        emit ScoutPaid(listingId, scout, msg.value);
    }

    /// @notice Informational multiplier used off-chain to size scout
    ///         commissions (1x–3x).
    function setScoutMultiplier(address scout, uint256 multiplierBPS) external onlyOwner {
        if (scout == address(0)) revert ZeroAddress();
        if (multiplierBPS < BPS || multiplierBPS > 30_000) revert BadMultiplier();
        scoutMultiplier[scout] = multiplierBPS;
        emit ScoutMultiplierSet(scout, multiplierBPS);
    }

    /*////////////////////////////////////////////////////////////////
                          HOLDER REGISTRATION
    ////////////////////////////////////////////////////////////////*/

    /// @dev Settle a platinum holder's accrued revenue into credit
    ///      before any token-count change (v2.0 settlement fix).
    function _settlePlatinum(address holder) internal {
        uint256 accrued = (platinumTokenCount[holder] * accPerPlatinumToken);
        if (accrued > platinumDebt[holder]) {
            platinumCredit[holder] += (accrued - platinumDebt[holder]) / ACC_PRECISION;
        }
        platinumDebt[holder] = platinumTokenCount[holder] * accPerPlatinumToken;
    }

    function _settleFounder(address holder) internal {
        uint256 accrued = (founderTokenCount[holder] * accPerFounderToken);
        if (accrued > founderDebt[holder]) {
            founderCredit[holder] += (accrued - founderDebt[holder]) / ACC_PRECISION;
        }
        founderDebt[holder] = founderTokenCount[holder] * accPerFounderToken;
    }

    /// @notice Register or top up a Platinum holder's token count.
    function registerPlatinumHolder(address holder, uint256 tokenCount) external onlyAuth {
        if (holder == address(0)) revert ZeroAddress();
        _settlePlatinum(holder);
        if (!isPlatinumHolder[holder]) isPlatinumHolder[holder] = true;
        platinumTokenCount[holder] += tokenCount;
        platinumTokenTotal         += tokenCount;
        platinumDebt[holder] = platinumTokenCount[holder] * accPerPlatinumToken;
        emit HolderRegistered(holder, "PLATINUM", tokenCount);
    }

    /// @notice Remove a Platinum holder. Pending revenue is settled to
    ///         their claimable credit first — nothing is lost.
    function removePlatinumHolder(address holder) external onlyAuth {
        if (!isPlatinumHolder[holder]) revert NotHolder();
        _settlePlatinum(holder);
        platinumTokenTotal -= platinumTokenCount[holder];
        platinumTokenCount[holder] = 0;
        platinumDebt[holder] = 0;
        isPlatinumHolder[holder] = false;
        emit HolderRemoved(holder, "PLATINUM");
    }

    /// @notice Register or top up a Founder holder's token count.
    function registerFounderHolder(address holder, uint256 tokenCount) external onlyAuth {
        if (holder == address(0)) revert ZeroAddress();
        _settleFounder(holder);
        if (!isFounderHolder[holder]) isFounderHolder[holder] = true;
        founderTokenCount[holder] += tokenCount;
        founderTokenTotal         += tokenCount;
        founderDebt[holder] = founderTokenCount[holder] * accPerFounderToken;
        emit HolderRegistered(holder, "FOUNDER", tokenCount);
    }

    /// @notice Remove a Founder holder (pending revenue settled first).
    function removeFounderHolder(address holder) external onlyAuth {
        if (!isFounderHolder[holder]) revert NotHolder();
        _settleFounder(holder);
        founderTokenTotal -= founderTokenCount[holder];
        founderTokenCount[holder] = 0;
        founderDebt[holder] = 0;
        isFounderHolder[holder] = false;
        emit HolderRemoved(holder, "FOUNDER");
    }

    /*////////////////////////////////////////////////////////////////
                                 CLAIMS
    ////////////////////////////////////////////////////////////////*/

    function claimPlatinum() external nonReentrant {
        _settlePlatinum(msg.sender);
        uint256 owed = platinumCredit[msg.sender];
        if (owed == 0) revert NothingToClaim();
        platinumCredit[msg.sender] = 0;
        platinumClaimed[msg.sender] += owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        if (!ok) revert TransferFailed();
        emit PlatinumClaimed(msg.sender, owed);
    }

    function claimFounder() external nonReentrant {
        _settleFounder(msg.sender);
        uint256 owed = founderCredit[msg.sender];
        if (owed == 0) revert NothingToClaim();
        founderCredit[msg.sender] = 0;
        founderClaimed[msg.sender] += owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        if (!ok) revert TransferFailed();
        emit FounderClaimed(msg.sender, owed);
    }

    function claimScout() external nonReentrant {
        uint256 owed = scoutCredit[msg.sender];
        if (owed == 0) revert NothingToClaim();
        scoutCredit[msg.sender] = 0;
        scoutClaimed[msg.sender] += owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        if (!ok) revert TransferFailed();
        emit ScoutClaimed(msg.sender, owed);
    }

    /// @notice Claim Platinum + Founder + Scout balances in one call.
    function claimAll() external nonReentrant {
        _settlePlatinum(msg.sender);
        _settleFounder(msg.sender);

        uint256 total = platinumCredit[msg.sender] + founderCredit[msg.sender] + scoutCredit[msg.sender];
        if (total == 0) revert NothingToClaim();

        if (platinumCredit[msg.sender] > 0) {
            platinumClaimed[msg.sender] += platinumCredit[msg.sender];
            emit PlatinumClaimed(msg.sender, platinumCredit[msg.sender]);
            platinumCredit[msg.sender] = 0;
        }
        if (founderCredit[msg.sender] > 0) {
            founderClaimed[msg.sender] += founderCredit[msg.sender];
            emit FounderClaimed(msg.sender, founderCredit[msg.sender]);
            founderCredit[msg.sender] = 0;
        }
        if (scoutCredit[msg.sender] > 0) {
            scoutClaimed[msg.sender] += scoutCredit[msg.sender];
            emit ScoutClaimed(msg.sender, scoutCredit[msg.sender]);
            scoutCredit[msg.sender] = 0;
        }

        (bool ok,) = payable(msg.sender).call{value: total}("");
        if (!ok) revert TransferFailed();
    }

    /*////////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function pendingPlatinum(address holder) public view returns (uint256) {
        uint256 accrued = platinumTokenCount[holder] * accPerPlatinumToken;
        uint256 unsettled = accrued > platinumDebt[holder]
            ? (accrued - platinumDebt[holder]) / ACC_PRECISION : 0;
        return platinumCredit[holder] + unsettled;
    }

    function pendingFounder(address holder) public view returns (uint256) {
        uint256 accrued = founderTokenCount[holder] * accPerFounderToken;
        uint256 unsettled = accrued > founderDebt[holder]
            ? (accrued - founderDebt[holder]) / ACC_PRECISION : 0;
        return founderCredit[holder] + unsettled;
    }

    function pendingScout(address scout) public view returns (uint256) {
        return scoutCredit[scout];
    }

    function pendingAll(address wallet)
        external view
        returns (uint256 platinum, uint256 founder, uint256 scout, uint256 total)
    {
        platinum = pendingPlatinum(wallet);
        founder  = pendingFounder(wallet);
        scout    = pendingScout(wallet);
        total    = platinum + founder + scout;
    }

    function getStats()
        external view
        returns (
            uint256 deposited, uint256 scoutPaid, uint256 treasuryPaid,
            uint256 platinumTokens, uint256 founderTokens
        )
    {
        return (totalDeposited, totalScoutPaid, totalTreasuryPaid, platinumTokenTotal, founderTokenTotal);
    }

    function getScoutStats(address scout)
        external view
        returns (
            uint256 listingsCount, uint256 successes, uint256 claimedAmt,
            uint256 pending, uint256 multiplier
        )
    {
        return (
            scoutListingsCount[scout], scoutSuccessCount[scout],
            scoutClaimed[scout], scoutCredit[scout], scoutMultiplier[scout]
        );
    }

    /*////////////////////////////////////////////////////////////////
                                  ADMIN
    ////////////////////////////////////////////////////////////////*/

    function setCryptValt(address c) external onlyOwner {
        if (c == address(0)) revert ZeroAddress();
        cryptvalt = c;
        emit ContractsSet(c, membershipContract, founderContract);
    }

    function setMembership(address m) external onlyOwner {
        if (m == address(0)) revert ZeroAddress();
        membershipContract = m;
        emit ContractsSet(cryptvalt, m, founderContract);
    }

    function setFounder(address f) external onlyOwner {
        if (f == address(0)) revert ZeroAddress();
        founderContract = f;
        emit ContractsSet(cryptvalt, membershipContract, f);
    }

    function updateTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    /*////////////////////////////////////////////////////////////////
                    EMERGENCY WITHDRAW (TIMELOCKED)
    ////////////////////////////////////////////////////////////////*/

    function queueEmergencyWithdraw() external onlyOwner {
        emergencyWithdrawQueuedAt = block.timestamp;
        emit EmergencyWithdrawQueued(block.timestamp + EMERGENCY_DELAY);
    }

    function cancelEmergencyWithdraw() external onlyOwner {
        emergencyWithdrawQueuedAt = 0;
        emit EmergencyWithdrawCancelled();
    }

    function emergencyWithdraw() external onlyOwner {
        if (emergencyWithdrawQueuedAt == 0) revert NotQueued();
        if (block.timestamp < emergencyWithdrawQueuedAt + EMERGENCY_DELAY) revert TimelockActive();
        emergencyWithdrawQueuedAt = 0;
        uint256 bal = address(this).balance;
        (bool ok,) = payable(treasury).call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit EmergencyWithdrawn(bal);
    }

    receive() external payable {
        _distribute(msg.value);
    }
}
