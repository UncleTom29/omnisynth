// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============================================================================
// IMPROVED LIQUIDITY MECHANICS WITH COUNTERPARTY POOLS
// ============================================================================

contract OmniLiquidityPool is ERC20, ReentrancyGuard, Ownable {
    IERC20 public immutable USDC;
    
    struct PoolInfo {
        uint256 longPool;      // USDC backing long positions
        uint256 shortPool;     // USDC backing short positions
        uint256 totalVolume;   // Total trading volume
        uint256 feesCollected; // Accumulated fees
        bool isActive;
    }
    
    struct LiquidityProvider {
        uint256 shares;
        uint256 lastRewardClaim;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
    }
    
    mapping(string => PoolInfo) public marketPools;
    mapping(address => LiquidityProvider) public liquidityProviders;
    mapping(string => bool) public supportedMarkets;
    
    uint256 public totalPoolValue;
    uint256 public insuranceFund;
    uint256 public constant INSURANCE_FEE = 10; // 10% of trading fees go to insurance
    uint256 public constant MAX_POOL_UTILIZATION = 80; // 80% max utilization
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% liquidation bonus
    uint256 public constant MIN_LIQUIDITY = 10e6; // 10 USDC minimum
    
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 shares);
    event TradingFeesCollected(string indexed market, uint256 amount);
    event InsuranceFundUsed(uint256 amount, string reason);
    event MarketAdded(string indexed market);
    
    constructor(address _usdc, address initialOwner) ERC20("OmniSynth LP Token", "OMNI-LP") Ownable(initialOwner) {
        USDC = IERC20(_usdc);
    }
    
    function addMarket(string memory market) external onlyOwner {
        require(!supportedMarkets[market], "Market already exists");
        supportedMarkets[market] = true;
        marketPools[market].isActive = true;
        emit MarketAdded(market);
    }
    
    function addLiquidity(uint256 amount) external nonReentrant {
        require(amount >= MIN_LIQUIDITY, "Below minimum liquidity");
        require(USDC.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        uint256 shares;
        if (totalSupply() == 0) {
            shares = amount;
        } else {
            shares = (amount * totalSupply()) / totalPoolValue;
        }
        
        liquidityProviders[msg.sender].shares += shares;
        liquidityProviders[msg.sender].totalDeposited += amount;
        liquidityProviders[msg.sender].lastRewardClaim = block.timestamp;
        
        totalPoolValue += amount;
        _mint(msg.sender, shares);
        
        emit LiquidityAdded(msg.sender, amount, shares);
    }
    
    function removeLiquidity(uint256 shares) external nonReentrant {
        require(shares > 0, "Invalid shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");
        
        uint256 amount = (shares * totalPoolValue) / totalSupply();
        
        // Check if withdrawal would break liquidity requirements
        require(canWithdraw(amount), "Would break liquidity requirements");
        require(USDC.balanceOf(address(this)) >= amount, "Insufficient contract balance");
        
        liquidityProviders[msg.sender].shares -= shares;
        liquidityProviders[msg.sender].totalWithdrawn += amount;
        
        totalPoolValue -= amount;
        _burn(msg.sender, shares);
        
        require(USDC.transfer(msg.sender, amount), "Transfer failed");
        emit LiquidityRemoved(msg.sender, amount, shares);
    }
    
    function canWithdraw(uint256 amount) public view returns (bool) {
        uint256 totalUtilized = 0;
        
        // Calculate total utilized liquidity across all markets
        string[] memory markets = getSupportedMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            PoolInfo storage pool = marketPools[markets[i]];
            totalUtilized += pool.longPool + pool.shortPool;
        }
        
        uint256 availableLiquidity = totalPoolValue - totalUtilized;
        uint256 minRequired = (totalPoolValue * (100 - MAX_POOL_UTILIZATION)) / 100;
        
        return (availableLiquidity - amount) >= minRequired;
    }
    
    function allocateLiquidity(string memory market, bool isLong, uint256 amount) external returns (bool) {
        require(supportedMarkets[market], "Market not supported");
        
        PoolInfo storage pool = marketPools[market];
        uint256 totalAllocated = pool.longPool + pool.shortPool;
        uint256 maxAllocation = (totalPoolValue * MAX_POOL_UTILIZATION) / 100;
        
        require(totalAllocated + amount <= maxAllocation, "Exceeds max allocation");
        
        if (isLong) {
            pool.longPool += amount;
        } else {
            pool.shortPool += amount;
        }
        
        return true;
    }
    
    function deallocateLiquidity(string memory market, bool isLong, uint256 amount) external {
        PoolInfo storage pool = marketPools[market];
        
        if (isLong) {
            require(pool.longPool >= amount, "Insufficient long pool");
            pool.longPool -= amount;
        } else {
            require(pool.shortPool >= amount, "Insufficient short pool");
            pool.shortPool -= amount;
        }
    }
    
    function collectTradingFees(string memory market, uint256 fees) external {
        require(supportedMarkets[market], "Market not supported");
        
        PoolInfo storage pool = marketPools[market];
        uint256 insuranceFee = (fees * INSURANCE_FEE) / 100;
        uint256 lpFee = fees - insuranceFee;
        
        pool.feesCollected += lpFee;
        insuranceFund += insuranceFee;
        totalPoolValue += lpFee;
        
        emit TradingFeesCollected(market, fees);
    }
    
    function processProfit(string memory market, bool isLong, uint256 profit) external returns (bool) {
        PoolInfo storage pool = marketPools[market];
        
        uint256 counterpartyPool = isLong ? pool.shortPool : pool.longPool;
        
        if (counterpartyPool >= profit) {
            // Normal case: counterparty pool covers profit
            if (isLong) {
                pool.shortPool -= profit;
            } else {
                pool.longPool -= profit;
            }
            return true;
        } else {
            // Emergency case: use insurance fund
            uint256 shortage = profit - counterpartyPool;
            
            if (insuranceFund >= shortage) {
                if (isLong) {
                    pool.shortPool = 0;
                } else {
                    pool.longPool = 0;
                }
                insuranceFund -= shortage;
                emit InsuranceFundUsed(shortage, "Covering trading profits");
                return true;
            } else {
                // Critical case: insufficient funds
                return false;
            }
        }
    }
    
    function processLoss(string memory market, bool isLong, uint256 loss) external {
        PoolInfo storage pool = marketPools[market];
        
        if (isLong) {
            pool.longPool += loss;
        } else {
            pool.shortPool += loss;
        }
        
        totalPoolValue += loss;
    }
    
    function getLPRewards(address provider) external view returns (uint256) {
        LiquidityProvider storage lp = liquidityProviders[provider];
        if (lp.shares == 0) return 0;
        
        uint256 totalFees = 0;
        string[] memory markets = getSupportedMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            totalFees += marketPools[markets[i]].feesCollected;
        }
        
        return (lp.shares * totalFees) / totalSupply();
    }
    
    function claimRewards() external nonReentrant {
        uint256 rewards = this.getLPRewards(msg.sender);
        require(rewards > 0, "No rewards to claim");
        
        liquidityProviders[msg.sender].lastRewardClaim = block.timestamp;
        
        // Reset fee tracking (simplified)
        string[] memory markets = getSupportedMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            marketPools[markets[i]].feesCollected = 0;
        }
        
        require(USDC.transfer(msg.sender, rewards), "Reward transfer failed");
    }
    
    function getSupportedMarkets() public pure returns (string[] memory) {
        // In production, maintain an array of supported markets
        string[] memory markets = new string[](4);
        markets[0] = "BTC/USD";
        markets[1] = "ETH/USD";
        markets[2] = "LINK/USD";
        return markets;
    }
    
    function getPoolInfo(string memory market) external view returns (
        uint256 longPool,
        uint256 shortPool,
        uint256 totalVolume,
        uint256 feesCollected,
        uint256 utilization
    ) {
        PoolInfo storage pool = marketPools[market];
        longPool = pool.longPool;
        shortPool = pool.shortPool;
        totalVolume = pool.totalVolume;
        feesCollected = pool.feesCollected;
        utilization = totalPoolValue > 0 ? ((longPool + shortPool) * 100) / totalPoolValue : 0;
    }
    
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(insuranceFund >= amount, "Insufficient insurance fund");
        insuranceFund -= amount;
        require(USDC.transfer(owner(), amount), "Emergency withdrawal failed");
    }
}

