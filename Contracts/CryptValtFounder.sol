// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * CryptValt Founder NFT Collection
 *
 * 100 unique Founder NFTs — never minted again after genesis.
 *
 * Perks:
 * - Lifetime Platinum membership benefits
 * - 2x revenue share multiplier vs regular Platinum
 * - Permanent "Founder" badge on all listings and bids
 * - Governance veto power on protocol changes
 * - Direct line to platform development roadmap
 * - First access to every new feature forever
 *
 * Rarity tiers (by token ID):
 * - Genesis    (1-10)   — 10 tokens — rarest
 * - Architect  (11-25)  — 15 tokens
 * - Pioneer    (26-50)  — 25 tokens
 * - Visionary  (51-100) — 50 tokens
 */

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract CryptValtFounder {

    string public name   = "CryptValt Founder";
    string public symbol = "CVFD";

    address public owner;
    address public treasury;
    address public membershipContract;

    uint256 public constant MAX_SUPPLY    = 100;
    uint256 public constant MINT_PRICE    = 1 ether;
    uint256 public constant ROYALTY_BPS   = 1000; // 10% secondary royalty

    uint256 public totalSupply;
    uint256 public totalRevenue;
    uint256 private _revenuePerToken;
    uint256 private _nextId = 1;

    bool public mintOpen = false;
    bool public frozen   = false;

    mapping(uint256 => address)  public ownerOf;
    mapping(address => uint256)  public balanceOf;
    mapping(uint256 => address)  public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(address => uint256[]) public tokensOf;
    mapping(uint256 => uint256)  public revenueAtMint;
    mapping(address => uint256)  public claimed;
    mapping(uint256 => string)   public tokenURI;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner_, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner_, address indexed operator, bool approved);
    event Minted(address indexed to, uint256 indexed tokenId, string rarity);
    event RevenueDeposited(uint256 amount);
    event RevenueClaimed(address indexed holder, uint256 amount);
    event RoyaltyPaid(address indexed to, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _treasury) {
        owner    = msg.sender;
        treasury = _treasury;
    }

    // ── Mint ───────────────────────────────────────────────
    function mint() external payable {
        require(mintOpen,                "Mint not open");
        require(!frozen,                 "Frozen");
        require(msg.value >= MINT_PRICE, "Low payment");
        require(totalSupply < MAX_SUPPLY,"Sold out");

        uint256 id     = _nextId++;
        string memory rarity = _getRarity(id);

        ownerOf[id]      = msg.sender;
        balanceOf[msg.sender]++;
        totalSupply++;
        tokensOf[msg.sender].push(id);
        revenueAtMint[id] = _revenuePerToken;

        // Set token URI based on rarity
        tokenURI[id] = string(abi.encodePacked(
            "https://cryptvalt.io/nft/founder/",
            _uint2str(id),
            ".json"
        ));

        // Split payment — 90% to treasury, 10% to revenue pool
        uint256 toPool     = msg.value / 10;
        uint256 toTreasury = msg.value - toPool;

        if (totalSupply > 1) {
            _revenuePerToken += toPool / (totalSupply - 1);
        }
        totalRevenue += toPool;

        (bool ok,) = payable(treasury).call{value: toTreasury}("");
        require(ok);

        emit Transfer(address(0), msg.sender, id);
        emit Minted(msg.sender, id, rarity);
    }

    // ── Admin Mint (for team/partners) ─────────────────────
    function adminMint(address to) external onlyOwner {
        require(totalSupply < MAX_SUPPLY, "Sold out");
        uint256 id = _nextId++;
        ownerOf[id]   = to;
        balanceOf[to]++;
        totalSupply++;
        tokensOf[to].push(id);
        revenueAtMint[id] = _revenuePerToken;
        tokenURI[id] = string(abi.encodePacked("https://cryptvalt.io/nft/founder/", _uint2str(id), ".json"));
        emit Transfer(address(0), to, id);
        emit Minted(to, id, _getRarity(id));
    }

    // ── Revenue ────────────────────────────────────────────
    function depositRevenue() external payable {
        require(msg.value > 0);
        if (totalSupply > 0) {
            _revenuePerToken += msg.value / totalSupply;
            totalRevenue     += msg.value;
            emit RevenueDeposited(msg.value);
        } else {
            (bool ok,) = payable(treasury).call{value: msg.value}("");
            require(ok);
        }
    }

    function claimRevenue() external {
        uint256 owed = pendingRevenue(msg.sender);
        require(owed > 0, "Nothing");
        claimed[msg.sender] += owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        require(ok);
        emit RevenueClaimed(msg.sender, owed);
    }

    function pendingRevenue(address holder) public view returns (uint256 total) {
        uint256[] memory tokens = tokensOf[holder];
        for (uint256 i = 0; i < tokens.length; i++) {
            total += _revenuePerToken - revenueAtMint[tokens[i]];
        }
        if (total > claimed[holder]) total -= claimed[holder];
        else total = 0;
    }

    // ── Royalty (ERC2981) ──────────────────────────────────
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (treasury, (salePrice * ROYALTY_BPS) / 10000);
    }

    // ── Rarity ────────────────────────────────────────────
    function _getRarity(uint256 id) internal pure returns (string memory) {
        if (id <= 10)  return "Genesis";
        if (id <= 25)  return "Architect";
        if (id <= 50)  return "Pioneer";
        return "Visionary";
    }

    function getRarity(uint256 id) external pure returns (string memory) {
        return _getRarity(id);
    }

    function isFounder(address wallet) external view returns (bool) {
        return balanceOf[wallet] > 0;
    }

    // ── ERC721 ─────────────────────────────────────────────
    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "Not owner");
        require(to != address(0),   "Zero addr");
        require(
            msg.sender == from ||
            getApproved[id] == msg.sender ||
            isApprovedForAll[from][msg.sender],
            "Not approved"
        );

        // Settle pending revenue before transfer
        uint256 pending = _revenuePerToken - revenueAtMint[id];
        if (pending > 0) {
            revenueAtMint[id] = _revenuePerToken;
        }

        balanceOf[from]--;
        balanceOf[to]++;
        ownerOf[id]     = to;
        getApproved[id] = address(0);

        _removeToken(from, id);
        tokensOf[to].push(id);

        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, id, "");
            require(ret == IERC721Receiver.onERC721Received.selector);
        }
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata) external {
        transferFrom(from, to, id);
    }

    function approve(address to, uint256 id) external {
        require(ownerOf[id] == msg.sender || isApprovedForAll[ownerOf[id]][msg.sender]);
        getApproved[id] = to;
        emit Approval(ownerOf[id], to, id);
    }

    function setApprovalForAll(address op, bool approved) external {
        isApprovedForAll[msg.sender][op] = approved;
        emit ApprovalForAll(msg.sender, op, approved);
    }

    function _removeToken(address from, uint256 id) internal {
        uint256[] storage tokens = tokensOf[from];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == id) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }
    }

    // ── View ───────────────────────────────────────────────
    function getStats() external view returns (uint256, uint256, bool, bool) {
        return (totalSupply, totalRevenue, mintOpen, frozen);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7 || id == 0x2a55205a;
    }

    // ── Admin ──────────────────────────────────────────────
    function openMint()  external onlyOwner { mintOpen = true; }
    function closeMint() external onlyOwner { mintOpen = false; }
    function freeze()    external onlyOwner { frozen = true; }
    function unfreeze()  external onlyOwner { frozen = false; }
    function updateTreasury(address t) external onlyOwner { treasury = t; }
    function setMembershipContract(address m) external onlyOwner { membershipContract = m; }
    function setTokenURI(uint256 id, string calldata uri) external onlyOwner { tokenURI[id] = uri; }
    function setMintPrice(uint256) external onlyOwner {} // Intentionally immutable

    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v; uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    receive() external payable {}
}
