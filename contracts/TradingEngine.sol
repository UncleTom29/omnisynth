// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./Pool.sol";

// ============================================================================
// GAS-OPTIMIZED TRADING ENGINE
// ============================================================================

contract OmniTradingEngine is ReentrancyGuard, Ownable, Pausable, AutomationCompatibleInterface {
    IERC20 public immutable USDC;
    OmniLiquidityPool public liquidityPool;
    
    struct Position {
        address trader;
        bytes32 marketHash; // Use hash instead of string for gas efficiency
        bool isLong;
        uint128 size; // Pack into smaller slots
        uint128 entryPrice;
        uint32 leverage;
        uint128 collateral;
        uint128 liquidationPrice;
        uint32 timestamp;
        bool isActive;
    }
    
    struct Order {
        uint256 id;
        address trader;
        bytes32 marketHash;
        bool isLong;
        uint128 size;
        uint128 price;
        uint32 leverage;
        uint128 collateral;
        uint32 timestamp;
        bool isActive;
        bool isMarketOrder;
    }
    
    // State variables
    mapping(address => uint256) public userCollateral;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userPositions;
    mapping(address => uint256[]) public userOrders;
    mapping(bytes32 => AggregatorV3Interface) public priceFeeds;
    mapping(string => bytes32) public marketHashes; // String to hash mapping
    
    uint256 public nextPositionId = 1;
    uint256 public nextOrderId = 1;
    uint256 public constant MAX_LEVERAGE = 100;
    uint256 public constant LIQUIDATION_THRESHOLD = 90;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant PRICE_PRECISION = 1e8;
    uint256 public tradingFee = 50;
    uint256 public constant STALE_THRESHOLD = 3600;
    uint256 public constant MAX_POSITIONS_PER_CHECK = 10; // Limit gas usage
    
    // Events
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event OrderPlaced(uint256 indexed orderId, address indexed trader, string market, bool isLong, uint256 size, uint256 price);
    event OrderExecuted(uint256 indexed orderId, uint256 indexed positionId, uint256 executionPrice);
    event PositionClosed(uint256 indexed positionId, address indexed trader, int256 pnl);
    event PositionLiquidated(uint256 indexed positionId, address indexed trader, uint256 liquidationPrice);
    event LiquidityCheckFailed(uint256 indexed orderId, string reason);
    event GasLimitReached(string operation, uint256 gasUsed);
    
    // Custom errors for gas efficiency
    error InsufficientCollateral();
    error InvalidLeverage();
    error PositionNotFound();
    error OrderNotFound();
    error InsufficientLiquidity();
    error PriceFeedNotFound();
    error StalePrice();
    error InvalidPrice();
    error TransferFailed();
    error NotAuthorized();
    error ContractPaused();
    
    modifier onlyWhenNotPaused() {
        if (paused()) revert ContractPaused();
        _;
    }
    
    modifier gasLimitCheck(uint256 gasStart, string memory operation) {
        _;
        uint256 gasUsed = gasStart - gasleft();
        if (gasUsed > 500000) { // 500k gas limit warning
            emit GasLimitReached(operation, gasUsed);
        }
    }
    
    constructor(
        address _usdc,
        address _liquidityPool,
        address initialOwner
    ) Ownable(initialOwner) {
        USDC = IERC20(_usdc);
        liquidityPool = OmniLiquidityPool(_liquidityPool);
        
        // Pre-populate market hashes
        marketHashes["BTC/USD"] = keccak256("BTC/USD");
        marketHashes["ETH/USD"] = keccak256("ETH/USD");
        marketHashes["LINK/USD"] = keccak256("LINK/USD");
    }
    
    // Add market with hash for gas efficiency
    function addMarket(string memory market) external onlyOwner {
        bytes32 marketHash = keccak256(bytes(market));
        marketHashes[market] = marketHash;
    }
    
    function addPriceFeed(string memory symbol, address priceFeed) external onlyOwner {
        bytes32 marketHash = marketHashes[symbol];
        if (marketHash == bytes32(0)) revert PriceFeedNotFound();
        priceFeeds[marketHash] = AggregatorV3Interface(priceFeed);
    }
    
    // Optimized price fetching with try-catch for gas estimation
    function getPrice(string memory symbol) public view returns (uint256 price, uint256 timestamp) {
        bytes32 marketHash = marketHashes[symbol];
        if (marketHash == bytes32(0)) revert PriceFeedNotFound();
        
        AggregatorV3Interface priceFeed = priceFeeds[marketHash];
        if (address(priceFeed) == address(0)) revert PriceFeedNotFound();
        
        try priceFeed.latestRoundData() returns (
            uint80,
            int256 priceInt,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (priceInt <= 0) revert InvalidPrice();
            if (block.timestamp - updatedAt > STALE_THRESHOLD) revert StalePrice();
            return (uint256(priceInt), updatedAt);
        } catch {
            revert InvalidPrice();
        }
    }
    
    // Safe price fetching for external calls
    function getPriceSafe(string memory symbol) external view returns (bool success, uint256 price, uint256 timestamp) {
        try this.getPrice(symbol) returns (uint256 p, uint256 t) {
            return (true, p, t);
        } catch {
            return (false, 0, 0);
        }
    }
    
    function depositCollateral(uint256 amount) external nonReentrant onlyWhenNotPaused {
        if (amount == 0) revert InsufficientCollateral();
        
        // Check allowance first to avoid failed transfers
        if (USDC.allowance(msg.sender, address(this)) < amount) revert TransferFailed();
        
        bool success = USDC.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        userCollateral[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }
    
    function withdrawCollateral(uint256 amount) external nonReentrant onlyWhenNotPaused {
        if (amount == 0) revert InsufficientCollateral();
        if (userCollateral[msg.sender] < amount) revert InsufficientCollateral();
        
        uint256 availableCollateral = getAvailableCollateral(msg.sender);
        if (availableCollateral < amount) revert InsufficientCollateral();
        
        userCollateral[msg.sender] -= amount;
        
        bool success = USDC.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        emit CollateralWithdrawn(msg.sender, amount);
    }
    
   // FIXED: Place order function with correct liquidity calculation
    function placeOrder(
        string memory market,
        bool isLong,
        uint256 size,
        uint256 price,
        uint256 leverage,
        bool isMarketOrder
    ) external nonReentrant onlyWhenNotPaused returns (uint256 orderId) {
        uint256 gasStart = gasleft();
        
        if (leverage == 0 || leverage > MAX_LEVERAGE) revert InvalidLeverage();
        if (size == 0) revert InsufficientCollateral();
        
        uint256 requiredCollateral = size / leverage;
        if (getAvailableCollateral(msg.sender) < requiredCollateral) revert InsufficientCollateral();
        
        bytes32 marketHash = marketHashes[market];
        if (marketHash == bytes32(0)) revert PriceFeedNotFound();
        
        // FIXED: Check liquidity for position size, not position size * leverage
        // The position size is what gets allocated to the pool
        if (!checkLiquidityAvailable(market, isLong, size)) {
            revert InsufficientLiquidity();
        }
        
        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            trader: msg.sender,
            marketHash: marketHash,
            isLong: isLong,
            size: uint128(size),
            price: uint128(price),
            leverage: uint32(leverage),
            collateral: uint128(requiredCollateral),
            timestamp: uint32(block.timestamp),
            isActive: true,
            isMarketOrder: isMarketOrder
        });
        
        userOrders[msg.sender].push(orderId);
        emit OrderPlaced(orderId, msg.sender, market, isLong, size, price);
        
        if (isMarketOrder) {
            executeOrderInternal(orderId);
        }
        
        uint256 gasUsed = gasStart - gasleft();
        if (gasUsed > 400000) {
            emit GasLimitReached("placeOrder", gasUsed);
        }
    }
    
    // Execute order function with error handling and gas optimization
    function executeOrder(uint256 orderId) external nonReentrant {
        executeOrderInternal(orderId);
    }
    
    // FIXED: Execute order with correct liquidity allocation
    function executeOrderInternal(uint256 orderId) internal {
        Order storage order = orders[orderId];
        if (!order.isActive) revert OrderNotFound();
        
        string memory market = getMarketFromHash(order.marketHash);
        
        (bool priceSuccess, uint256 currentPrice,) = this.getPriceSafe(market);
        if (!priceSuccess) return;
        
        if (!order.isMarketOrder) {
            if (order.isLong && currentPrice > order.price) return;
            if (!order.isLong && currentPrice < order.price) return;
        }
        
        // FIXED: Allocate position size to the same-side pool, not position size * leverage
        uint256 requiredLiquidity = uint256(order.size); // Just the position size
        
        if (!checkLiquidityAvailable(market, order.isLong, requiredLiquidity)) {
            emit LiquidityCheckFailed(orderId, "Insufficient liquidity for execution");
            return;
        }
        
        try liquidityPool.allocateLiquidity(market, order.isLong, requiredLiquidity) returns (bool success) {
            if (!success) {
                emit LiquidityCheckFailed(orderId, "Liquidity allocation failed");
                return;
            }
        } catch {
            emit LiquidityCheckFailed(orderId, "Liquidity allocation reverted");
            return;
        }
        
        uint256 executionPrice = order.isMarketOrder ? currentPrice : order.price;
        uint256 positionId = nextPositionId++;
        
        uint256 liquidationPrice = calculateLiquidationPrice(executionPrice, order.leverage, order.isLong);
        
        positions[positionId] = Position({
            trader: order.trader,
            marketHash: order.marketHash,
            isLong: order.isLong,
            size: order.size,
            entryPrice: uint128(executionPrice),
            leverage: order.leverage,
            collateral: order.collateral,
            liquidationPrice: uint128(liquidationPrice),
            timestamp: order.timestamp,
            isActive: true
        });
        
        userPositions[order.trader].push(positionId);
        order.isActive = false;
        
        emit OrderExecuted(orderId, positionId, executionPrice);
    }
    
    
    // FIXED: Close position with correct liquidity deallocation
    function closePosition(uint256 positionId) external nonReentrant onlyWhenNotPaused {
        Position storage position = positions[positionId];
        if (position.trader != msg.sender) revert NotAuthorized();
        if (!position.isActive) revert PositionNotFound();
        
        string memory market = getMarketFromHash(position.marketHash);
        
        (bool priceSuccess, uint256 currentPrice,) = this.getPriceSafe(market);
        if (!priceSuccess) revert InvalidPrice();
        
        int256 pnl = calculatePnL(position.entryPrice, currentPrice, position.size, position.isLong);
        uint256 fee = (uint256(position.size) * tradingFee) / 10000;
        int256 netPnl = pnl - int256(fee);
        
        // FIXED: Deallocate position size, not position size * leverage
        uint256 allocatedLiquidity = uint256(position.size);
        liquidityPool.deallocateLiquidity(market, position.isLong, allocatedLiquidity);
        
        liquidityPool.collectTradingFees(market, fee);
        
        if (netPnl > 0) {
            uint256 profit = uint256(netPnl);
            bool profitProcessed = liquidityPool.processProfit(market, position.isLong, profit);
            if (!profitProcessed) revert InsufficientLiquidity();
            userCollateral[msg.sender] += profit;
        } else {
            uint256 loss = uint256(-netPnl);
            liquidityPool.processLoss(market, position.isLong, loss);
            if (userCollateral[msg.sender] < loss) revert InsufficientCollateral();
            userCollateral[msg.sender] -= loss;
        }
        
        position.isActive = false;
        emit PositionClosed(positionId, msg.sender, netPnl);
    }
    // Optimized liquidation checking with gas limits
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256[] memory liquidatablePositions = new uint256[](MAX_POSITIONS_PER_CHECK);
        uint256 count = 0;
        uint256 gasUsed = 0;
        uint256 gasStart = gasleft();
        
        for (uint256 i = 1; i < nextPositionId && count < MAX_POSITIONS_PER_CHECK; i++) {
            // Check gas usage every 5 iterations
            if (i % 5 == 0) {
                gasUsed = gasStart - gasleft();
                if (gasUsed > 400000) break; // Stop if approaching gas limit
            }
            
            if (positions[i].isActive && isLiquidatableSafe(i)) {
                liquidatablePositions[count] = i;
                count++;
            }
        }
        
        if (count > 0) {
            uint256[] memory result = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                result[i] = liquidatablePositions[i];
            }
            return (true, abi.encode(result));
        }
        
        return (false, "");
    }
    
    function performUpkeep(bytes calldata performData) external override {
        uint256[] memory positionIds = abi.decode(performData, (uint256[]));
        
        for (uint256 i = 0; i < positionIds.length && i < MAX_POSITIONS_PER_CHECK; i++) {
            if (isLiquidatableSafe(positionIds[i])) {
                liquidatePosition(positionIds[i]);
            }
        }
    }
    
    function isLiquidatableSafe(uint256 positionId) internal view returns (bool) {
        try this.isLiquidatable(positionId) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    function isLiquidatable(uint256 positionId) external view returns (bool) {
        Position storage position = positions[positionId];
        if (!position.isActive) return false;
        
        string memory market = getMarketFromHash(position.marketHash);
        (bool priceSuccess, uint256 currentPrice,) = this.getPriceSafe(market);
        if (!priceSuccess) return false;
        
        int256 pnl = calculatePnL(position.entryPrice, currentPrice, position.size, position.isLong);
        
        uint256 currentCollateral = position.collateral;
        if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (loss >= currentCollateral) return true;
            currentCollateral -= loss;
        }
        
        return (currentCollateral * 100) / position.collateral <= (100 - LIQUIDATION_THRESHOLD);
    }
    
    function liquidatePosition(uint256 positionId) internal {
        Position storage position = positions[positionId];
        if (!position.isActive) return;
        
        string memory market = getMarketFromHash(position.marketHash);
        (bool priceSuccess, uint256 currentPrice,) = this.getPriceSafe(market);
        if (!priceSuccess) return;
        
        uint256 liquidationBonus = (uint256(position.collateral) * liquidityPool.LIQUIDATION_BONUS()) / 10000;
        uint256 remainingCollateral = uint256(position.collateral) > liquidationBonus ? 
            uint256(position.collateral) - liquidationBonus : 0;
        
        uint256 allocatedLiquidity = uint256(position.size) * uint256(position.leverage);
        liquidityPool.deallocateLiquidity(market, position.isLong, allocatedLiquidity);
        
        if (remainingCollateral > 0) {
            liquidityPool.processLoss(market, position.isLong, remainingCollateral);
        }
        
        position.isActive = false;
        emit PositionLiquidated(positionId, position.trader, currentPrice);
    }
    
    // Utility functions
    function getMarketFromHash(bytes32 marketHash) internal pure returns (string memory) {
        // In production, maintain a reverse mapping or use events to track this
        if (marketHash == keccak256("BTC/USD")) return "BTC/USD";
        if (marketHash == keccak256("ETH/USD")) return "ETH/USD";
        if (marketHash == keccak256("LINK/USD")) return "LINK/USD";
        return "";
    }
    
   function checkLiquidityAvailable(string memory market, bool isLong, uint256 requiredLiquidity) public view returns (bool) {
        try liquidityPool.getPoolInfo(market) returns (
            uint256 longPool,
            uint256 shortPool,
            uint256,
            uint256,
            uint256 utilization
        ) {
            // Check overall pool utilization first
            uint256 maxUtilization = liquidityPool.MAX_POOL_UTILIZATION();
            if (utilization >= maxUtilization) return false;
            
            // Check if we have enough total pool value to support the new position
            uint256 totalPoolValue = liquidityPool.totalPoolValue();
            uint256 totalAllocated = longPool + shortPool;
            
            // The required liquidity is the position size, not position size * leverage
            // We need to allocate the position size to the same-side pool
            uint256 newTotalAllocated = totalAllocated + requiredLiquidity;
            uint256 maxAllocation = (totalPoolValue * maxUtilization) / 100;
            
            if (newTotalAllocated > maxAllocation) return false;
            
            // Also check that counterparty pool has sufficient liquidity to cover potential profits
            // This is a safety check - counterparty pool should have at least the position size
            uint256 counterpartyPool = isLong ? shortPool : longPool;
            return counterpartyPool >= requiredLiquidity / 2; // Conservative check
            
        } catch {
            return false;
        }
    }
    
    function calculatePnL(uint256 entryPrice, uint256 currentPrice, uint256 size, bool isLong) internal pure returns (int256) {
        if (isLong) {
            return int256((currentPrice - entryPrice) * size / PRICE_PRECISION);
        } else {
            return int256((entryPrice - currentPrice) * size / PRICE_PRECISION);
        }
    }
    
    function calculateLiquidationPrice(uint256 entryPrice, uint256 leverage, bool isLong) internal pure returns (uint256) {
        uint256 liquidationThreshold = (PRECISION * 90) / 100;
        if (isLong) {
            return (entryPrice * (PRECISION - liquidationThreshold / leverage)) / PRECISION;
        } else {
            return (entryPrice * (PRECISION + liquidationThreshold / leverage)) / PRECISION;
        }
    }
    
    function getAvailableCollateral(address user) public view returns (uint256) {
        uint256 totalCollateral = userCollateral[user];
        uint256 usedCollateral = 0;
        
        uint256[] memory userPos = userPositions[user];
        for (uint256 i = 0; i < userPos.length; i++) {
            Position storage position = positions[userPos[i]];
            if (position.isActive) {
                usedCollateral += position.collateral;
            }
        }
        
        uint256[] memory userOrd = userOrders[user];
        for (uint256 i = 0; i < userOrd.length; i++) {
            Order storage order = orders[userOrd[i]];
            if (order.isActive) {
                usedCollateral += order.collateral;
            }
        }
        
        return totalCollateral > usedCollateral ? totalCollateral - usedCollateral : 0;
    }
    
    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    // Batch operations for gas efficiency
    function batchExecuteOrders(uint256[] calldata orderIds) external {
        for (uint256 i = 0; i < orderIds.length && i < 5; i++) { // Limit batch size
            executeOrderInternal(orderIds[i]);
        }
    }
}