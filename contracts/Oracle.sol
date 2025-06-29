// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OmniPriceOracle
 * @dev Aggregates price feeds from multiple Chainlink oracles
 */
contract OmniPriceOracle is Ownable {
    mapping(string => AggregatorV3Interface) public priceFeeds;
    mapping(string => uint256) public lastUpdated;
    uint256 public constant STALE_THRESHOLD = 3600; // 1 hour
    uint256 public constant PRICE_PRECISION = 1e8;
    
    event PriceFeedAdded(string indexed symbol, address indexed priceFeed);
    event PriceFeedRemoved(string indexed symbol);
    event PriceRequested(string indexed symbol, uint256 price, uint256 timestamp);
    
    error PriceFeedNotFound(string symbol);
    error InvalidPrice(string symbol);
    error StalePrice(string symbol, uint256 updatedAt);
    error ZeroAddress();
    
    constructor(address initialOwner) Ownable(initialOwner) {}
    
    /**
     * @dev Adds a new price feed for a given symbol
     * @param symbol The symbol identifier (e.g., "BTC", "ETH")
     * @param priceFeed The Chainlink price feed contract address
     */
    function addPriceFeed(string memory symbol, address priceFeed) external onlyOwner {
        if (priceFeed == address(0)) revert ZeroAddress();
        
        priceFeeds[symbol] = AggregatorV3Interface(priceFeed);
        emit PriceFeedAdded(symbol, priceFeed);
    }
    
    /**
     * @dev Removes a price feed for a given symbol
     * @param symbol The symbol identifier to remove
     */
    function removePriceFeed(string memory symbol) external onlyOwner {
        delete priceFeeds[symbol];
        emit PriceFeedRemoved(symbol);
    }
    
    /**
     * @dev Gets the latest price for a given symbol
     * @param symbol The symbol to get price for
     * @return price The latest price with 8 decimal precision
     * @return timestamp The timestamp of the price update
     */
    function getPrice(string memory symbol) external view returns (uint256 price, uint256 timestamp) {
        AggregatorV3Interface priceFeed = priceFeeds[symbol];
        if (address(priceFeed) == address(0)) revert PriceFeedNotFound(symbol);
        
        (, int256 priceInt, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        
        if (priceInt <= 0) revert InvalidPrice(symbol);
        if (block.timestamp - updatedAt > STALE_THRESHOLD) revert StalePrice(symbol, updatedAt);
        
        price = uint256(priceInt);
        timestamp = updatedAt;
    }
    
    /**
     * @dev Gets the latest prices for multiple symbols
     * @param symbols Array of symbols to get prices for
     * @return prices Array of latest prices
     * @return timestamps Array of price update timestamps
     */
    function getPrices(string[] memory symbols) 
        external 
        view 
        returns (uint256[] memory prices, uint256[] memory timestamps) 
    {
        uint256 length = symbols.length;
        prices = new uint256[](length);
        timestamps = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            (prices[i], timestamps[i]) = this.getPrice(symbols[i]);
        }
    }
    
    /**
     * @dev Checks if a price feed exists for a symbol
     * @param symbol The symbol to check
     * @return exists True if price feed exists
     */
    function hasPriceFeed(string memory symbol) external view returns (bool exists) {
        return address(priceFeeds[symbol]) != address(0);
    }
    
    /**
     * @dev Gets the decimals for a price feed
     * @param symbol The symbol to get decimals for
     * @return decimals The number of decimals
     */
    function getDecimals(string memory symbol) external view returns (uint8 decimals) {
        AggregatorV3Interface priceFeed = priceFeeds[symbol];
        if (address(priceFeed) == address(0)) revert PriceFeedNotFound(symbol);
        
        return priceFeed.decimals();
    }
    
    /**
     * @dev Gets the description for a price feed
     * @param symbol The symbol to get description for
     * @return description The price feed description
     */
    function getDescription(string memory symbol) external view returns (string memory description) {
        AggregatorV3Interface priceFeed = priceFeeds[symbol];
        if (address(priceFeed) == address(0)) revert PriceFeedNotFound(symbol);
        
        return priceFeed.description();
    }
}