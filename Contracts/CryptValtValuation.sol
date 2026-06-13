// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract CryptValtValuation {

    address public owner;
    address public platform;

    uint256 public totalSales;
    uint256 public sentiment  = 10000;
    uint256 public demandIdx  = 9500;

    mapping(string  => uint256) public catMult;
    mapping(string  => uint256) public catAvg;
    mapping(string  => uint256) public catCount;
    mapping(uint256 => uint256) public valMid;
    mapping(uint256 => uint256) public valMin;
    mapping(uint256 => uint256) public valMax;

    event Sale(string cat, uint256 price);

    modifier onlyAuth() { require(msg.sender == platform || msg.sender == owner); _; }

    constructor(address _platform) {
        require(_platform != address(0));
        owner    = msg.sender;
        platform = _platform;
        catMult["tech"]     = 16000;
        catMult["health"]   = 19000;
        catMult["finance"]  = 17500;
        catMult["consumer"] = 12000;
        catMult["energy"]   = 14500;
        catMult["other"]    = 10000;
    }

    function recordSale(string calldata cat, uint256 price) external onlyAuth {
        catCount[cat]++;
        totalSales++;
        if (catAvg[cat] == 0) {
            catAvg[cat] = price;
        } else {
            catAvg[cat] = (catAvg[cat] * 8000 + price * 2000) / 10000;
        }
        emit Sale(cat, price);
    }

    function storeVal(uint256 id, uint256 lo, uint256 mid, uint256 hi) external onlyAuth {
        valMin[id] = lo;
        valMid[id] = mid;
        valMax[id] = hi;
    }

    function estimate(uint256 score, string calldata cat, uint256 mktSize)
        external view returns (uint256 lo, uint256 mid, uint256 hi)
    {
        mid = _calc(score, cat, mktSize);
        lo  = (mid * 6500) / 10000;
        hi  = (mid * 15000) / 10000;
    }

    function _calc(uint256 score, string calldata cat, uint256 mktSize) internal view returns (uint256) {
        uint256 v = (mktSize * 3000 / 10000 * 700 / 10000);
        v = (v * _mult(score)) / 10000;
        v = (v * (catMult[cat] > 0 ? catMult[cat] : 10000)) / 10000;
        v = (v * sentiment) / 10000;
        v = (v * demandIdx) / 10000;
        if (v < 5000) v = 5000;
        if (catCount[cat] >= 5) v = (v * 6500 + catAvg[cat] * 3500) / 10000;
        return v;
    }

    function _mult(uint256 s) internal pure returns (uint256) {
        if (s >= 90) return 35000;
        if (s >= 80) return 22000 + (s - 80) * 800;
        if (s >= 70) return 16500 + (s - 70) * 550;
        if (s >= 60) return 12500 + (s - 60) * 400;
        if (s >= 50) return  9500 + (s - 50) * 300;
        if (s >= 40) return  7500 + (s - 40) * 200;
        if (s >= 30) return  5500 + (s - 30) * 200;
        if (s >= 20) return  4000 + (s - 20) * 150;
        if (s >= 10) return  2750 + (s - 10) * 125;
        return 2500 + s * 25;
    }

    function getVal(uint256 id) external view returns (uint256, uint256, uint256) {
        return (valMin[id], valMid[id], valMax[id]);
    }

    function setCatMult(string calldata cat, uint256 mult) external { require(msg.sender == owner && mult >= 5000 && mult <= 30000); catMult[cat] = mult; }
    function setSentiment(uint256 val) external { require(msg.sender == owner && val >= 5000 && val <= 20000); sentiment = val; }
    function setDemand(uint256 val) external { require(msg.sender == owner && val >= 5000 && val <= 20000); demandIdx = val; }
    function updatePlatform(address p) external { require(msg.sender == owner); platform = p; }
}
