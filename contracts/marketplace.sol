// //SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NFTMarketplace is ERC721("MyNFT", "MNFT"), Ownable, ReentrancyGuard {
    ERC20 public paymentToken;

    struct NFT {
        string tokenName;
        uint256 tokenID;
        bool isListed;
        string description;
        string category;
        address creator;
        uint256 price;
    }

    mapping(uint256 => NFT) public nfts;
    uint256 private nextTokenId;
    uint256[] public listedNFTs;

    constructor() Ownable() ReentrancyGuard() {}

    event NFTMinted(uint256 indexed tokenId, address indexed creator);
    event NFTListed(uint256 indexed tokenId, uint256 price);
    event NFTSold(uint256 indexed tokenId, address indexed buyer, uint256 price);

    function mintNFT(
        string memory _tokenName,
        string memory _description,
        string memory _category
    ) public {
        uint256 tokenId = nextTokenId;

        nfts[tokenId] = NFT({
            tokenName: _tokenName,
            tokenID: tokenId,
            isListed: false,
            description: _description,
            category: _category,
            creator: msg.sender,
            price: 0
        });

        _safeMint(msg.sender, tokenId);
        emit NFTMinted(tokenId, msg.sender);
        nextTokenId++;
    }

    function listNFT(uint256 tokenID, uint256 price) public {
        require(ownerOf(tokenID) == msg.sender, "Only owner can list an NFT");
        require(!nfts[tokenID].isListed, "NFT is already listed for sale");
        require(price > 0, "Price must be greater than 0");

        nfts[tokenID].price = price;
        nfts[tokenID].isListed = true;
        listedNFTs.push(tokenID);

        emit NFTListed(tokenID, price);
    }

    function buyNFT(uint256 tokenID) public nonReentrant {
        require(nfts[tokenID].isListed, "This NFT is not listed for sale");

        uint256 price = nfts[tokenID].price;
        address seller = ownerOf(tokenID);

        require(
            paymentToken.balanceOf(msg.sender) >= price,
            "Insufficient Balance"
        );

        require(
            paymentToken.transferFrom(msg.sender, seller, price),
            "Payment transfer failed"
        );

        _transfer(seller, msg.sender, tokenID);

        nfts[tokenID].isListed = false;

        emit NFTSold(tokenID, msg.sender, price);
    }

    function getNFTsForSale() public view returns (uint256[] memory) {
        return listedNFTs;
    }

    function getNFTDetails(uint256 tokenID) public view returns (NFT memory) {
        require(nfts[tokenID].creator != address(0), "NFT does not exist");
        return nfts[tokenID];
    }
}

contract Auction is NFTMarketplace {
    struct AuctionNFT {
        address seller;
        uint256 minBid;
        address highestBidder;
        uint256 highestBid;
        uint256 auctionStartTime;
        uint256 auctionEndTime;
        bool isActive;
        address[] bidHistory;
        uint256[] bidAmounts;
        uint256 finalPrice;
    }

    mapping(uint256 => AuctionNFT) public auctions;
    mapping(address => uint256) public pendingReturns;

    event AuctionCreated(uint256 indexed tokenID, uint256 startTime, uint256 endTime);
    event BidPlaced(uint256 indexed tokenID, address indexed bidder, uint256 amount);
    event AuctionEnded(uint256 indexed tokenID, address winner, uint256 finalPrice);

    constructor(ERC20 _paymentToken) {
        paymentToken = _paymentToken;
    }

    function createAuction(
        uint256 tokenID,
        uint256 _auctionStartTime,
        uint256 _auctionEndTime,
        uint256 _minBid
    ) public {
        require(ownerOf(tokenID) == msg.sender, "Only owner of NFT can create an auction");
        require(!nfts[tokenID].isListed, "NFT is listed for sale");
        require(_auctionEndTime > _auctionStartTime, "Cannot end auction before starting");
        require(_auctionStartTime > block.timestamp, "Auction can only be started in future");

        auctions[tokenID] = AuctionNFT({
            seller: msg.sender,
            minBid: _minBid,
            highestBidder: address(0),
            highestBid: 0,
            auctionStartTime: _auctionStartTime,
            auctionEndTime: _auctionEndTime,
            isActive: false,
            bidHistory: new address[](0),
            bidAmounts: new uint256[](0) ,
            finalPrice: 0
        });

        emit AuctionCreated(tokenID, _auctionStartTime, _auctionEndTime);
    }

    function placeBid(uint256 tokenID, uint256 bidAmount) public nonReentrant {
        AuctionNFT storage auction = auctions[tokenID];

        require(block.timestamp >= auction.auctionStartTime, "Auction not started");
        require(block.timestamp <= auction.auctionEndTime, "Auction ended");
        require(bidAmount >= auction.minBid && bidAmount > auction.highestBid, "Bid too low");

        if (auction.highestBidder != address(0)) {
            pendingReturns[auction.highestBidder] += auction.highestBid;
        }

        require(
            paymentToken.transferFrom(msg.sender, address(this), bidAmount),
            "Bid transfer failed"
        );

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;
        auction.bidAmounts.push(bidAmount);
        auction.bidHistory.push(msg.sender);

        emit BidPlaced(tokenID, msg.sender, bidAmount);
    }

    function withdrawBid() public nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "No funds to withdraw");

        pendingReturns[msg.sender] = 0;

        require(paymentToken.transfer(msg.sender, amount), "Withdrawal failed");
    }

    function endAuction(uint256 tokenID) public {
        AuctionNFT storage auction = auctions[tokenID];

        require(block.timestamp > auction.auctionEndTime, "Auction not yet ended");
        require(!auction.isActive, "Auction already settled");
        require(ownerOf(tokenID) == auction.seller, "Seller no longer owns the NFT");

        auction.isActive = true;

        if (auction.highestBidder != address(0)) {
            _transfer(auction.seller, auction.highestBidder, tokenID);

            require(
                paymentToken.transfer(auction.seller, auction.highestBid),
                "Payment transfer failed"
            );

            auction.finalPrice = auction.highestBid;

            emit AuctionEnded(
                tokenID,
                auction.highestBidder,
                auction.highestBid
            );
        }
    }
}

contract MyToken is ERC20 {
    uint256 private constant INITIAL_SUPPLY = 10_000_000 * (10 ** 18);
    address public admin;

    constructor() ERC20("MToken", "MYTKN") {
        admin = msg.sender;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "No access");
        _;
    }

    function mint(address to, uint256 amount) public onlyAdmin {
        _mint(to, amount);
    }
}
