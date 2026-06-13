// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * CryptValt Membership NFT
 *
 * Three tiers:
 * - BRONZE  (1000 max) — Basic access, 5% fee discount
 * - GOLD    (500 max)  — Priority access, 10% fee discount, early listings
 * - PLATINUM (100 max) — VIP access, 15% fee discount, private auctions, revenue share
 *
 * Revenue share: 10% of all platform fees distributed to Platinum holders
 * Secondary sales: 10% royalty back to CryptValt treasury
 */

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract CryptValtMembership {

    string  public name     = "CryptValt Membership";
    string  public symbol   = "CVM";
    address public owner;
    address public treasury;

    uint256 public totalSupply;
    uint256 public totalRevenue;
    uint256 public unclaimedRevenue;

    // Tier prices in ETH
    uint256 public priceBronze   = 0.05 ether;
    uint256 public priceGold     = 0.15 ether;
    uint256 public pricePlatinum = 0.50 ether;

    // Tier supply caps
    uint256 public constant MAX_BRONZE   = 1000;
    uint256 public constant MAX_GOLD     = 500;
    uint256 public constant MAX_PLATINUM = 100;

    // Minted counts
    uint256 public mintedBronze;
    uint256 public mintedGold;
    uint256 public mintedPlatinum;

    // Tier IDs
    uint8 public constant BRONZE   = 1;
    uint8 public constant GOLD     = 2;
    uint8 public constant PLATINUM = 3;

    // Fee discounts in BPS
    uint256 public constant DISCOUNT_BRONZE   = 500;  // 5%
    uint256 public constant DISCOUNT_GOLD     = 1000; // 10%
    uint256 public constant DISCOUNT_PLATINUM = 1500; // 15%

    // Revenue share — Platinum gets 10% of platform fees
    uint256 public constant PLATINUM_SHARE_BPS = 1000;

    mapping(uint256 => address)  public ownerOf;
    mapping(address => uint256)  public balanceOf;
    mapping(uint256 => address)  public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => uint8)    public tierOf;
    mapping(address => uint256[]) public tokensOf;
    mapping(address => uint256)  public revenueOwed;
    mapping(address => uint256)  public revenueClaimed;
    mapping(uint256 => uint256)  public revenuePerTokenAtMint;

    uint256 private _revenuePerToken;
    uint256 private _nextTokenId = 1;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner_, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner_, address indexed operator, bool approved);
    event Minted(address indexed to, uint256 indexed tokenId, uint8 tier, uint256 price);
    event RevenueDeposited(uint256 amount, uint256 perToken);
    event RevenueClaimed(address indexed holder, uint256 amount);
    event TierPriceUpdated(uint8 tier, uint256 newPrice);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _treasury) {
        owner    = msg.sender;
        treasury = _treasury;
    }

    // ── Mint ───────────────────────────────────────────────
    function mintBronze() external payable {
        require(msg.value >= priceBronze,      "Low payment");
        require(mintedBronze < MAX_BRONZE,     "Sold out");
        _mint(msg.sender, BRONZE);
        mintedBronze++;
        _forwardPayment();
    }

    function mintGold() external payable {
        require(msg.value >= priceGold,        "Low payment");
        require(mintedGold < MAX_GOLD,         "Sold out");
        _mint(msg.sender, GOLD);
        mintedGold++;
        _forwardPayment();
    }

    function mintPlatinum() external payable {
        require(msg.value >= pricePlatinum,    "Low payment");
        require(mintedPlatinum < MAX_PLATINUM, "Sold out");
        _mint(msg.sender, PLATINUM);
        mintedPlatinum++;
        _forwardPayment();
    }

    function _mint(address to, uint8 tier) internal {
        uint256 id = _nextTokenId++;
        ownerOf[id]   = to;
        tierOf[id]    = tier;
        balanceOf[to]++;
        totalSupply++;
        tokensOf[to].push(id);
        revenuePerTokenAtMint[id] = _revenuePerToken;
        emit Transfer(address(0), to, id);
        emit Minted(to, id, tier, msg.value);
    }

    function _forwardPayment() internal {
        uint256 amt = msg.value;
        // 90% to treasury, 10% to revenue pool for Platinum holders
        uint256 toPool    = (amt * PLATINUM_SHARE_BPS) / 10000;
        uint256 toTreasury = amt - toPool;

        if (mintedPlatinum > 0 && toPool > 0) {
            _revenuePerToken += toPool / mintedPlatinum;
            unclaimedRevenue += toPool;
            totalRevenue     += toPool;
            emit RevenueDeposited(toPool, _revenuePerToken);
        } else {
            toTreasury = amt;
        }

        (bool ok,) = payable(treasury).call{value: toTreasury}("");
        require(ok, "Treasury transfer failed");
    }

    // ── Revenue Distribution ───────────────────────────────
    function depositRevenue() external payable {
        require(msg.value > 0, "No value");
        if (mintedPlatinum > 0) {
            uint256 perToken  = msg.value / mintedPlatinum;
            _revenuePerToken += perToken;
            unclaimedRevenue += msg.value;
            totalRevenue     += msg.value;
            emit RevenueDeposited(msg.value, _revenuePerToken);
        } else {
            (bool ok,) = payable(treasury).call{value: msg.value}("");
            require(ok);
        }
    }

    function claimRevenue() external {
        uint256 owed = pendingRevenue(msg.sender);
        require(owed > 0, "Nothing to claim");
        revenueClaimed[msg.sender] += owed;
        unclaimedRevenue           -= owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        require(ok, "Transfer failed");
        emit RevenueClaimed(msg.sender, owed);
    }

    function pendingRevenue(address holder) public view returns (uint256 total) {
        uint256[] memory tokens = tokensOf[holder];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tierOf[tokens[i]] == PLATINUM) {
                uint256 earned = _revenuePerToken - revenuePerTokenAtMint[tokens[i]];
                total += earned;
            }
        }
        if (total > revenueClaimed[holder]) {
            total -= revenueClaimed[holder];
        } else {
            total = 0;
        }
    }

    // ── Membership Benefits ────────────────────────────────
    function hasMembership(address wallet) external view returns (bool) {
        return balanceOf[wallet] > 0;
    }

    function getHighestTier(address wallet) external view returns (uint8 tier) {
        uint256[] memory tokens = tokensOf[wallet];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tierOf[tokens[i]] > tier) tier = tierOf[tokens[i]];
        }
    }

    function getFeeDiscount(address wallet) external view returns (uint256) {
        uint256[] memory tokens = tokensOf[wallet];
        uint8 highest;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tierOf[tokens[i]] > highest) highest = tierOf[tokens[i]];
        }
        if (highest == PLATINUM) return DISCOUNT_PLATINUM;
        if (highest == GOLD)     return DISCOUNT_GOLD;
        if (highest == BRONZE)   return DISCOUNT_BRONZE;
        return 0;
    }

    function getTierName(uint8 tier) external pure returns (string memory) {
        if (tier == PLATINUM) return "PLATINUM";
        if (tier == GOLD)     return "GOLD";
        if (tier == BRONZE)   return "BRONZE";
        return "NONE";
    }

    // ── ERC721 Transfer ────────────────────────────────────
    function transferFrom(address from, address to, uint256 tokenId) public {
        require(ownerOf[tokenId] == from,                              "Not owner");
        require(to != address(0),                                      "Zero address");
        require(msg.sender == from || getApproved[tokenId] == msg.sender || isApprovedForAll[from][msg.sender], "Not approved");

        // Handle revenue on transfer
        uint256 pending = _pendingForToken(tokenId);
        if (pending > 0 && tierOf[tokenId] == PLATINUM) {
            revenuePerTokenAtMint[tokenId] = _revenuePerToken;
        }

        balanceOf[from]--;
        balanceOf[to]++;
        ownerOf[tokenId]     = to;
        getApproved[tokenId] = address(0);

        _removeToken(from, tokenId);
        tokensOf[to].push(tokenId);

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
            require(ret == IERC721Receiver.onERC721Received.selector);
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external {
        transferFrom(from, to, tokenId);
    }

    function approve(address approved, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender || isApprovedForAll[ownerOf[tokenId]][msg.sender]);
        getApproved[tokenId] = approved;
        emit Approval(ownerOf[tokenId], approved, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function _removeToken(address from, uint256 tokenId) internal {
        uint256[] storage tokens = tokensOf[from];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == tokenId) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }
    }

    function _pendingForToken(uint256 tokenId) internal view returns (uint256) {
        if (tierOf[tokenId] != PLATINUM) return 0;
        return _revenuePerToken - revenuePerTokenAtMint[tokenId];
    }

    // ── View ───────────────────────────────────────────────
    function getStats() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (totalSupply, mintedBronze, mintedGold, mintedPlatinum, totalRevenue);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7;
    }

    // ── Admin ──────────────────────────────────────────────
    function setPrices(uint256 bronze, uint256 gold, uint256 platinum) external onlyOwner {
        priceBronze   = bronze;
        priceGold     = gold;
        pricePlatinum = platinum;
    }

    function adminMint(address to, uint8 tier) external onlyOwner {
        if (tier == BRONZE)   { require(mintedBronze   < MAX_BRONZE);   mintedBronze++;   }
        if (tier == GOLD)     { require(mintedGold     < MAX_GOLD);     mintedGold++;     }
        if (tier == PLATINUM) { require(mintedPlatinum < MAX_PLATINUM); mintedPlatinum++; }
        _mint(to, tier);
    }

    function updateTreasury(address t) external onlyOwner { treasury = t; }

    receive() external payable { }
}
