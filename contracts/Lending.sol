// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title OmniLending - USDC Native
 * @dev A decentralized lending protocol where USDC is the native borrowing asset
 * Users deposit ETH as collateral to borrow USDC, or lend USDC to earn ETH rewards
 */
contract OmniLending is ReentrancyGuard, Ownable, Pausable {
    IERC20 public immutable USDC;
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;
    
    struct UserAccount {
        uint256 ethCollateral;          // ETH deposited as collateral
        uint256 usdcBorrowed;          // USDC borrowed amount
        uint256 usdcLent;              // USDC lent to protocol
        uint256 lastBorrowUpdate;      // Last interest update timestamp
        uint256 lastLendUpdate;        // Last reward update timestamp
        uint256 accruedBorrowInterest; // Accumulated interest owed
        uint256 accruedLendRewards;    // Accumulated ETH rewards earned
    }
    
    struct ProtocolState {
        uint256 totalEthCollateral;    // Total ETH locked as collateral
        uint256 totalUsdcBorrowed;     // Total USDC borrowed
        uint256 totalUsdcLent;         // Total USDC lent to protocol
        uint256 totalEthRewards;       // Total ETH available for rewards
        uint256 borrowRate;            // Annual borrow rate (basis points)
        uint256 lendRewardRate;        // Annual ETH reward rate (basis points)
        uint256 lastRateUpdate;        // Last rate update timestamp
    }
    
    mapping(address => UserAccount) public userAccounts;
    ProtocolState public protocolState;
    
    // Protocol parameters
    uint256 public constant COLLATERAL_RATIO = 150; // 150% collateralization required
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% liquidation threshold
    uint256 public constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators
    uint256 public constant BASE_BORROW_RATE = 300; // 3% base annual rate
    uint256 public constant BASE_REWARD_RATE = 500; // 5% base annual ETH reward rate
    uint256 public constant RATE_SLOPE = 2000; // Rate increases by 20% when utilization increases by 100%
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    uint256 public protocolFee = 1000; // 10% of interest goes to protocol
    uint256 public minCollateralAmount = 0.01 ether; // Minimum ETH collateral
    uint256 public minLendAmount = 100e6; // Minimum USDC lending (100 USDC)
    
    address public treasury;
    
    event CollateralDeposited(address indexed user, uint256 ethAmount);
    event CollateralWithdrawn(address indexed user, uint256 ethAmount);
    event UsdcBorrowed(address indexed user, uint256 usdcAmount);
    event UsdcRepaid(address indexed user, uint256 usdcAmount, uint256 interestPaid);
    event UsdcLent(address indexed user, uint256 usdcAmount);
    event UsdcWithdrawnFromLending(address indexed user, uint256 usdcAmount);
    event EthRewardsClaimed(address indexed user, uint256 ethAmount);
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 ethSeized,
        uint256 usdcRepaid
    );
    event RatesUpdated(uint256 borrowRate, uint256 lendRewardRate);
    event ProtocolFeesCollected(uint256 usdcAmount, uint256 ethAmount);
    
    error InsufficientCollateral();
    error ExceedsCollateralCapacity();
    error InsufficientLiquidity();
    error InvalidAmount();
    error PositionHealthy();
    error NoCollateral();
    error NoDebt();
    error NoLending();
    error InsufficientRewards();
    error InvalidPrice();

    constructor(
        address _usdc,
        address _ethUsdPriceFeed,
        address _treasury
    ) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_ethUsdPriceFeed != address(0), "Invalid price feed");
        require(_treasury != address(0), "Invalid treasury");
        
        USDC = IERC20(_usdc);
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);
        treasury = _treasury;
        
        protocolState.borrowRate = BASE_BORROW_RATE;
        protocolState.lendRewardRate = BASE_REWARD_RATE;
        protocolState.lastRateUpdate = block.timestamp;
    }
    
    /**
     * @dev Get current ETH/USD price from Chainlink
     */
    function getEthPrice() public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = ETH_USD_PRICE_FEED.latestRoundData();
        
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt <= 3600, "Price too stale"); // 1 hour max
        
        return uint256(price) * 1e10; // Convert to 18 decimals (price feed is 8 decimals)
    }
    
    /**
     * @dev Deposit ETH as collateral
     */
    function depositCollateral() external payable nonReentrant whenNotPaused {
        if (msg.value < minCollateralAmount) revert InvalidAmount();
        
        _updateUserInterest(msg.sender);
        
        userAccounts[msg.sender].ethCollateral += msg.value;
        protocolState.totalEthCollateral += msg.value;
        
        emit CollateralDeposited(msg.sender, msg.value);
    }
    
    /**
     * @dev Withdraw ETH collateral
     */
    function withdrawCollateral(uint256 ethAmount) external nonReentrant whenNotPaused {
        UserAccount storage account = userAccounts[msg.sender];
        if (account.ethCollateral < ethAmount) revert InsufficientCollateral();
        
        _updateUserInterest(msg.sender);
        
        // Check if withdrawal maintains required collateral ratio
        uint256 remainingCollateral = account.ethCollateral - ethAmount;
        if (account.usdcBorrowed > 0) {
            uint256 maxBorrow = _calculateMaxBorrow(remainingCollateral);
            if (account.usdcBorrowed + account.accruedBorrowInterest > maxBorrow) {
                revert InsufficientCollateral();
            }
        }
        
        account.ethCollateral -= ethAmount;
        protocolState.totalEthCollateral -= ethAmount;
        
        payable(msg.sender).transfer(ethAmount);
        emit CollateralWithdrawn(msg.sender, ethAmount);
    }
    
    /**
     * @dev Borrow USDC against ETH collateral
     */
    function borrowUsdc(uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (usdcAmount == 0) revert InvalidAmount();
        
        UserAccount storage account = userAccounts[msg.sender];
        if (account.ethCollateral == 0) revert NoCollateral();
        
        _updateUserInterest(msg.sender);
        _updateRates();
        
        uint256 maxBorrow = _calculateMaxBorrow(account.ethCollateral);
        uint256 totalDebt = account.usdcBorrowed + account.accruedBorrowInterest + usdcAmount;
        
        if (totalDebt > maxBorrow) revert ExceedsCollateralCapacity();
        if (USDC.balanceOf(address(this)) < usdcAmount) revert InsufficientLiquidity();
        
        account.usdcBorrowed += usdcAmount;
        account.lastBorrowUpdate = block.timestamp;
        protocolState.totalUsdcBorrowed += usdcAmount;
        
        USDC.transfer(msg.sender, usdcAmount);
        emit UsdcBorrowed(msg.sender, usdcAmount);
    }
    
    /**
     * @dev Repay USDC debt
     */
    function repayUsdc(uint256 usdcAmount) external nonReentrant whenNotPaused {
        UserAccount storage account = userAccounts[msg.sender];
        if (account.usdcBorrowed == 0 && account.accruedBorrowInterest == 0) revert NoDebt();
        
        _updateUserInterest(msg.sender);
        
        uint256 totalDebt = account.usdcBorrowed + account.accruedBorrowInterest;
        uint256 repayAmount = usdcAmount > totalDebt ? totalDebt : usdcAmount;
        
        USDC.transferFrom(msg.sender, address(this), repayAmount);
        
        // Pay interest first, then principal
        uint256 interestPaid = 0;
        if (account.accruedBorrowInterest > 0) {
            uint256 interestPayment = repayAmount > account.accruedBorrowInterest ? 
                account.accruedBorrowInterest : repayAmount;
            account.accruedBorrowInterest -= interestPayment;
            interestPaid = interestPayment;
            repayAmount -= interestPayment;
        }
        
        if (repayAmount > 0) {
            account.usdcBorrowed -= repayAmount;
            protocolState.totalUsdcBorrowed -= repayAmount;
        }
        
        emit UsdcRepaid(msg.sender, repayAmount, interestPaid);
    }
    
    /**
     * @dev Lend USDC to earn ETH rewards
     */
    function lendUsdc(uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (usdcAmount < minLendAmount) revert InvalidAmount();
        
        _updateUserRewards(msg.sender);
        
        USDC.transferFrom(msg.sender, address(this), usdcAmount);
        
        userAccounts[msg.sender].usdcLent += usdcAmount;
        userAccounts[msg.sender].lastLendUpdate = block.timestamp;
        protocolState.totalUsdcLent += usdcAmount;
        
        emit UsdcLent(msg.sender, usdcAmount);
    }
    
    /**
     * @dev Withdraw lent USDC
     */
    function withdrawLentUsdc(uint256 usdcAmount) external nonReentrant whenNotPaused {
        UserAccount storage account = userAccounts[msg.sender];
        if (account.usdcLent < usdcAmount) revert NoLending();
        
        _updateUserRewards(msg.sender);
        
        // Check if protocol has enough liquidity
        uint256 availableLiquidity = USDC.balanceOf(address(this)) - protocolState.totalUsdcBorrowed;
        if (availableLiquidity < usdcAmount) revert InsufficientLiquidity();
        
        account.usdcLent -= usdcAmount;
        protocolState.totalUsdcLent -= usdcAmount;
        
        USDC.transfer(msg.sender, usdcAmount);
        emit UsdcWithdrawnFromLending(msg.sender, usdcAmount);
    }
    
    /**
     * @dev Claim ETH rewards from lending
     */
    function claimEthRewards() external nonReentrant whenNotPaused {
        _updateUserRewards(msg.sender);
        
        UserAccount storage account = userAccounts[msg.sender];
        uint256 rewards = account.accruedLendRewards;
        if (rewards == 0) revert InsufficientRewards();
        if (address(this).balance < rewards) revert InsufficientLiquidity();
        
        account.accruedLendRewards = 0;
        protocolState.totalEthRewards -= rewards;
        
        payable(msg.sender).transfer(rewards);
        emit EthRewardsClaimed(msg.sender, rewards);
    }
    
    /**
     * @dev Liquidate undercollateralized position
     */
    function liquidate(address borrower, uint256 usdcAmount) external nonReentrant whenNotPaused {
        require(borrower != msg.sender, "Cannot liquidate self");
        
        UserAccount storage account = userAccounts[borrower];
        _updateUserInterest(borrower);
        
        uint256 totalDebt = account.usdcBorrowed + account.accruedBorrowInterest;
        if (totalDebt == 0) revert NoDebt();
        
        uint256 collateralValue = _getCollateralValueUsd(account.ethCollateral);
        uint256 healthFactor = (collateralValue * BASIS_POINTS) / totalDebt;
        
        if (healthFactor >= LIQUIDATION_THRESHOLD * 100) revert PositionHealthy();
        
        // Calculate ETH to seize
        uint256 ethPrice = getEthPrice();
        uint256 baseEthAmount = (usdcAmount * PRECISION) / ethPrice;
        uint256 bonusEthAmount = (baseEthAmount * LIQUIDATION_BONUS) / 100;
        uint256 totalEthToSeize = baseEthAmount + bonusEthAmount;
        
        require(account.ethCollateral >= totalEthToSeize, "Insufficient collateral");
        require(usdcAmount <= totalDebt, "Repay amount too high");
        
        // Transfer USDC from liquidator
        USDC.transferFrom(msg.sender, address(this), usdcAmount);
        
        // Update borrower's debt
        if (usdcAmount >= account.accruedBorrowInterest) {
            uint256 principalRepay = usdcAmount - account.accruedBorrowInterest;
            account.accruedBorrowInterest = 0;
            account.usdcBorrowed -= principalRepay;
            protocolState.totalUsdcBorrowed -= principalRepay;
        } else {
            account.accruedBorrowInterest -= usdcAmount;
        }
        
        // Transfer ETH collateral to liquidator
        account.ethCollateral -= totalEthToSeize;
        protocolState.totalEthCollateral -= totalEthToSeize;
        
        payable(msg.sender).transfer(totalEthToSeize);
        
        emit Liquidated(borrower, msg.sender, totalEthToSeize, usdcAmount);
    }
    
    /**
     * @dev Calculate maximum USDC that can be borrowed with given ETH collateral
     */
    function _calculateMaxBorrow(uint256 ethAmount) internal view returns (uint256) {
        uint256 collateralValueUsd = _getCollateralValueUsd(ethAmount);
        return (collateralValueUsd * 100) / COLLATERAL_RATIO;
    }
    
    /**
     * @dev Get USD value of ETH collateral
     */
    function _getCollateralValueUsd(uint256 ethAmount) internal view returns (uint256) {
        uint256 ethPrice = getEthPrice();
        return (ethAmount * ethPrice) / PRECISION;
    }
    
    /**
     * @dev Update user's borrow interest
     */
    function _updateUserInterest(address user) internal {
        UserAccount storage account = userAccounts[user];
        if (account.usdcBorrowed == 0) return;
        
        uint256 timeElapsed = block.timestamp - account.lastBorrowUpdate;
        if (timeElapsed == 0) return;
        
        uint256 interest = (account.usdcBorrowed * protocolState.borrowRate * timeElapsed) / 
                          (BASIS_POINTS * SECONDS_PER_YEAR);
        
        account.accruedBorrowInterest += interest;
        account.lastBorrowUpdate = block.timestamp;
    }
    
    /**
     * @dev Update user's lending rewards
     */
    function _updateUserRewards(address user) internal {
        UserAccount storage account = userAccounts[user];
        if (account.usdcLent == 0) return;
        
        uint256 timeElapsed = block.timestamp - account.lastLendUpdate;
        if (timeElapsed == 0) return;
        
        uint256 ethPrice = getEthPrice();
        uint256 rewardValueUsd = (account.usdcLent * protocolState.lendRewardRate * timeElapsed) / 
                                (BASIS_POINTS * SECONDS_PER_YEAR);
        
        uint256 ethReward = (rewardValueUsd * PRECISION) / ethPrice;
        
        account.accruedLendRewards += ethReward;
        account.lastLendUpdate = block.timestamp;
        protocolState.totalEthRewards += ethReward;
    }
    
    /**
     * @dev Update protocol interest and reward rates based on utilization
     */
    function _updateRates() internal {
        if (block.timestamp < protocolState.lastRateUpdate + 1 hours) return;
        
        uint256 totalLiquidity = USDC.balanceOf(address(this));
        if (totalLiquidity == 0) return;
        
        uint256 utilization = (protocolState.totalUsdcBorrowed * BASIS_POINTS) / totalLiquidity;
        
        // Update borrow rate based on utilization
        protocolState.borrowRate = BASE_BORROW_RATE + 
            (utilization * RATE_SLOPE) / BASIS_POINTS;
        
        // Update lend reward rate (inverse relationship with utilization)
        protocolState.lendRewardRate = BASE_REWARD_RATE + 
            ((BASIS_POINTS - utilization) * RATE_SLOPE) / (2 * BASIS_POINTS);
        
        protocolState.lastRateUpdate = block.timestamp;
        
        emit RatesUpdated(protocolState.borrowRate, protocolState.lendRewardRate);
    }
    
    /**
     * @dev Get user account information
     */
    function getUserAccount(address user) external view returns (
        uint256 ethCollateral,
        uint256 usdcBorrowed,
        uint256 usdcLent,
        uint256 accruedInterest,
        uint256 accruedRewards,
        uint256 healthFactor,
        uint256 maxBorrow
    ) {
        UserAccount storage account = userAccounts[user];
        
        ethCollateral = account.ethCollateral;
        usdcBorrowed = account.usdcBorrowed;
        usdcLent = account.usdcLent;
        accruedInterest = account.accruedBorrowInterest;
        accruedRewards = account.accruedLendRewards;
        
        if (account.usdcBorrowed + account.accruedBorrowInterest > 0) {
            uint256 collateralValue = _getCollateralValueUsd(account.ethCollateral);
            uint256 totalDebt = account.usdcBorrowed + account.accruedBorrowInterest;
            healthFactor = (collateralValue * BASIS_POINTS) / totalDebt;
        } else {
            healthFactor = type(uint256).max;
        }
        
        maxBorrow = _calculateMaxBorrow(account.ethCollateral);
    }
    
    /**
     * @dev Get protocol state information
     */
    function getProtocolState() external view returns (
        uint256 totalEthCollateral,
        uint256 totalUsdcBorrowed,
        uint256 totalUsdcLent,
        uint256 borrowRate,
        uint256 lendRewardRate,
        uint256 utilization,
        uint256 ethPrice
    ) {
        totalEthCollateral = protocolState.totalEthCollateral;
        totalUsdcBorrowed = protocolState.totalUsdcBorrowed;
        totalUsdcLent = protocolState.totalUsdcLent;
        borrowRate = protocolState.borrowRate;
        lendRewardRate = protocolState.lendRewardRate;
        
        uint256 totalLiquidity = USDC.balanceOf(address(this));
        utilization = totalLiquidity > 0 ? 
            (protocolState.totalUsdcBorrowed * BASIS_POINTS) / totalLiquidity : 0;
        
        ethPrice = getEthPrice();
    }
    
    /**
     * @dev Owner functions
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }
    
    function updateProtocolParameters(
        uint256 _protocolFee,
        uint256 _minCollateralAmount,
        uint256 _minLendAmount
    ) external onlyOwner {
        require(_protocolFee <= 2000, "Protocol fee too high"); // Max 20%
        protocolFee = _protocolFee;
        minCollateralAmount = _minCollateralAmount;
        minLendAmount = _minLendAmount;
    }
    
    /**
     * @dev Collect protocol fees
     */
    function collectProtocolFees() external onlyOwner {
        uint256 usdcBalance = USDC.balanceOf(address(this));
        uint256 excessUsdc = usdcBalance - protocolState.totalUsdcLent;
        
        if (excessUsdc > 0) {
            uint256 feeAmount = (excessUsdc * protocolFee) / BASIS_POINTS;
            if (feeAmount > 0) {
                USDC.transfer(treasury, feeAmount);
            }
        }
        
        uint256 ethBalance = address(this).balance;
        uint256 excessEth = ethBalance - protocolState.totalEthCollateral - protocolState.totalEthRewards;
        
        if (excessEth > 0) {
            payable(treasury).transfer(excessEth);
        }
        
        emit ProtocolFeesCollected(excessUsdc, excessEth);
    }
    
    /**
     * @dev Emergency withdrawal (only owner)
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).transfer(owner(), amount);
        }
    }
    
    /**
     * @dev Receive ETH for rewards pool
     */
    receive() external payable {
        // ETH sent to contract goes to rewards pool
    }
}