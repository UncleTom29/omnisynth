// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OmniVault
 * @dev AI-powered vault that uses Chainlink Functions for strategy optimization
 * and VRF for randomized rebalancing timing
 */
contract OmniVault is FunctionsClient, VRFConsumerBaseV2, ReentrancyGuard, Ownable {
    using FunctionsRequest for FunctionsRequest.Request;

    // Chainlink VRF Configuration
    VRFCoordinatorV2Interface public immutable VRF_COORDINATOR;
    uint64 public immutable VRF_SUBSCRIPTION_ID;
    bytes32 public constant KEY_HASH = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;
    uint32 public constant CALLBACK_GAS_LIMIT = 200000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 1;

    // Vault Configuration
    IERC20 public immutable USDC;
    
    struct VaultStrategy {
        string name;
        uint256 targetAllocation; // Percentage in basis points (10000 = 100%)
        uint256 currentAllocation;
        bool isActive;
        uint256 lastRebalance;
        uint256 performanceScore; // 0-100
    }

    struct UserInfo {
        uint256 shares;
        uint256 depositTimestamp;
        uint256 lastRewardClaim;
    }

    mapping(address => UserInfo) public userInfo;
    mapping(uint256 => VaultStrategy) public strategies;
    mapping(bytes32 => bool) public pendingRequests;
    
    uint256 public totalShares;
    uint256 public totalAssets;
    uint256 public strategyCount;
    uint256 public performanceFee = 2000; // 20% in basis points
    uint256 public managementFee = 200; // 2% annual
    uint256 public lastFeeCollection;
    uint256 public minDeposit = 5e6; // 100 USDC
    uint256 public maxTotalAssets = 10000000e6; // 10M USDC cap

    // AI Strategy Configuration
    string public aiStrategySource = 
        "const marketData = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,chainlink&vs_currencies=usd');"
        "const data = await marketData.json();"
        "const btcPrice = data.bitcoin.usd;"
        "const ethPrice = data.ethereum.usd;"
        "const linkPrice = data.chainlink.usd;"
        "let allocation = 3333;" // Default equal allocation
        "if (btcPrice > 50000) allocation += 1000;"
        "if (ethPrice > 3000) allocation += 500;"
        "return Functions.encodeUint256(Math.min(allocation, 10000));";

    bytes32 public lastRequestId;
    uint256 public lastStrategyUpdate;
    uint256 public nextRebalanceTime;

    // Events
    event SharesMinted(address indexed user, uint256 shares, uint256 assets);
    event SharesRedeemed(address indexed user, uint256 shares, uint256 assets);
    event StrategyUpdated(uint256 indexed strategyId, uint256 newAllocation);
    event RebalanceExecuted(uint256 totalValue, uint256 timestamp);
    event FeesCollected(uint256 performanceFee, uint256 managementFee);
    event AIStrategyRequested(bytes32 indexed requestId);
    event EmergencyWithdrawal(address indexed user, uint256 amount);

    constructor(
        address _router,
        address _vrfCoordinator,
        uint64 _subscriptionId,
        address _usdc
    ) 
        FunctionsClient(_router) 
        VRFConsumerBaseV2(_vrfCoordinator) 
        Ownable(msg.sender)
    {
        VRF_COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        VRF_SUBSCRIPTION_ID = _subscriptionId;
        USDC = IERC20(_usdc);
        lastFeeCollection = block.timestamp;
        lastStrategyUpdate = block.timestamp;
        
        // Initialize default strategies
        _initializeStrategies();
    }

    function _initializeStrategies() internal {
        strategies[0] = VaultStrategy({
            name: "Conservative DeFi",
            targetAllocation: 4000, // 40%
            currentAllocation: 4000,
            isActive: true,
            lastRebalance: block.timestamp,
            performanceScore: 75
        });

        strategies[1] = VaultStrategy({
            name: "Balanced Growth",
            targetAllocation: 3500, // 35%
            currentAllocation: 3500,
            isActive: true,
            lastRebalance: block.timestamp,
            performanceScore: 80
        });

        strategies[2] = VaultStrategy({
            name: "Aggressive Yield",
            targetAllocation: 2500, // 25%
            currentAllocation: 2500,
            isActive: true,
            lastRebalance: block.timestamp,
            performanceScore: 85
        });

        strategyCount = 3;
    }

    /**
     * @dev Deposit USDC and receive vault shares
     */
    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        require(assets >= minDeposit, "Below minimum deposit");
        require(totalAssets + assets <= maxTotalAssets, "Exceeds vault cap");
        require(assets > 0, "Amount must be positive");

        // Calculate shares to mint
        shares = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;

        // Transfer USDC from user
        USDC.transferFrom(msg.sender, address(this), assets);

        // Update state
        userInfo[msg.sender].shares += shares;
        userInfo[msg.sender].depositTimestamp = block.timestamp;
        totalShares += shares;
        totalAssets += assets;

        emit SharesMinted(msg.sender, shares, assets);
        return shares;
    }

    /**
     * @dev Redeem shares for USDC
     */
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Shares must be positive");
        require(userInfo[msg.sender].shares >= shares, "Insufficient shares");

        // Calculate assets to return
        assets = (shares * totalAssets) / totalShares;
        
        // Apply early withdrawal penalty if within 7 days
        if (block.timestamp < userInfo[msg.sender].depositTimestamp + 7 days) {
            uint256 penalty = assets * 50 / 10000; // 0.5% penalty
            assets -= penalty;
        }

        // Update state
        userInfo[msg.sender].shares -= shares;
        totalShares -= shares;
        totalAssets -= assets;

        // Transfer USDC to user
        USDC.transfer(msg.sender, assets);

        emit SharesRedeemed(msg.sender, shares, assets);
        return assets;
    }

    /**
     * @dev Execute AI-powered strategy optimization
     */
    function executeAIStrategy() external onlyOwner {
        require(block.timestamp >= lastStrategyUpdate + 1 hours, "Too soon for update");
        
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(aiStrategySource);
        
        lastRequestId = _sendRequest(
            req.encodeCBOR(),
            VRF_SUBSCRIPTION_ID,
            300000,
            0x0
        );
        
        pendingRequests[lastRequestId] = true;
        emit AIStrategyRequested(lastRequestId);
    }

    /**
     * @dev Handle Chainlink Functions response
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        require(pendingRequests[requestId], "Invalid request");
        pendingRequests[requestId] = false;

        if (err.length > 0) {
            // Handle error - could emit event or use fallback strategy
            return;
        }

        uint256 newAllocation = abi.decode(response, (uint256));
        _rebalanceStrategy(newAllocation);
        lastStrategyUpdate = block.timestamp;
    }

    /**
     * @dev Internal rebalancing logic
     */
    function _rebalanceStrategy(uint256 primaryAllocation) internal {
        // Update primary strategy allocation
        if (primaryAllocation <= 10000) {
            strategies[0].targetAllocation = primaryAllocation;
            
            // Distribute remaining allocation among other strategies
            uint256 remaining = 10000 - primaryAllocation;
            if (strategyCount > 1) {
                strategies[1].targetAllocation = remaining * 60 / 100;
                if (strategyCount > 2) {
                    strategies[2].targetAllocation = remaining * 40 / 100;
                }
            }
        }

        _executeRebalance();
    }

    /**
     * @dev Execute the actual rebalancing
     */
    function _executeRebalance() internal {
        // In a real implementation, this would interact with various DeFi protocols
        // For now, we'll update the current allocations to match targets
        
        for (uint256 i = 0; i < strategyCount; i++) {
            strategies[i].currentAllocation = strategies[i].targetAllocation;
            strategies[i].lastRebalance = block.timestamp;
        }

        emit RebalanceExecuted(totalAssets, block.timestamp);
    }

    /**
     * @dev Request random rebalancing timing using VRF
     */
    function requestRandomRebalance() external onlyOwner {
        VRF_COORDINATOR.requestRandomWords(
            KEY_HASH,
            VRF_SUBSCRIPTION_ID,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );
    }

    /**
     * @dev Handle VRF response for random rebalancing
     */
    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] memory randomWords
    ) internal override {
        // Use randomness to determine next rebalance time (1-24 hours)
        uint256 randomHours = (randomWords[0] % 24) + 1;
        nextRebalanceTime = block.timestamp + (randomHours * 1 hours);
        
        // Could also use randomness for strategy selection or risk adjustment
        uint256 riskAdjustment = (randomWords[0] % 20) + 90; // 90-110% of normal allocation
        
        for (uint256 i = 0; i < strategyCount; i++) {
            if (strategies[i].isActive) {
                strategies[i].performanceScore = riskAdjustment;
            }
        }
    }

    /**
     * @dev Collect management and performance fees
     */
    function collectFees() external onlyOwner {
        uint256 timeElapsed = block.timestamp - lastFeeCollection;
        
        // Calculate annual management fee
        uint256 annualFee = (totalAssets * managementFee) / 10000;
        uint256 mgmtFeeAmount = (annualFee * timeElapsed) / 365 days;
        
        // Performance fee would be calculated based on returns above benchmark
        // For simplicity, we'll use a fixed percentage of AUM
        uint256 perfFeeAmount = (totalAssets * performanceFee * timeElapsed) / (10000 * 365 days);
        
        uint256 totalFeeAmount = mgmtFeeAmount + perfFeeAmount;
        
        if (totalFeeAmount > 0 && totalAssets > totalFeeAmount) {
            totalAssets -= totalFeeAmount;
            USDC.transfer(owner(), totalFeeAmount);
            lastFeeCollection = block.timestamp;
            
            emit FeesCollected(perfFeeAmount, mgmtFeeAmount);
        }
    }

    /**
     * @dev Emergency withdrawal for owner
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= USDC.balanceOf(address(this)), "Insufficient balance");
        USDC.transfer(owner(), amount);
        emit EmergencyWithdrawal(owner(), amount);
    }

    /**
     * @dev Update strategy parameters
     */
    function updateStrategy(
        uint256 strategyId,
        string memory name,
        uint256 targetAllocation,
        bool isActive
    ) external onlyOwner {
        require(strategyId < strategyCount, "Invalid strategy ID");
        
        strategies[strategyId].name = name;
        strategies[strategyId].targetAllocation = targetAllocation;
        strategies[strategyId].isActive = isActive;
        
        emit StrategyUpdated(strategyId, targetAllocation);
    }

    /**
     * @dev Get vault information
     */
    function getVaultInfo() external view returns (
        uint256 _totalAssets,
        uint256 _totalShares,
        uint256 _sharePrice,
        uint256 _lastUpdate,
        uint256 _nextRebalance
    ) {
        _totalAssets = totalAssets;
        _totalShares = totalShares;
        _sharePrice = totalShares > 0 ? (totalAssets * 1e18) / totalShares : 1e18;
        _lastUpdate = lastStrategyUpdate;
        _nextRebalance = nextRebalanceTime;
    }

    /**
     * @dev Get user information
     */
    function getUserInfo(address user) external view returns (
        uint256 shares,
        uint256 assets,
        uint256 depositTime
    ) {
        UserInfo memory info = userInfo[user];
        shares = info.shares;
        assets = totalShares > 0 ? (shares * totalAssets) / totalShares : 0;
        depositTime = info.depositTimestamp;
    }

    /**
     * @dev Get strategy information
     */
    function getStrategy(uint256 strategyId) external view returns (
        string memory name,
        uint256 targetAllocation,
        uint256 currentAllocation,
        bool isActive,
        uint256 lastRebalance,
        uint256 performanceScore
    ) {
        require(strategyId < strategyCount, "Invalid strategy ID");
        VaultStrategy memory strategy = strategies[strategyId];
        
        return (
            strategy.name,
            strategy.targetAllocation,
            strategy.currentAllocation,
            strategy.isActive,
            strategy.lastRebalance,
            strategy.performanceScore
        );
    }

    /**
     * @dev Update AI strategy source code
     */
    function updateAIStrategy(string memory newSource) external onlyOwner {
        aiStrategySource = newSource;
    }

    /**
     * @dev Update fee parameters
     */
    function updateFees(uint256 _performanceFee, uint256 _managementFee) external onlyOwner {
        require(_performanceFee <= 3000, "Performance fee too high"); // Max 30%
        require(_managementFee <= 500, "Management fee too high"); // Max 5%
        
        performanceFee = _performanceFee;
        managementFee = _managementFee;
    }
}