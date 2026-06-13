// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * CryptValt Token (CVT)
 * ERC-20 Platform Token
 *
 * Tokenomics:
 * Total Supply: 100,000,000 CVT (100M)
 *
 * Distribution:
 * - 40% Community & Platform Rewards  — 40,000,000 CVT
 * - 20% Team & Advisors (2yr vesting) — 20,000,000 CVT
 * - 15% Treasury                      — 15,000,000 CVT
 * - 15% Ecosystem & Partnerships      — 15,000,000 CVT
 * - 10% Initial Liquidity             — 10,000,000 CVT
 *
 * Utility:
 * - Pay platform fees at 50% discount
 * - Stake to earn platform revenue share
 * - Governance voting power
 * - Boost scout referral multiplier
 * - Unlock premium features
 * - Required for DAO participation
 */

contract CryptValtToken {

    // ── ERC-20 Standard ────────────────────────────────────
    string  public constant name     = "CryptValt Token";
    string  public constant symbol   = "CVT";
    uint8   public constant decimals = 18;

    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 10**18; // 100M CVT

    // ── Distribution ───────────────────────────────────────
    uint256 public constant COMMUNITY_ALLOC   = 40_000_000 * 10**18;
    uint256 public constant TEAM_ALLOC        = 20_000_000 * 10**18;
    uint256 public constant TREASURY_ALLOC    = 15_000_000 * 10**18;
    uint256 public constant ECOSYSTEM_ALLOC   = 15_000_000 * 10**18;
    uint256 public constant LIQUIDITY_ALLOC   = 10_000_000 * 10**18;

    // ── Vesting ─────────────────────────────────────────────
    uint256 public constant VESTING_DURATION  = 730 days; // 2 years
    uint256 public constant VESTING_CLIFF     = 180 days; // 6 month cliff

    // ── State ──────────────────────────────────────────────
    address public owner;
    address public treasury;
    address public cryptvalt;

    uint256 public deployedAt;
    bool    public transfersPaused;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Vesting schedules
    struct VestingSchedule {
        uint256 total;
        uint256 released;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
        bool    revoked;
    }
    mapping(address => VestingSchedule) public vestingSchedules;

    // Staking
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakeTimestamp;
    mapping(address => uint256) public stakingRewards;
    uint256 public totalStaked;
    uint256 public rewardPerToken;
    mapping(address => uint256) public rewardDebt;

    // Burn tracking
    uint256 public totalBurned;

    // ── Events ─────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner_, address indexed spender, uint256 value);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardDeposited(uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event VestingCreated(address indexed beneficiary, uint256 total);
    event VestingReleased(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary);

    modifier onlyOwner()  { require(msg.sender == owner,    "Not owner");  _; }
    modifier notPaused()  { require(!transfersPaused,       "Paused");     _; }

    constructor(address _treasury) {
        owner      = msg.sender;
        treasury   = _treasury;
        deployedAt = block.timestamp;

        // Mint all tokens to owner for distribution
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);

        // Immediately allocate treasury
        _transfer(msg.sender, _treasury, TREASURY_ALLOC);

        // Liquidity to owner for DEX listing
        // (LIQUIDITY_ALLOC stays with owner)

        // Community rewards pool stays with owner until distributed
        // Team vesting set up separately via createVesting()
        // Ecosystem allocated via transfer as partnerships form
    }

    // ── ERC-20 ─────────────────────────────────────────────
    function totalSupply() external view returns (uint256) {
        return TOTAL_SUPPLY - totalBurned;
    }

    function transfer(address to, uint256 amount) external notPaused returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external notPaused returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "Insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }

    // ── Burn ───────────────────────────────────────────────
    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalBurned           += amount;
        emit Transfer(msg.sender, address(0), amount);
        emit Burned(msg.sender, amount);
    }

    // Platform burns tokens from fees — deflationary mechanism
    function burnFromFees(uint256 amount) external {
        require(msg.sender == cryptvalt || msg.sender == owner, "Not authorized");
        require(balanceOf[address(this)] >= amount, "Insufficient contract balance");
        balanceOf[address(this)] -= amount;
        totalBurned             += amount;
        emit Transfer(address(this), address(0), amount);
        emit Burned(address(this), amount);
    }

    // ── Staking ────────────────────────────────────────────
    function stake(uint256 amount) external notPaused {
        require(amount > 0,                         "Zero amount");
        require(balanceOf[msg.sender] >= amount,    "Insufficient balance");

        _claimReward(msg.sender);

        balanceOf[msg.sender]     -= amount;
        stakedBalance[msg.sender] += amount;
        totalStaked               += amount;
        stakeTimestamp[msg.sender] = block.timestamp;
        rewardDebt[msg.sender]     = rewardPerToken;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(stakedBalance[msg.sender] >= amount, "Insufficient staked");

        _claimReward(msg.sender);

        stakedBalance[msg.sender] -= amount;
        balanceOf[msg.sender]     += amount;
        totalStaked               -= amount;

        emit Unstaked(msg.sender, amount);
    }

    function claimStakingReward() external {
        _claimReward(msg.sender);
    }

    function _claimReward(address user) internal {
        uint256 pending = pendingReward(user);
        if (pending > 0) {
            stakingRewards[user]  = 0;
            rewardDebt[user]      = rewardPerToken;
            balanceOf[user]      += pending;
            balanceOf[address(this)] -= pending;
            emit Transfer(address(this), user, pending);
            emit RewardClaimed(user, pending);
        } else {
            rewardDebt[user] = rewardPerToken;
        }
    }

    function depositReward(uint256 amount) external {
        require(msg.sender == owner || msg.sender == cryptvalt, "Not authorized");
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        if (totalStaked > 0) {
            rewardPerToken += amount / totalStaked;
        }
        balanceOf[msg.sender]    -= amount;
        balanceOf[address(this)] += amount;
        emit RewardDeposited(amount);
    }

    function pendingReward(address user) public view returns (uint256) {
        if (stakedBalance[user] == 0) return 0;
        uint256 earned = stakedBalance[user] * (rewardPerToken - rewardDebt[user]);
        return earned + stakingRewards[user];
    }

    // ── Vesting ────────────────────────────────────────────
    function createVesting(
        address beneficiary,
        uint256 total,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external onlyOwner {
        require(beneficiary != address(0),                 "Zero address");
        require(vestingSchedules[beneficiary].total == 0,  "Already has vesting");
        require(balanceOf[msg.sender] >= total,            "Insufficient balance");

        balanceOf[msg.sender]        -= total;
        balanceOf[address(this)]     += total;

        vestingSchedules[beneficiary] = VestingSchedule({
            total:     total,
            released:  0,
            startTime: startTime > 0 ? startTime : block.timestamp,
            duration:  duration,
            cliff:     cliff,
            revoked:   false
        });

        emit VestingCreated(beneficiary, total);
    }

    function releaseVesting() external {
        VestingSchedule storage v = vestingSchedules[msg.sender];
        require(v.total > 0,   "No vesting schedule");
        require(!v.revoked,    "Vesting revoked");

        uint256 vested    = vestedAmount(msg.sender);
        uint256 releasable = vested - v.released;
        require(releasable > 0, "Nothing to release");

        v.released               += releasable;
        balanceOf[address(this)] -= releasable;
        balanceOf[msg.sender]    += releasable;

        emit Transfer(address(this), msg.sender, releasable);
        emit VestingReleased(msg.sender, releasable);
    }

    function vestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule storage v = vestingSchedules[beneficiary];
        if (v.total == 0 || v.revoked) return v.released;

        uint256 elapsed = block.timestamp - v.startTime;
        if (elapsed < v.cliff) return 0;
        if (elapsed >= v.duration) return v.total;

        return (v.total * elapsed) / v.duration;
    }

    function revokeVesting(address beneficiary) external onlyOwner {
        VestingSchedule storage v = vestingSchedules[beneficiary];
        require(!v.revoked, "Already revoked");

        uint256 vested    = vestedAmount(beneficiary);
        uint256 releasable = vested - v.released;
        uint256 unvested   = v.total - vested;

        if (releasable > 0) {
            v.released               += releasable;
            balanceOf[address(this)] -= releasable;
            balanceOf[beneficiary]   += releasable;
            emit VestingReleased(beneficiary, releasable);
        }

        if (unvested > 0) {
            balanceOf[address(this)] -= unvested;
            balanceOf[treasury]      += unvested;
        }

        v.revoked = true;
        emit VestingRevoked(beneficiary);
    }

    // ── Utility Functions ──────────────────────────────────
    function getFeeDiscount(address user) external view returns (uint256 discountBPS) {
        uint256 bal = balanceOf[user] + stakedBalance[user];
        if      (bal >= 100_000 * 10**18) return 5000; // 50% discount — 100k+ CVT
        else if (bal >= 50_000  * 10**18) return 3000; // 30% discount — 50k+ CVT
        else if (bal >= 10_000  * 10**18) return 2000; // 20% discount — 10k+ CVT
        else if (bal >= 1_000   * 10**18) return 1000; // 10% discount — 1k+ CVT
        else if (bal >= 100     * 10**18) return 500;  // 5% discount  — 100+ CVT
        return 0;
    }

    function getVotingPower(address user) external view returns (uint256) {
        // Staked tokens = 2x voting power, unstaked = 1x
        return balanceOf[user] + (stakedBalance[user] * 2);
    }

    // ── View ───────────────────────────────────────────────
    function getTokenStats() external view returns (
        uint256 supply, uint256 burned, uint256 staked,
        uint256 circulatingSupply
    ) {
        return (
            TOTAL_SUPPLY,
            totalBurned,
            totalStaked,
            TOTAL_SUPPLY - totalBurned - totalStaked
        );
    }

    function getStakeInfo(address user) external view returns (
        uint256 staked, uint256 pending, uint256 stakedAt
    ) {
        return (stakedBalance[user], pendingReward(user), stakeTimestamp[user]);
    }

    // ── Admin ──────────────────────────────────────────────
    function setCryptValt(address c) external onlyOwner { cryptvalt = c; }
    function pauseTransfers()  external onlyOwner { transfersPaused = true; }
    function unpauseTransfers() external onlyOwner { transfersPaused = false; }
    function updateTreasury(address t) external onlyOwner { treasury = t; }

    // Allow contract to receive ETH for reward distribution
    receive() external payable {}
}
