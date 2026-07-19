// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                            CRYPTVALT TOKEN (CVT) v2.0
                 ERC-20 + Permit + Staking + Vesting — OZ Edition
//////////////////////////////////////////////////////////////////////////*/

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CryptValt Token (CVT)
/// @author CryptValt
/// @notice Platform utility token: fee discounts, staking rewards,
///        vesting schedules, and DAO voting power.
/// @dev v2.0 hardened release, built on OpenZeppelin audited bases:
///      - ERC20 + ERC20Permit (EIP-2612 gasless approvals) + ERC20Burnable
///      - Ownable2Step: two-step ownership transfer (Safe-ready)
///      - Pausable transfer freeze, ReentrancyGuard on state-heavy ops
///      Security fixes over v1:
///      - STAKING PRECISION FIX: reward accumulator scaled by 1e18 so
///        rewards no longer round to zero (v1 divided two 18-decimal
///        values directly, losing all precision)
///      - Vesting escrow held by the contract itself (unchanged), with
///        revocation returning unvested funds to treasury
contract CryptValtToken is ERC20, ERC20Permit, ERC20Burnable, Ownable2Step, Pausable, ReentrancyGuard {

    /*////////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////////*/

    uint256 public constant TOTAL_SUPPLY    = 100_000_000e18;
    uint256 public constant COMMUNITY_ALLOC = 40_000_000e18;
    uint256 public constant TEAM_ALLOC      = 20_000_000e18;
    uint256 public constant TREASURY_ALLOC  = 15_000_000e18;
    uint256 public constant ECOSYSTEM_ALLOC = 15_000_000e18;
    uint256 public constant LIQUIDITY_ALLOC = 10_000_000e18;

    /// @dev Precision scalar for the staking reward accumulator.
    uint256 private constant ACC_PRECISION = 1e18;

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStaked();
    error NoStakers();
    error NotAuthorized();
    error AlreadyVesting();
    error NoVesting();
    error VestingRevokedErr();
    error NothingToRelease();
    error AlreadyRevoked();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    address public treasury;
    address public cryptvalt;
    uint256 public deployedAt;

    // ── Staking ──
    uint256 public totalStaked;
    /// @dev Scaled by ACC_PRECISION (v2.0 precision fix).
    uint256 public accRewardPerShare;
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakeTimestamp;
    mapping(address => uint256) public rewardDebt;

    // ── Vesting ──
    struct VestingSchedule {
        uint256 total;
        uint256 released;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
        bool    revoked;
    }
    mapping(address => VestingSchedule) public vestingSchedules;

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardDeposited(address indexed from, uint256 amount);
    event VestingCreated(address indexed beneficiary, uint256 total);
    event VestingReleased(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 returnedToTreasury);
    event TreasuryUpdated(address indexed newTreasury);
    event CryptValtSet(address indexed cryptvalt);

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param initialOwner Deployer/admin — transfer to the Safe via
    ///                     transferOwnership + acceptOwnership.
    /// @param _treasury    Treasury address (receives TREASURY_ALLOC and
    ///                     revoked vesting funds).
    constructor(address initialOwner, address _treasury)
        ERC20("CryptValt Token", "CVT")
        ERC20Permit("CryptValt Token")
        Ownable(initialOwner)
    {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury   = _treasury;
        deployedAt = block.timestamp;
        _mint(initialOwner, TOTAL_SUPPLY - TREASURY_ALLOC);
        _mint(_treasury, TREASURY_ALLOC);
    }

    /*////////////////////////////////////////////////////////////////
                                 STAKING
    ////////////////////////////////////////////////////////////////*/

    /// @notice Stake CVT to earn a share of deposited rewards and boost
    ///         DAO voting power (staked tokens count double).
    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _claimReward(msg.sender);
        _transfer(msg.sender, address(this), amount);
        stakedBalance[msg.sender] += amount;
        totalStaked               += amount;
        stakeTimestamp[msg.sender] = block.timestamp;
        rewardDebt[msg.sender]     = (stakedBalance[msg.sender] * accRewardPerShare) / ACC_PRECISION;
        emit Staked(msg.sender, amount);
    }

    /// @notice Unstake CVT (claims pending rewards first).
    function unstake(uint256 amount) external nonReentrant {
        if (stakedBalance[msg.sender] < amount) revert InsufficientStaked();
        _claimReward(msg.sender);
        stakedBalance[msg.sender] -= amount;
        totalStaked               -= amount;
        rewardDebt[msg.sender]     = (stakedBalance[msg.sender] * accRewardPerShare) / ACC_PRECISION;
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Claim accumulated staking rewards.
    function claimStakingReward() external nonReentrant {
        _claimReward(msg.sender);
        rewardDebt[msg.sender] = (stakedBalance[msg.sender] * accRewardPerShare) / ACC_PRECISION;
    }

    /// @dev MasterChef-style settlement with 1e18 scaling (v2.0 fix).
    function _claimReward(address user) internal {
        uint256 pending = pendingReward(user);
        if (pending > 0) {
            _transfer(address(this), user, pending);
            emit RewardClaimed(user, pending);
        }
    }

    /// @notice Deposit CVT as staking rewards (platform or owner only).
    /// @dev v2.0 precision fix: accumulator is scaled by 1e18 before the
    ///      division so small deposits no longer round to zero.
    function depositReward(uint256 amount) external nonReentrant {
        if (msg.sender != owner() && msg.sender != cryptvalt) revert NotAuthorized();
        if (amount == 0)      revert ZeroAmount();
        if (totalStaked == 0) revert NoStakers();
        _transfer(msg.sender, address(this), amount);
        accRewardPerShare += (amount * ACC_PRECISION) / totalStaked;
        emit RewardDeposited(msg.sender, amount);
    }

    /// @notice Pending (unclaimed) staking rewards for a user.
    function pendingReward(address user) public view returns (uint256) {
        if (stakedBalance[user] == 0) return 0;
        uint256 accumulated = (stakedBalance[user] * accRewardPerShare) / ACC_PRECISION;
        return accumulated > rewardDebt[user] ? accumulated - rewardDebt[user] : 0;
    }

    /*////////////////////////////////////////////////////////////////
                                 VESTING
    ////////////////////////////////////////////////////////////////*/

    /// @notice Create a linear vesting schedule with cliff. Tokens are
    ///         escrowed in this contract until released.
    function createVesting(
        address beneficiary,
        uint256 total,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    ) external onlyOwner {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (total == 0)                revert ZeroAmount();
        if (vestingSchedules[beneficiary].total != 0) revert AlreadyVesting();

        _transfer(msg.sender, address(this), total);
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

    /// @notice Release your vested tokens.
    function releaseVesting() external nonReentrant {
        VestingSchedule storage v = vestingSchedules[msg.sender];
        if (v.total == 0) revert NoVesting();
        if (v.revoked)    revert VestingRevokedErr();

        uint256 releasable = vestedAmount(msg.sender) - v.released;
        if (releasable == 0) revert NothingToRelease();

        v.released += releasable;
        _transfer(address(this), msg.sender, releasable);
        emit VestingReleased(msg.sender, releasable);
    }

    /// @notice Linearly vested amount (0 before cliff, full after
    ///         duration).
    function vestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule storage v = vestingSchedules[beneficiary];
        if (v.total == 0 || v.revoked) return v.released;
        uint256 elapsed = block.timestamp - v.startTime;
        if (elapsed < v.cliff)     return 0;
        if (elapsed >= v.duration) return v.total;
        return (v.total * elapsed) / v.duration;
    }

    /// @notice Revoke a vesting schedule: vested portion goes to the
    ///         beneficiary, unvested returns to treasury.
    function revokeVesting(address beneficiary) external onlyOwner nonReentrant {
        VestingSchedule storage v = vestingSchedules[beneficiary];
        if (v.total == 0) revert NoVesting();
        if (v.revoked)    revert AlreadyRevoked();

        uint256 vested     = vestedAmount(beneficiary);
        uint256 releasable = vested - v.released;
        uint256 unvested   = v.total - vested;

        v.revoked = true;

        if (releasable > 0) {
            v.released += releasable;
            _transfer(address(this), beneficiary, releasable);
            emit VestingReleased(beneficiary, releasable);
        }
        if (unvested > 0) {
            _transfer(address(this), treasury, unvested);
        }
        emit VestingRevoked(beneficiary, unvested);
    }

    /*////////////////////////////////////////////////////////////////
                        PLATFORM UTILITY VIEWS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Fee discount tier (basis points) by combined held+staked
    ///         balance.
    function getFeeDiscount(address user) external view returns (uint256 discountBPS) {
        uint256 bal = balanceOf(user) + stakedBalance[user];
        if      (bal >= 100_000e18) return 5000;
        else if (bal >= 50_000e18)  return 3000;
        else if (bal >= 10_000e18)  return 2000;
        else if (bal >= 1_000e18)   return 1000;
        else if (bal >= 100e18)     return 500;
        return 0;
    }

    /// @notice DAO voting power: balance + 2× staked.
    function getVotingPower(address user) external view returns (uint256) {
        return balanceOf(user) + (stakedBalance[user] * 2);
    }

    function getTokenStats()
        external view
        returns (uint256 supply, uint256 staked, uint256 circulating)
    {
        return (totalSupply(), totalStaked, totalSupply() - totalStaked);
    }

    function getStakeInfo(address user)
        external view
        returns (uint256 staked, uint256 pending, uint256 stakedAt)
    {
        return (stakedBalance[user], pendingReward(user), stakeTimestamp[user]);
    }

    /*////////////////////////////////////////////////////////////////
                                  ADMIN
    ////////////////////////////////////////////////////////////////*/

    /// @notice Burn CVT held by this contract (fee-burn mechanism).
    function burnFromFees(uint256 amount) external {
        if (msg.sender != owner() && msg.sender != cryptvalt) revert NotAuthorized();
        _burn(address(this), amount);
    }

    function setCryptValt(address c) external onlyOwner {
        if (c == address(0)) revert ZeroAddress();
        cryptvalt = c;
        emit CryptValtSet(c);
    }

    function updateTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function pauseTransfers() external onlyOwner { _pause(); }
    function unpauseTransfers() external onlyOwner { _unpause(); }

    /// @dev OZ v5 transfer hook — enforces pause on user transfers while
    ///      still allowing mint/burn and this contract's own escrow moves
    ///      (staking, vesting) to proceed.
    function _update(address from, address to, uint256 value) internal override {
        if (paused() && from != address(0) && to != address(0)
            && from != address(this) && to != address(this)) {
            revert EnforcedPause();
        }
        super._update(from, to, value);
    }
}
