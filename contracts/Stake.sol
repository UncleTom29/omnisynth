// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OmniStake
 * @dev Liquid staking contract with USDC as native asset, earning ETH rewards
 */
contract OmniStake is ERC20, VRFConsumerBaseV2, ReentrancyGuard, Ownable {
    VRFCoordinatorV2Interface public immutable VRF_COORDINATOR;
    uint64 public immutable VRF_SUBSCRIPTION_ID;
    bytes32 public immutable KEY_HASH;
    uint32 public constant CALLBACK_GAS_LIMIT = 200000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 1;
    
    IERC20 public immutable USDC;
    AggregatorV3Interface public immutable ETH_PRICE_FEED;
    
    struct Validator {
        address validatorAddress;
        uint256 stakedAmount;
        uint256 rewardDebt;
        bool isActive;
        uint256 performance; // Performance score out of 100
        uint256 commission; // Commission rate in basis points (100 = 1%)
    }
    
    mapping(uint256 => Validator) public validators;
    mapping(address => uint256) public userStakes;
    mapping(bytes32 => bool) public pendingRequests;
    
    uint256 public validatorCount;
    uint256 public totalStaked; // Total USDC staked
    uint256 public totalETHRewards; // Total ETH rewards accumulated
    uint256 public annualRewardRate = 500; // 5% annual
    uint256 public protocolFee = 1000; // 10% of rewards
    uint256 public lastRewardDistribution;
    uint256 public minStakeAmount = 5e6; // 100 USDC (6 decimals)
    uint256 public unstakingPeriod = 7 days;
    
    struct UnstakeRequest {
        uint256 amount; // USDC amount
        uint256 timestamp;
        bool processed;
    }
    
    mapping(address => UnstakeRequest[]) public unstakeRequests;
    
    uint256 public lastRandomRequest;
    uint256 public selectedValidatorId;
    
    event Staked(address indexed user, uint256 usdcAmount, uint256 shares);
    event UnstakeRequested(address indexed user, uint256 usdcAmount, uint256 requestId);
    event Unstaked(address indexed user, uint256 usdcAmount, uint256 shares);
    event ValidatorAdded(uint256 indexed id, address validator, uint256 commission);
    event ValidatorUpdated(uint256 indexed id, bool isActive, uint256 performance);
    event ETHRewardsDistributed(uint256 ethAmount, uint256 usdcValue, uint256 timestamp);
    event ValidatorSelected(uint256 indexed id, address validator);
    event ProtocolFeeUpdated(uint256 newFee);
    
    error InvalidAmount();
    error InvalidValidator();
    error InsufficientBalance();
    error InvalidUnstakeRequest();
    error UnstakingPeriodNotPassed();
    error RequestAlreadyProcessed();
    error InvalidPriceFeed();
    
    constructor(
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        address _usdc,
        address _ethPriceFeed,
        string memory _name,
        string memory _symbol
    )
        ERC20(_name, _symbol)
        VRFConsumerBaseV2(_vrfCoordinator)
        Ownable(msg.sender)
    {
        VRF_COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        VRF_SUBSCRIPTION_ID = _subscriptionId;
        KEY_HASH = _keyHash;
        USDC = IERC20(_usdc);
        ETH_PRICE_FEED = AggregatorV3Interface(_ethPriceFeed);
        lastRewardDistribution = block.timestamp;
    }
    
    /**
     * @dev Stake USDC and receive liquid staking tokens
     */
    function stake(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount < minStakeAmount) revert InvalidAmount();
        
        uint256 shares = totalSupply() == 0 
            ? usdcAmount 
            : (usdcAmount * totalSupply()) / totalStaked;
        
        USDC.transferFrom(msg.sender, address(this), usdcAmount);
        
        userStakes[msg.sender] += usdcAmount;
        totalStaked += usdcAmount;
        
        _mint(msg.sender, shares);
        emit Staked(msg.sender, usdcAmount, shares);
    }
    
    /**
     * @dev Request unstaking of shares (requires waiting period)
     */
    function requestUnstake(uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientBalance();
        
        uint256 usdcAmount = (shares * totalStaked) / totalSupply();
        
        unstakeRequests[msg.sender].push(UnstakeRequest({
            amount: usdcAmount,
            timestamp: block.timestamp,
            processed: false
        }));
        
        _burn(msg.sender, shares);
        
        emit UnstakeRequested(msg.sender, usdcAmount, unstakeRequests[msg.sender].length - 1);
    }
    
    /**
     * @dev Process unstake request after waiting period
     */
    function processUnstake(uint256 requestId) external nonReentrant {
        UnstakeRequest[] storage requests = unstakeRequests[msg.sender];
        if (requestId >= requests.length) revert InvalidUnstakeRequest();
        
        UnstakeRequest storage request = requests[requestId];
        if (request.processed) revert RequestAlreadyProcessed();
        if (block.timestamp < request.timestamp + unstakingPeriod) {
            revert UnstakingPeriodNotPassed();
        }
        
        if (USDC.balanceOf(address(this)) < request.amount) revert InsufficientBalance();
        
        request.processed = true;
        userStakes[msg.sender] -= request.amount;
        totalStaked -= request.amount;
        
        USDC.transfer(msg.sender, request.amount);
        emit Unstaked(msg.sender, request.amount, 0);
    }
    
    /**
     * @dev Add a new validator
     */
    function addValidator(
        address validatorAddress, 
        uint256 commission
    ) external onlyOwner {
        if (validatorAddress == address(0)) revert InvalidValidator();
        if (commission > 5000) revert InvalidValidator(); // Max 50% commission
        
        validators[validatorCount] = Validator({
            validatorAddress: validatorAddress,
            stakedAmount: 0,
            rewardDebt: 0,
            isActive: true,
            performance: 100,
            commission: commission
        });
        
        emit ValidatorAdded(validatorCount, validatorAddress, commission);
        validatorCount++;
    }
    
    /**
     * @dev Update validator status and performance
     */
    function updateValidator(
        uint256 validatorId,
        bool isActive,
        uint256 performance
    ) external onlyOwner {
        if (validatorId >= validatorCount) revert InvalidValidator();
        if (performance > 100) revert InvalidValidator();
        
        validators[validatorId].isActive = isActive;
        validators[validatorId].performance = performance;
        
        emit ValidatorUpdated(validatorId, isActive, performance);
    }
    
    /**
     * @dev Select random validator using Chainlink VRF
     */
    function selectRandomValidator() external onlyOwner {
        if (validatorCount == 0) revert InvalidValidator();
        
        lastRandomRequest = VRF_COORDINATOR.requestRandomWords(
            KEY_HASH,
            VRF_SUBSCRIPTION_ID,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );
        
        pendingRequests[bytes32(lastRandomRequest)] = true;
    }
    
    /**
     * @dev Chainlink VRF callback
     */
    function fulfillRandomWords(
        uint256 requestId, 
        uint256[] memory randomWords
    ) internal override {
        if (!pendingRequests[bytes32(requestId)]) return;
        
        pendingRequests[bytes32(requestId)] = false;
        
        // Weighted random selection based on performance
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < validatorCount; i++) {
            if (validators[i].isActive) {
                totalWeight += validators[i].performance;
            }
        }
        
        if (totalWeight == 0) return;
        
        uint256 randomWeight = randomWords[0] % totalWeight;
        uint256 currentWeight = 0;
        
        for (uint256 i = 0; i < validatorCount; i++) {
            if (validators[i].isActive) {
                currentWeight += validators[i].performance;
                if (currentWeight >= randomWeight) {
                    selectedValidatorId = i;
                    emit ValidatorSelected(i, validators[i].validatorAddress);
                    break;
                }
            }
        }
    }
    
    /**
     * @dev Get ETH price from Chainlink
     */
    function getETHPrice() public view returns (uint256) {
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
        ) = ETH_PRICE_FEED.latestRoundData();
        
        if (price <= 0 || updatedAt == 0) revert InvalidPriceFeed();
        
        // Convert to 6 decimals (USDC format) from 8 decimals (Chainlink format)
        return uint256(price) / 100;
    }
    
    /**
     * @dev Distribute ETH rewards (convert to USDC value)
     */
    function distributeETHRewards() external payable {
        if (block.timestamp < lastRewardDistribution + 86400) return; // Daily rewards
        if (msg.value == 0) return;
        
        uint256 ethPrice = getETHPrice();
        uint256 rewardValueUSDC = (msg.value * ethPrice) / 1e18;
        
        uint256 protocolFeeAmount = (rewardValueUSDC * protocolFee) / 10000;
        uint256 stakersReward = rewardValueUSDC - protocolFeeAmount;
        
        totalStaked += stakersReward;
        totalETHRewards += msg.value;
        lastRewardDistribution = block.timestamp;
        
        // Send protocol fee in ETH to owner
        if (protocolFeeAmount > 0) {
            uint256 protocolFeeETH = (msg.value * protocolFee) / 10000;
            payable(owner()).transfer(protocolFeeETH);
        }
        
        emit ETHRewardsDistributed(msg.value, rewardValueUSDC, block.timestamp);
    }
    
    /**
     * @dev Update protocol parameters
     */
    function updateProtocolFee(uint256 newFee) external onlyOwner {
        if (newFee > 2000) revert InvalidAmount(); // Max 20%
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }
    
    function updateRewardRate(uint256 newRate) external onlyOwner {
        if (newRate > 2000) revert InvalidAmount(); // Max 20%
        annualRewardRate = newRate;
    }
    
    function updateMinStakeAmount(uint256 newAmount) external onlyOwner {
        minStakeAmount = newAmount;
    }
    
    function updateUnstakingPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod > 30 days) revert InvalidAmount();
        unstakingPeriod = newPeriod;
    }
    
    /**
     * @dev Get staking information for user
     */
    function getStakingInfo(address user) external view returns (
        uint256 _totalStaked,
        uint256 _totalETHRewards,
        uint256 _apy,
        uint256 _userStake,
        uint256 _userShares,
        uint256 _sharePrice,
        uint256 _ethPrice
    ) {
        _totalStaked = totalStaked;
        _totalETHRewards = totalETHRewards;
        _apy = annualRewardRate;
        _userStake = userStakes[user];
        _userShares = balanceOf(user);
        _sharePrice = totalSupply() > 0 ? (totalStaked * 1e18) / totalSupply() : 1e18;
        _ethPrice = getETHPrice();
    }
    
    /**
     * @dev Get user's unstake requests
     */
    function getUserUnstakeRequests(address user) external view returns (
        UnstakeRequest[] memory
    ) {
        return unstakeRequests[user];
    }
    
    /**
     * @dev Emergency withdrawal (only owner)
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        if (amount > USDC.balanceOf(address(this))) revert InsufficientBalance();
        USDC.transfer(owner(), amount);
    }
    
    /**
     * @dev Emergency ETH withdrawal (only owner)
     */
    function emergencyWithdrawETH(uint256 amount) external onlyOwner {
        if (amount > address(this).balance) revert InsufficientBalance();
        payable(owner()).transfer(amount);
    }
    
    /**
     * @dev Receive ETH for staking rewards
     */
    receive() external payable {
        // Handle validator rewards
    }
}