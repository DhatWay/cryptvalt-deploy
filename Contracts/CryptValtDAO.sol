// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * CryptValt DAO Governance
 * CVT holders vote on proposals that shape the platform.
 */

interface ICVTToken {
    function getVotingPower(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IFounderNFT {
    function balanceOf(address user) external view returns (uint256);
}

contract CryptValtDAO {

    uint256 public constant PROPOSAL_THRESHOLD = 10_000 * 10**18;
    uint256 public constant VOTING_PERIOD      = 7 days;
    uint256 public constant TIMELOCK_PERIOD    = 48 hours;
    uint256 public constant QUORUM_BPS         = 500;
    uint256 public constant PASS_BPS           = 6000;
    uint256 public constant BPS                = 10000;

    struct Proposal {
        address proposer;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 startTime;
        uint256 endTime;
        uint256 queuedAt;
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

    address public owner;
    ICVTToken   public cvtToken;
    IFounderNFT public founderNFT;
    address public treasury;

    uint256 public proposalCount;
    uint256 public totalVotesCast;
    bool    public paused;

    mapping(uint256 => Proposal)                    public proposals;
    mapping(uint256 => string)                      public proposalTitles;
    mapping(uint256 => string)                      public proposalDescriptions;
    mapping(uint256 => bytes)                       public proposalCallData;
    mapping(uint256 => mapping(address => Receipt)) public receipts;
    mapping(address => uint256[])                   public proposerHistory;
    mapping(address => uint256)                     public delegatedPower;

    event ProposalCreated(uint256 indexed id, address indexed proposer, string title, uint256 endTime);
    event VoteCast(uint256 indexed id, address indexed voter, uint8 support, uint256 votes);
    event ProposalQueued(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);
    event ProposalVetoed(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    modifier notPaused() { require(!paused, "Paused"); _; }

    constructor(address _cvt, address _founder, address _treasury) {
        owner      = msg.sender;
        cvtToken   = ICVTToken(_cvt);
        founderNFT = IFounderNFT(_founder);
        treasury   = _treasury;
    }

    function propose(
        string calldata title,
        string calldata description,
        uint8 proposalType,
        address target,
        bytes calldata callData
    ) external notPaused returns (uint256) {
        require(getVotingPower(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient CVT");
        require(bytes(title).length > 0 && bytes(description).length > 0, "Fields required");

        proposalCount++;
        uint256 id = proposalCount;

        proposals[id].proposer      = msg.sender;
        proposals[id].proposalType  = proposalType;
        proposals[id].startTime     = block.timestamp;
        proposals[id].endTime       = block.timestamp + VOTING_PERIOD;
        proposals[id].target        = target;

        proposalTitles[id]       = title;
        proposalDescriptions[id] = description;
        proposalCallData[id]     = callData;

        proposerHistory[msg.sender].push(id);

        emit ProposalCreated(id, msg.sender, title, block.timestamp + VOTING_PERIOD);
        return id;
    }

    function castVote(uint256 id, uint8 support) external notPaused {
        require(support <= 2,                              "Invalid support");
        require(getState(id) == 1,                         "Not active");
        require(!receipts[id][msg.sender].hasVoted,        "Already voted");

        uint256 votes = getVotingPower(msg.sender);
        require(votes > 0, "No voting power");

        receipts[id][msg.sender] = Receipt(true, support, votes);
        totalVotesCast++;

        if      (support == 1) proposals[id].forVotes     += votes;
        else if (support == 0) proposals[id].againstVotes += votes;
        else                   proposals[id].abstainVotes += votes;

        emit VoteCast(id, msg.sender, support, votes);
    }

    function queue(uint256 id) external {
        require(getState(id) == 2, "Not succeeded");
        proposals[id].queuedAt = block.timestamp;
        emit ProposalQueued(id);
    }

    function execute(uint256 id) external {
        require(getState(id) == 4, "Not queued");
        require(block.timestamp >= proposals[id].queuedAt + TIMELOCK_PERIOD, "Timelock");
        proposals[id].executed = true;
        address target = proposals[id].target;
        if (target != address(0) && proposalCallData[id].length > 0) {
            (bool ok,) = target.call(proposalCallData[id]);
            require(ok, "Execution failed");
        }
        emit ProposalExecuted(id);
    }

    function veto(uint256 id) external {
        require(founderNFT.balanceOf(msg.sender) > 0, "Not a Founder");
        Proposal storage p = proposals[id];
        require(!p.executed && !p.vetoed && !p.cancelled, "Finalized");
        uint8 s = getState(id);
        require(s == 1 || s == 2 || s == 4, "Cannot veto");
        p.vetoed = true;
        emit ProposalVetoed(id);
    }

    function cancel(uint256 id) external {
        require(msg.sender == proposals[id].proposer || msg.sender == owner);
        require(!proposals[id].executed && !proposals[id].vetoed);
        proposals[id].cancelled = true;
        emit ProposalCancelled(id);
    }

    function delegate(address to, uint256 power) external {
        delegatedPower[to] += power;
    }

    function getVotingPower(address user) public view returns (uint256) {
        uint256 base    = cvtToken.getVotingPower(user);
        uint256 bonus   = founderNFT.balanceOf(user) > 0 ? base * 2 : 0;
        uint256 del     = delegatedPower[user];
        return base + bonus + del;
    }

    // State: 0=Pending 1=Active 2=Succeeded 3=Defeated 4=Queued 5=Executed 6=Vetoed 7=Cancelled
    function getState(uint256 id) public view returns (uint8) {
        Proposal storage p = proposals[id];
        if (p.cancelled)                       return 7;
        if (p.vetoed)                          return 6;
        if (p.executed)                        return 5;
        if (block.timestamp < p.startTime)     return 0;
        if (block.timestamp <= p.endTime)      return 1;

        uint256 total   = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 quorum  = (cvtToken.totalSupply() * QUORUM_BPS) / BPS;
        if (total < quorum)                    return 3;
        if (p.forVotes * BPS < (p.forVotes + p.againstVotes) * PASS_BPS) return 3;
        if (p.queuedAt > 0)                    return 4;
        return 2;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) { return proposals[id]; }
    function getTitle(uint256 id) external view returns (string memory) { return proposalTitles[id]; }
    function getDescription(uint256 id) external view returns (string memory) { return proposalDescriptions[id]; }
    function getReceipt(uint256 id, address voter) external view returns (Receipt memory) { return receipts[id][voter]; }
    function getProposerHistory(address p) external view returns (uint256[] memory) { return proposerHistory[p]; }

    function setCVT(address t) external onlyOwner { cvtToken = ICVTToken(t); }
    function setFounder(address f) external onlyOwner { founderNFT = IFounderNFT(f); }
    function setPaused(bool p) external onlyOwner { paused = p; }
}
