// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                        CRYPTVALT FOUNDER NFT (CVFD) v2.0
              ERC-721 + EIP-2981 + Revenue Share — OZ Edition
//////////////////////////////////////////////////////////////////////////*/

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CryptValt Founder NFT (CVFD)
/// @author CryptValt
/// @notice 100 founder passes. Mint revenue: 90% treasury, 10% shared
///         pro-rata among existing holders. Holders also receive ongoing
///         platform revenue deposits.
/// @dev v2.0 hardened release on OpenZeppelin audited bases:
///      - ERC721 + ERC721Enumerable (audited transfer/ownership logic)
///      - ERC2981 on-chain royalty standard (marketplaces honor it)
///      - Ownable2Step (Safe-ready), ReentrancyGuard
///      Security fixes over v1:
///      - SELF-REVENUE FIX: minter's revenue baseline is snapshotted
///        BEFORE the pool update from their own payment, and the pool
///        divides among tokens minted before them — a minter can no
///        longer earn a share of their own mint payment
///      - Pull-pattern revenue claims (unchanged) with per-token
///        baseline accounting like Membership v2
contract CryptValtFounder is ERC721, ERC721Enumerable, ERC2981, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    /*////////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_SUPPLY   = 100;
    uint256 public constant MINT_PRICE   = 1 ether;
    uint96  public constant ROYALTY_BPS  = 1000; // 10%
    uint256 public constant HOLDER_SHARE_BPS = 1000; // 10% of each mint
    uint256 public constant BPS          = 10_000;

    /// @dev Precision scalar for the revenue accumulator.
    uint256 private constant ACC_PRECISION = 1e18;

    /*////////////////////////////////////////////////////////////////
                              CUSTOM ERRORS
    ////////////////////////////////////////////////////////////////*/

    error MintClosed();
    error Frozen();
    error LowPayment();
    error SoldOut();
    error ZeroAddress();
    error ZeroAmount();
    error NothingOwed();
    error TransferFailed();

    /*////////////////////////////////////////////////////////////////
                                 STORAGE
    ////////////////////////////////////////////////////////////////*/

    address public treasury;
    uint256 public totalRevenue;
    uint256 private _nextId = 1;
    bool    public mintOpen;
    bool    public frozen;

    /// @dev Revenue accumulator per token, scaled by ACC_PRECISION.
    uint256 private _accRevenuePerToken;
    /// @dev Accumulator snapshot at each token's mint (v2.0 fix: taken
    ///      BEFORE the token's own mint payment enters the pool).
    mapping(uint256 => uint256) public revenueBaselineOf;
    /// @dev Revenue already claimed against each token.
    mapping(uint256 => uint256) public claimedOf;

    string private _baseTokenURI = "https://cryptvalt.io/nft/founder/";

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

    event Minted(address indexed to, uint256 indexed tokenId, string rarity);
    event RevenueDeposited(address indexed from, uint256 amount);
    event RevenueClaimed(address indexed holder, uint256 indexed tokenId, uint256 amount);
    event MintOpenSet(bool open);
    event FrozenSet(bool frozen);
    event TreasuryUpdated(address indexed newTreasury);
    event BaseURIUpdated(string newBase);

    /*////////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /// @param initialOwner Deployer/admin — transfer to the Safe via
    ///                     transferOwnership + acceptOwnership.
    /// @param _treasury    Receives 90% of mint revenue.
    constructor(address initialOwner, address _treasury)
        ERC721("CryptValt Founder", "CVFD")
        Ownable(initialOwner)
    {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        _setDefaultRoyalty(_treasury, ROYALTY_BPS); // EIP-2981
    }

    /*////////////////////////////////////////////////////////////////
                                 MINTING
    ////////////////////////////////////////////////////////////////*/

    /// @notice Mint a Founder pass. 90% of payment goes to treasury,
    ///         10% is shared among tokens minted before yours.
    /// @dev v2.0 SELF-REVENUE FIX: the new token's baseline is recorded
    ///      from the accumulator BEFORE this mint's holder-share is
    ///      added, and the share divides by the pre-mint supply — so
    ///      the minter cannot claim any part of their own payment.
    function mint() external payable nonReentrant {
        if (!mintOpen)               revert MintClosed();
        if (frozen)                  revert Frozen();
        if (msg.value < MINT_PRICE)  revert LowPayment();
        uint256 supplyBefore = totalSupply();
        if (supplyBefore >= MAX_SUPPLY) revert SoldOut();

        uint256 id = _nextId++;

        uint256 toHolders  = (msg.value * HOLDER_SHARE_BPS) / BPS;
        uint256 toTreasury = msg.value - toHolders;

        if (supplyBefore > 0) {
            _accRevenuePerToken += (toHolders * ACC_PRECISION) / supplyBefore;
            totalRevenue        += toHolders;
        } else {
            // First mint: no prior holders — everything to treasury.
            toTreasury = msg.value;
        }

        // Snapshot baseline AFTER the pool update from this mint's own
        // payment (self-revenue fix): the new token's entitlement starts
        // from here, excluding its own contribution.
        revenueBaselineOf[id] = _accRevenuePerToken;

        _safeMint(msg.sender, id);

        (bool ok,) = payable(treasury).call{value: toTreasury}("");
        if (!ok) revert TransferFailed();

        emit Minted(msg.sender, id, getRarity(id));
    }

    /// @notice Owner mint for team/partners (no payment, no pool
    ///         entitlement dilution beyond standard baseline).
    function adminMint(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() >= MAX_SUPPLY) revert SoldOut();
        uint256 id = _nextId++;
        revenueBaselineOf[id] = _accRevenuePerToken;
        _safeMint(to, id);
        emit Minted(to, id, getRarity(id));
    }

    /*////////////////////////////////////////////////////////////////
                              REVENUE SHARE
    ////////////////////////////////////////////////////////////////*/

    /// @notice Deposit platform revenue to be shared among all current
    ///         Founder holders pro-rata.
    function depositRevenue() external payable {
        if (msg.value == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        if (supply > 0) {
            _accRevenuePerToken += (msg.value * ACC_PRECISION) / supply;
            totalRevenue        += msg.value;
            emit RevenueDeposited(msg.sender, msg.value);
        } else {
            (bool ok,) = payable(treasury).call{value: msg.value}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Revenue pending for a single token.
    function pendingRevenueOf(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        uint256 earned = (_accRevenuePerToken - revenueBaselineOf[tokenId]) / ACC_PRECISION;
        return earned > claimedOf[tokenId] ? earned - claimedOf[tokenId] : 0;
    }

    /// @notice Total pending revenue across all tokens a holder owns.
    function pendingRevenue(address holder) public view returns (uint256 total) {
        uint256 n = balanceOf(holder);
        for (uint256 i; i < n; ++i) {
            total += pendingRevenueOf(tokenOfOwnerByIndex(holder, i));
        }
    }

    /// @notice Claim all pending revenue for every token you hold.
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
                                METADATA
    ////////////////////////////////////////////////////////////////*/

    /// @notice Rarity tier by token id.
    function getRarity(uint256 id) public pure returns (string memory) {
        if (id <= 5)  return "LEGENDARY";
        if (id <= 20) return "EPIC";
        if (id <= 50) return "RARE";
        return "STANDARD";
    }

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

    function setFrozen(bool f) external onlyOwner {
        frozen = f;
        emit FrozenSet(f);
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
        // Direct ETH treated as a revenue deposit when holders exist.
        if (msg.value > 0 && totalSupply() > 0) {
            _accRevenuePerToken += (msg.value * ACC_PRECISION) / totalSupply();
            totalRevenue        += msg.value;
            emit RevenueDeposited(msg.sender, msg.value);
        }
    }
}
