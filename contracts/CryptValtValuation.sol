// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                        CRYPTVALT VALUATION v2.0
              On-Chain Idea Valuation Oracle — OZ Edition
//////////////////////////////////////////////////////////////////////////*/

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CryptValt Valuation Oracle
/// @author CryptValt
/// @notice Estimates idea valuations from AI score, category, and
///         market size; learns from realized sale prices via an
///         exponential moving average per category.
/// @dev v2.0 modernization on OpenZeppelin Ownable2Step (Safe-ready).
///      Logic unchanged from v1 (holds no funds; audit found no
///      issues); adds custom errors.
contract CryptValtValuation is Ownable2Step {

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NotAuthorized();
    error EmptyCategory();
    error ZeroPrice();
    error InvalidRange();
    error ScoreTooHigh();
    error InvalidMultiplier();
    error InvalidSentiment();
    error InvalidDemand();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    address public platform;

    uint256 public totalSales;
    uint256 public sentiment = 10_000;
    uint256 public demandIdx = 9_500;

    mapping(string  => uint256) public catMult;
    mapping(string  => uint256) public catAvg;
    mapping(string  => uint256) public catCount;
    mapping(uint256 => uint256) public valMid;
    mapping(uint256 => uint256) public valMin;
    mapping(uint256 => uint256) public valMax;

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event Sale(string indexed cat, uint256 price);
    event CatMultiplierUpdated(string indexed cat, uint256 oldMult, uint256 newMult);
    event SentimentUpdated(uint256 oldVal, uint256 newVal);
    event DemandUpdated(uint256 oldVal, uint256 newVal);
    event PlatformUpdated(address indexed oldPlatform, address indexed newPlatform);
    event ValuationStored(uint256 indexed id, uint256 lo, uint256 mid, uint256 hi);

    /*////////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    modifier onlyAuth() {
        if (msg.sender != platform && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param initialOwner Deployer/admin — transfer to the Safe via
    ///                     transferOwnership + acceptOwnership.
    /// @param _platform    The CryptValt core contract address.
    constructor(address initialOwner, address _platform) Ownable(initialOwner) {
        if (_platform == address(0)) revert ZeroAddress();
        platform = _platform;
        catMult["tech"]     = 16_000;
        catMult["health"]   = 19_000;
        catMult["finance"]  = 17_500;
        catMult["consumer"] = 12_000;
        catMult["energy"]   = 14_500;
        catMult["other"]    = 10_000;
    }

    /*////////////////////////////////////////////////////////////////
                            RECORDING & STORAGE
    ////////////////////////////////////////////////////////////////*/

    /// @notice Record a realized sale; updates the category's EMA
    ///         (80% history / 20% new price).
    function recordSale(string calldata cat, uint256 price) external onlyAuth {
        if (bytes(cat).length == 0) revert EmptyCategory();
        if (price == 0) revert ZeroPrice();
        catCount[cat]++;
        totalSales++;
        if (catAvg[cat] == 0) {
            catAvg[cat] = price;
        } else {
            catAvg[cat] = (catAvg[cat] * 8_000 + price * 2_000) / 10_000;
        }
        emit Sale(cat, price);
    }

    /// @notice Store an off-chain computed valuation range for a
    ///         listing.
    function storeVal(uint256 id, uint256 lo, uint256 mid, uint256 hi) external onlyAuth {
        if (lo > mid || mid > hi) revert InvalidRange();
        valMin[id] = lo;
        valMid[id] = mid;
        valMax[id] = hi;
        emit ValuationStored(id, lo, mid, hi);
    }

    /*////////////////////////////////////////////////////////////////
                               ESTIMATION
    ////////////////////////////////////////////////////////////////*/

    /// @notice Estimate a valuation range for an idea.
    /// @param score   AI quality score (0–100)
    /// @param cat     Category key (e.g. "tech")
    /// @param mktSize Addressable market size in wei-denominated USD
    function estimate(uint256 score, string calldata cat, uint256 mktSize)
        external view returns (uint256 lo, uint256 mid, uint256 hi)
    {
        if (score > 100) revert ScoreTooHigh();
        if (bytes(cat).length == 0) revert EmptyCategory();
        mid = _calc(score, cat, mktSize);
        lo  = (mid * 6_500)  / 10_000;
        hi  = (mid * 15_000) / 10_000;
    }

    function _calc(uint256 score, string calldata cat, uint256 mktSize)
        internal view returns (uint256)
    {
        uint256 v = (mktSize * 3_000 / 10_000 * 700 / 10_000);
        v = (v * _mult(score)) / 10_000;
        v = (v * (catMult[cat] > 0 ? catMult[cat] : 10_000)) / 10_000;
        v = (v * sentiment) / 10_000;
        v = (v * demandIdx) / 10_000;
        if (v < 5_000) v = 5_000;
        if (catCount[cat] >= 5) v = (v * 6_500 + catAvg[cat] * 3_500) / 10_000;
        return v;
    }

    /// @dev Score→multiplier curve (steeper rewards at higher scores).
    function _mult(uint256 s) internal pure returns (uint256) {
        if (s >= 90) return 35_000;
        if (s >= 80) return 22_000 + (s - 80) * 800;
        if (s >= 70) return 16_500 + (s - 70) * 550;
        if (s >= 60) return 12_500 + (s - 60) * 400;
        if (s >= 50) return  9_500 + (s - 50) * 300;
        if (s >= 40) return  7_500 + (s - 40) * 200;
        if (s >= 30) return  5_500 + (s - 30) * 200;
        if (s >= 20) return  4_000 + (s - 20) * 150;
        if (s >= 10) return  2_750 + (s - 10) * 125;
        return 2_500 + s * 25;
    }

    /*////////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function getVal(uint256 id) external view returns (uint256, uint256, uint256) {
        return (valMin[id], valMid[id], valMax[id]);
    }

    /*////////////////////////////////////////////////////////////////
                                  ADMIN
    ////////////////////////////////////////////////////////////////*/

    function setCatMult(string calldata cat, uint256 mult) external onlyOwner {
        if (bytes(cat).length == 0) revert EmptyCategory();
        if (mult < 5_000 || mult > 30_000) revert InvalidMultiplier();
        uint256 old = catMult[cat];
        catMult[cat] = mult;
        emit CatMultiplierUpdated(cat, old, mult);
    }

    function setSentiment(uint256 val) external onlyOwner {
        if (val < 5_000 || val > 20_000) revert InvalidSentiment();
        uint256 old = sentiment;
        sentiment = val;
        emit SentimentUpdated(old, val);
    }

    function setDemand(uint256 val) external onlyOwner {
        if (val < 5_000 || val > 20_000) revert InvalidDemand();
        uint256 old = demandIdx;
        demandIdx = val;
        emit DemandUpdated(old, val);
    }

    function updatePlatform(address p) external onlyOwner {
        if (p == address(0)) revert ZeroAddress();
        address old = platform;
        platform = p;
        emit PlatformUpdated(old, p);
    }
}
