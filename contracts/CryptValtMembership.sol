// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                      CRYPTVALT MEMBERSHIP NFT (CVM) v2.0
            Tiered ERC-721 + EIP-2981 + Platinum Revenue — OZ Edition
//////////////////////////////////////////////////////////////////////////*/

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CryptValt Membership NFT (CVM)
/// @author CryptValt
/// @notice Tiered membership passes (Silver / Gold / Platinum) granting
///         platform fee discounts. Platinum holders share in platform
///         revenue deposits pro-rata.
/// @dev v2.0 hardened release on OpenZeppelin audited bases:
///      - ERC721 + ERC721Enumerable, ERC2981 royalties, Ownable2Step
///      Security fixes over v1:
///      - SELF-REVENUE FIX: a Platinum minter's baseline snapshot is
///        taken BEFORE their own mint payment enters the revenue pool,
///        and the pool divides among Platinum tokens minted before
///        theirs — no earning a slice of your own payment
///      - Pull-pattern claims; transfers no longer force-settle to the
///        seller (pending revenue stays with the token's claim record,
///        priced into the sale — simpler and griefing-proof)
contract CryptValtMembership is ERC721, ERC721Enumerable, ERC2981, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    /*////////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////////*/

    uint8 public constant TIER_SILVER   = 1;
    uint8 public constant TIER_GOLD     = 2;
    uint8 public constant TIER_PLATINUM = 3;

    uint96  public constant ROYALTY_BPS      = 500;   // 5%
    uint256 public constant HOLDER_SHARE_BPS = 1000;  // 10% of Platinum mints
    uint256 public constant BPS              = 10_000;

    /// @dev Precision scalar for the revenue accumulator.
    uint256 private constant ACC_PRECISION = 1e18;

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error MintClosed();
    error BadTier();
    error LowPayment();
    error TierSoldOut();
    error ZeroAddress();
    error ZeroAmount();
    error NothingOwed();
    error TransferFailed();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    address public treasury;
    bool    public mintOpen;
    uint256 private _nextId = 1;
    uint256 public totalRevenue;

    mapping(uint8 => uint256) public tierPrice;
    mapping(uint8 => uint256) public tierMaxSupply;
    mapping(uint8 => uint256) public tierMinted;
    mapping(uint8 => uint256) public tierDiscountBps;
    mapping(uint256 => uint8) public tierOf;

    // ── Platinum revenue share ──
    uint256 public platinumCount;
    /// @dev Revenue accumulator per Platinum token, scaled by 1e18.
    uint256 private _accRevenuePerPlatinum;
    mapping(uint256 => uint256) public revenueBaselineOf;
    mapping(uint256 => uint256) public claimedOf;

    string private _baseTokenURI = "https://cryptvalt.io/nft/membership/";

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event Minted(address indexed to, uint256 indexed tokenId, uint8 tier);
    event RevenueDeposited(address indexed from, uint256 amount);
    event RevenueClaimed(address indexed holder, uint256 indexed tokenId, uint256 amount);
    event MintOpenSet(bool open);
    event TierConfigured(uint8 indexed tier, uint256 price, uint256 maxSupply, uint256 discountBps);
    event TreasuryUpdated(address indexed newTreasury);
    event BaseURIUpdated(string newBase);

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param initialOwner Deployer/admin — transfer to the Safe via
    ///                     transferOwnership + acceptOwnership.
    /// @param _treasury    Receives mint revenue net of holder share.
    constructor(address initialOwner, address _treasury)
        ERC721("CryptValt Membership", "CVM")
        Ownable(initialOwner)
    {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        _setDefaultRoyalty(_treasury, ROYALTY_BPS);

        tierPrice[TIER_SILVER]      = 0.05 ether;
        tierPrice[TIER_GOLD]        = 0.15 ether;
        tierPrice[TIER_PLATINUM]    = 0.5 ether;
        tierMaxSupply[TIER_SILVER]  = 5000;
        tierMaxSupply[TIER_GOLD]    = 1000;
        tierMaxSupply[TIER_PLATINUM]= 200;
        tierDiscountBps[TIER_SILVER]   = 1000; // 10%
        tierDiscountBps[TIER_GOLD]     = 2500; // 25%
        tierDiscountBps[TIER_PLATINUM] = 5000; // 50%
    }

    /*////////////////////////////////////////////////////////////////
                                 MINTING
    ////////////////////////////////////////////////////////////////*/

    /// @notice Mint a membership pass of the given tier.
    /// @dev v2.0 SELF-REVENUE FIX: for Platinum mints, the baseline is
    ///      snapshotted BEFORE this mint's holder share is added, and
    ///      the share divides by the pre-mint Platinum count.
    function mint(uint8 tier) external payable nonReentrant {
        if (!mintOpen) revert MintClosed();
        if (tier < TIER_SILVER || tier > TIER_PLATINUM) revert BadTier();
        if (msg.value < tierPrice[tier]) revert LowPayment();
        if (tierMinted[tier] >= tierMaxSupply[tier]) revert TierSoldOut();

        uint256 id = _nextId++;
        tierMinted[tier]++;
        tierOf[id] = tier;

        uint256 toTreasury = msg.value;

        if (tier == TIER_PLATINUM) {
            // Snapshot baseline BEFORE pool update (self-revenue fix).
            revenueBaselineOf[id] = _accRevenuePerPlatinum;

            uint256 platBefore = platinumCount;
            if (platBefore > 0) {
                uint256 toHolders = (msg.value * HOLDER_SHARE_BPS) / BPS;
                _accRevenuePerPlatinum += (toHolders * ACC_PRECISION) / platBefore;
                totalRevenue += toHolders;
                toTreasury    = msg.value - toHolders;
            }
            platinumCount = platBefore + 1;
        }

        _safeMint(msg.sender, id);

        (bool ok,) = payable(treasury).call{value: toTreasury}("");
        if (!ok) revert TransferFailed();

        emit Minted(msg.sender, id, tier);
    }

    /// @notice Owner mint for partners/promotions.
    function adminMint(address to, uint8 tier) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (tier < TIER_SILVER || tier > TIER_PLATINUM) revert BadTier();
        if (tierMinted[tier] >= tierMaxSupply[tier]) revert TierSoldOut();
        uint256 id = _nextId++;
        tierMinted[tier]++;
        tierOf[id] = tier;
        if (tier == TIER_PLATINUM) {
            revenueBaselineOf[id] = _accRevenuePerPlatinum;
            platinumCount++;
        }
        _safeMint(to, id);
        emit Minted(to, id, tier);
    }

    /*////////////////////////////////////////////////////////////////
                        PLATINUM REVENUE SHARE
    ////////////////////////////////////////////////////////////////*/

    /// @notice Deposit platform revenue to be shared among Platinum
    ///         holders pro-rata.
    function depositRevenue() external payable {
        if (msg.value == 0) revert ZeroAmount();
        if (platinumCount > 0) {
            _accRevenuePerPlatinum += (msg.value * ACC_PRECISION) / platinumCount;
            totalRevenue           += msg.value;
            emit RevenueDeposited(msg.sender, msg.value);
        } else {
            (bool ok,) = payable(treasury).call{value: msg.value}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Revenue pending for a single Platinum token.
    function pendingRevenueOf(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        if (tierOf[tokenId] != TIER_PLATINUM) return 0;
        uint256 earned = (_accRevenuePerPlatinum - revenueBaselineOf[tokenId]) / ACC_PRECISION;
        return earned > claimedOf[tokenId] ? earned - claimedOf[tokenId] : 0;
    }

    /// @notice Total pending revenue across all tokens a holder owns.
    function pendingRevenue(address holder) public view returns (uint256 total) {
        uint256 n = balanceOf(holder);
        for (uint256 i; i < n; ++i) {
            total += pendingRevenueOf(tokenOfOwnerByIndex(holder, i));
        }
    }

    /// @notice Claim all pending revenue for every Platinum token you
    ///         hold. Pull-pattern: revenue follows the token, so buying
    ///         a token with unclaimed revenue entitles you to claim it
    ///         (price that into secondary sales).
    function claimRevenue() external nonReentrant {
        uint256 n = balanceOf(msg.sender);
        uint256 owed;
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenOfOwnerByIndex(msg.sender, i);
            uint256 p  = pendingRevenueOf(id);
            if (p > 0) {
                claimedOf[id] += p;
                owed += p;
                emit RevenueClaimed(msg.sender, id, p);
            }
        }
        if (owed == 0) revert NothingOwed();
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        if (!ok) revert TransferFailed();
    }

    /*////////////////////////////////////////////////////////////////
                          PLATFORM UTILITY VIEWS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Highest fee-discount (bps) across all passes a user
    ///         holds — used by the platform for fee calculation.
    function getFeeDiscount(address user) external view returns (uint256 best) {
        uint256 n = balanceOf(user);
        for (uint256 i; i < n; ++i) {
            uint256 d = tierDiscountBps[tierOf[tokenOfOwnerByIndex(user, i)]];
            if (d > best) best = d;
        }
    }

    /// @notice Highest tier a user holds (0 = none).
    function getHighestTier(address user) external view returns (uint8 best) {
        uint256 n = balanceOf(user);
        for (uint256 i; i < n; ++i) {
            uint8 t = tierOf[tokenOfOwnerByIndex(user, i)];
            if (t > best) best = t;
        }
    }

    function getTierName(uint8 tier) public pure returns (string memory) {
        if (tier == TIER_SILVER)   return "SILVER";
        if (tier == TIER_GOLD)     return "GOLD";
        if (tier == TIER_PLATINUM) return "PLATINUM";
        return "NONE";
    }

    /*////////////////////////////////////////////////////////////////
                                METADATA
    ////////////////////////////////////////////////////////////////*/

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string(abi.encodePacked(_baseTokenURI, tokenId.toString(), ".json"));
    }

    /*////////////////////////////////////////////////////////////////
                                  ADMIN
    ////////////////////////////////////////////////////////////////*/

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
        emit MintOpenSet(open);
    }

    function configureTier(uint8 tier, uint256 price, uint256 maxSupply, uint256 discountBps)
        external onlyOwner
    {
        if (tier < TIER_SILVER || tier > TIER_PLATINUM) revert BadTier();
        tierPrice[tier]       = price;
        tierMaxSupply[tier]   = maxSupply;
        tierDiscountBps[tier] = discountBps;
        emit TierConfigured(tier, price, maxSupply, discountBps);
    }

    function updateTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        _setDefaultRoyalty(t, ROYALTY_BPS);
        emit TreasuryUpdated(t);
    }

    function setBaseURI(string calldata base) external onlyOwner {
        _baseTokenURI = base;
        emit BaseURIUpdated(base);
    }

    /*////////////////////////////////////////////////////////////////
                        REQUIRED OZ OVERRIDES
    ////////////////////////////////////////////////////////////////*/

    function _update(address to, uint256 tokenId, address auth)
        internal override(ERC721, ERC721Enumerable) returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, ERC721Enumerable, ERC2981) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    receive() external payable {
        // Direct ETH treated as a revenue deposit when Platinum
        // holders exist.
        if (msg.value > 0 && platinumCount > 0) {
            _accRevenuePerPlatinum += (msg.value * ACC_PRECISION) / platinumCount;
            totalRevenue           += msg.value;
            emit RevenueDeposited(msg.sender, msg.value);
        }
    }
}
