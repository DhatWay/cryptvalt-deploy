// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                            CRYPTVALT DAO v2.0
              Token Governance with Founder Veto — OZ Edition
//////////////////////////////////////////////////////////////////////////*/

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICVTToken {
    function getVotingPower(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IFounderNFT {
    function balanceOf(address user) external view returns (uint256);
}

/// @title CryptValt DAO
/// @author CryptValt
/// @notice Token-weighted governance: CVT holders propose and vote,
///         Founder NFT holders carry a 2x multiplier and veto power.
///         Passed proposals execute against a whitelist of targets
///         after a 48h timelock.
/// @dev v2.0 modernization on OpenZeppelin bases (Ownable2Step,
///      Pausable, ReentrancyGuard). Changes over v1:
///      - QUORUM SNAPSHOT: total supply is snapshotted at proposal
///        creation, so quorum can't be manipulated by minting/burning
///        during the vote
///      - Custom errors, full event coverage, executed-flag reentrancy
///        ordering preserved
///
///      KNOWN LIMITATION (documented, v3 roadmap): voting power is
///      read live at vote time rather than from historical checkpoints,
///      so tokens moved between wallets during a voting period could
///      vote more than once. Mitigations in place: one vote per wallet
///      per proposal, Founder veto over any malicious proposal, target
///      whitelist + 48h timelock on execution, and owner pause. Full
///      fix is migrating CVT to ERC20Votes checkpoints (planned before
///      the DAO controls treasury funds).
contract CryptValtDAO is Ownable2Step, Pausable, ReentrancyGuard {

    /*////////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////////*/

    uint256 public constant PROPOSAL_THRESHOLD = 10_000e18;
    uint256 public constant VOTING_PERIOD      = 7 days;
    uint256 public constant TIMELOCK_PERIOD    = 48 hours;
    uint256 public constant QUORUM_BPS         = 500;   // 5%
    uint256 public constant PASS_BPS           = 6_000; // 60% of for+against
    uint256 public constant BPS                = 10_000;
    /// @dev Founder NFTs required to veto a proposal. See veto().
    uint256 public constant VETO_THRESHOLD     = 3;

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidDelegate();
    error InsufficientPower();
    error FieldsRequired();
    error InvalidSupport();
    error NotActiveState();
    error AlreadyVoted();
    error NoVotingPower();
    error NotSucceeded();
    error NotQueuedState();
    error TimelockNotElapsed();
    error TargetNotAllowed();
    error ExecutionFailed();
    error NotFounder();
    error Finalized();
    error CannotVeto();
    error NotProposerOrOwner();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    struct Proposal {
        address proposer;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 startTime;
        uint256 endTime;
        uint256 queuedAt;
        uint256 supplySnapshot;   // v2.0: quorum base frozen at creation
        uint8   proposalType;
        bool    executed;
        bool    vetoed;
        bool    cancelled;
        address target;
    }

    struct Receipt {
        bool    hasVoted;
        uint8   support;
        uint256 votes;
    }

    ICVTToken   public cvtToken;
    IFounderNFT public founderNFT;
    address     public immutable treasury;

    uint256 public proposalCount;
    uint256 public totalVotesCast;

    mapping(uint256 => Proposal)                    public proposals;
    mapping(uint256 => string)                      public proposalTitles;
    mapping(uint256 => string)                      public proposalDescriptions;
    mapping(uint256 => bytes)                       public proposalCallData;
    mapping(uint256 => mapping(address => Receipt)) public receipts;
    mapping(address => uint256[])                   public proposerHistory;

    mapping(address => address) public delegatedTo;
    mapping(address => uint256) public delegatedIn;

    mapping(address => bool) public allowedExecutors;

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event ProposalCreated(uint256 indexed id, address indexed proposer, string title, uint256 endTime);
    event VoteCast(uint256 indexed id, address indexed voter, uint8 support, uint256 votes);
    event ProposalQueued(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);
    event ProposalVetoed(uint256 indexed id, address indexed by);
    event ProposalCancelled(uint256 indexed id);
    event Delegated(address indexed from, address indexed to, uint256 power);
    event AllowedExecutorAdded(address indexed executor);
    event AllowedExecutorRemoved(address indexed executor);
    event CVTSet(address indexed token);
    event FounderSet(address indexed founder);

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param initialOwner Deployer/admin — transfer to the Safe via
    ///                     transferOwnership + acceptOwnership.
    constructor(address initialOwner, address _cvt, address _founder, address _treasury)
        Ownable(initialOwner)
    {
        if (_cvt == address(0) || _founder == address(0) || _treasury == address(0)) revert ZeroAddress();
        cvtToken   = ICVTToken(_cvt);
        founderNFT = IFounderNFT(_founder);
        treasury   = _treasury;
    }

    /*////////////////////////////////////////////////////////////////
                             VOTING POWER
    ////////////////////////////////////////////////////////////////*/

    /// @notice Voting power before delegation: CVT power (balance +
    ///         2× staked) doubled again for Founder NFT holders.
    function baseVotingPower(address user) public view returns (uint256) {
        uint256 base = cvtToken.getVotingPower(user);
        if (founderNFT.balanceOf(user) > 0) base *= 2;
        return base;
    }

    /// @notice Delegate your voting power to another wallet.
    function delegate(address to) external whenNotPaused {
        if (to == address(0) || to == msg.sender) revert InvalidDelegate();
        address old = delegatedTo[msg.sender];
        uint256 power = baseVotingPower(msg.sender);
        if (old != address(0)) {
            delegatedIn[old] = delegatedIn[old] >= power ? delegatedIn[old] - power : 0;
        }
        delegatedTo[msg.sender] = to;
        delegatedIn[to] += power;
        emit Delegated(msg.sender, to, power);
    }

    /// @notice Effective voting power: own power (zero if delegated
    ///         away) plus power delegated in.
    function getVotingPower(address user) public view returns (uint256) {
        uint256 own = delegatedTo[user] != address(0) ? 0 : baseVotingPower(user);
        return own + delegatedIn[user];
    }

    /*////////////////////////////////////////////////////////////////
                               PROPOSALS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Create a proposal (requires 10,000 CVT of voting power).
    function propose(
        string calldata title,
        string calldata description,
        uint8 proposalType,
        address target,
        bytes calldata callData
    ) external whenNotPaused returns (uint256 id) {
        if (getVotingPower(msg.sender) < PROPOSAL_THRESHOLD) revert InsufficientPower();
        if (bytes(title).length == 0 || bytes(description).length == 0) revert FieldsRequired();

        id = ++proposalCount;
        Proposal storage p = proposals[id];
        p.proposer       = msg.sender;
        p.proposalType   = proposalType;
        p.startTime      = block.timestamp;
        p.endTime        = block.timestamp + VOTING_PERIOD;
        p.target         = target;
        p.supplySnapshot = cvtToken.totalSupply(); // v2.0 quorum snapshot

        proposalTitles[id]       = title;
        proposalDescriptions[id] = description;
        proposalCallData[id]     = callData;
        proposerHistory[msg.sender].push(id);

        emit ProposalCreated(id, msg.sender, title, p.endTime);
    }

    /// @notice Cast a vote. support: 0=against, 1=for, 2=abstain.
    function castVote(uint256 id, uint8 support) external whenNotPaused {
        if (support > 2) revert InvalidSupport();
        if (getState(id) != 1) revert NotActiveState();
        if (receipts[id][msg.sender].hasVoted) revert AlreadyVoted();

        uint256 votes = getVotingPower(msg.sender);
        if (votes == 0) revert NoVotingPower();

        receipts[id][msg.sender] = Receipt(true, support, votes);
        totalVotesCast++;

        if      (support == 1) proposals[id].forVotes     += votes;
        else if (support == 0) proposals[id].againstVotes += votes;
        else                   proposals[id].abstainVotes += votes;

        emit VoteCast(id, msg.sender, support, votes);
    }

    /// @notice Queue a succeeded proposal for execution (starts the
    ///         48h timelock).
    function queue(uint256 id) external {
        if (getState(id) != 2) revert NotSucceeded();
        proposals[id].queuedAt = block.timestamp;
        emit ProposalQueued(id);
    }

    /// @notice Execute a queued proposal after the timelock. Targets
    ///         must be whitelisted.
    function execute(uint256 id) external nonReentrant {
        if (getState(id) != 4) revert NotQueuedState();
        Proposal storage p = proposals[id];
        if (block.timestamp < p.queuedAt + TIMELOCK_PERIOD) revert TimelockNotElapsed();

        p.executed = true; // set before external call (reentrancy ordering)
        address target = p.target;
        if (target != address(0) && !allowedExecutors[target]) revert TargetNotAllowed();
        if (target != address(0) && proposalCallData[id].length > 0) {
            (bool ok,) = target.call(proposalCallData[id]);
            if (!ok) revert ExecutionFailed();
        }
        emit ProposalExecuted(id);
    }

    /**
     * @notice Veto a non-finalized proposal.
     *
     * @dev Requires VETO_THRESHOLD founder NFTs, not one.
     *
     *      A single-token check made governance capturable for the
     *      price of one mint: mint() on the founder contract is public
     *      and payable, so anyone could buy one NFT and block every
     *      proposal, permanently, with no way to remove them. A veto is
     *      meant to be a founder safeguard against a hostile proposal,
     *      not a lever a passer-by can hold.
     *
     *      A threshold does not make capture impossible — someone can
     *      buy more tokens — but it prices it at a level where the
     *      holder has a real stake in the platform they would be
     *      breaking.
     */
    function veto(uint256 id) external {
        if (founderNFT.balanceOf(msg.sender) < VETO_THRESHOLD) revert NotFounder();
        Proposal storage p = proposals[id];
        if (p.executed || p.vetoed || p.cancelled) revert Finalized();
        uint8 s = getState(id);
        if (s != 1 && s != 2 && s != 4) revert CannotVeto();
        p.vetoed = true;
        emit ProposalVetoed(id, msg.sender);
    }

    /// @notice Proposer or owner can cancel a non-finalized proposal.
    function cancel(uint256 id) external {
        Proposal storage p = proposals[id];
        if (msg.sender != p.proposer && msg.sender != owner()) revert NotProposerOrOwner();
        if (p.executed || p.vetoed) revert Finalized();
        p.cancelled = true;
        emit ProposalCancelled(id);
    }

    /*////////////////////////////////////////////////////////////////
                                  STATE
    ////////////////////////////////////////////////////////////////*/

    /// @notice Proposal state machine.
    /// @return 0=Pending 1=Active 2=Succeeded 3=Defeated 4=Queued
    ///         5=Executed 6=Vetoed 7=Cancelled
    function getState(uint256 id) public view returns (uint8) {
        Proposal storage p = proposals[id];
        if (p.cancelled)                   return 7;
        if (p.vetoed)                      return 6;
        if (p.executed)                    return 5;
        if (block.timestamp < p.startTime) return 0;
        if (block.timestamp <= p.endTime)  return 1;

        uint256 total  = p.forVotes + p.againstVotes + p.abstainVotes;
        // v2.0: quorum measured against supply at proposal creation.
        uint256 quorum = (p.supplySnapshot * QUORUM_BPS) / BPS;
        if (total < quorum) return 3;
        if (p.forVotes * BPS < (p.forVotes + p.againstVotes) * PASS_BPS) return 3;
        if (p.queuedAt > 0) return 4;
        return 2;
    }

    /*////////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function getProposal(uint256 id) external view returns (Proposal memory) { return proposals[id]; }
    function getTitle(uint256 id) external view returns (string memory) { return proposalTitles[id]; }
    function getDescription(uint256 id) external view returns (string memory) { return proposalDescriptions[id]; }
    function getReceipt(uint256 id, address voter) external view returns (Receipt memory) { return receipts[id][voter]; }
    function getProposerHistory(address p) external view returns (uint256[] memory) { return proposerHistory[p]; }

    /*////////////////////////////////////////////////////////////////
                                  ADMIN
    ////////////////////////////////////////////////////////////////*/

    function addAllowedExecutor(address executor) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        allowedExecutors[executor] = true;
        emit AllowedExecutorAdded(executor);
    }

    function removeAllowedExecutor(address executor) external onlyOwner {
        allowedExecutors[executor] = false;
        emit AllowedExecutorRemoved(executor);
    }

    function setCVT(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        cvtToken = ICVTToken(t);
        emit CVTSet(t);
    }

    function setFounder(address f) external onlyOwner {
        if (f == address(0)) revert ZeroAddress();
        founderNFT = IFounderNFT(f);
        emit FounderSet(f);
    }

    function setPaused(bool p) external onlyOwner {
        if (p) _pause();
        else _unpause();
    }
}