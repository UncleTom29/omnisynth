// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title OmniRouter
 * @dev Central router contract for the OmniSynth protocol
 */
contract OmniRouter is Ownable, ReentrancyGuard, Pausable, AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");
    
    struct ContractInfo {
        address contractAddress;
        bool isActive;
        uint256 version;
        bytes32 contractHash;
    }
    
    struct ProtocolStats {
        uint256 totalTVL;
        uint256 totalVolume24h;
        uint256 totalUsers;
        uint256 totalFees;
        uint256 lastUpdated;
    }
    
    struct MultiChainOperation {
        uint64 chainId;
        address target;
        bytes callData;
        uint256 value;
        bool executed;
    }
    
    mapping(string => ContractInfo) public contracts;
    mapping(address => bool) public authorizedCallers;
    mapping(bytes32 => MultiChainOperation[]) public multiChainOperations;
    mapping(address => uint256) public userLastActivity;
    mapping(string => uint256) public contractFees;
    
    ProtocolStats public protocolStats;
    
    string[] public contractNames;
    uint256 public totalOperations;
    uint256 public operationFee = 100; // 1% in basis points
    address public feeCollector;
    
    event ContractUpdated(string indexed name, address indexed newAddress, uint256 version);
    event OperationExecuted(bytes32 indexed operationId, address indexed user, string operation);
    event MultiChainOperationExecuted(bytes32 indexed operationId, uint64[] chains, uint256 totalValue);
    event FeeCollected(address indexed user, string operation, uint256 amount);
    event EmergencyPaused(address indexed admin, string reason);
    event ProtocolStatsUpdated(uint256 tvl, uint256 volume, uint256 users, uint256 fees);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    
    error ContractNotFound(string name);
    error InvalidContractAddress(address addr);
    error OperationFailed(string reason);
    error InsufficientFee(uint256 required, uint256 provided);
    error UnauthorizedCaller(address caller);
    error InvalidOperation();
    error ChainNotSupported(uint64 chainId);
    
    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender] && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedCaller(msg.sender);
        }
        _;
    }
    
    modifier validContract(string memory name) {
        if (contracts[name].contractAddress == address(0)) {
            revert ContractNotFound(name);
        }
        if (!contracts[name].isActive) {
            revert ContractNotFound(name);
        }
        _;
    }
    
    constructor(address _feeCollector) Ownable(msg.sender) {
        feeCollector = _feeCollector;
        authorizedCallers[msg.sender] = true;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(STRATEGY_MANAGER_ROLE, msg.sender);
    }
    
    /**
     * @dev Set or update a contract address
     */
    function setContract(
        string memory name,
        address contractAddress,
        uint256 version
    ) external onlyOwner {
        if (contractAddress == address(0)) {
            revert InvalidContractAddress(contractAddress);
        }
        
        // Add to contract names if new
        if (contracts[name].contractAddress == address(0)) {
            contractNames.push(name);
        }
        
        contracts[name] = ContractInfo({
            contractAddress: contractAddress,
            isActive: true,
            version: version,
            contractHash: keccak256(abi.encodePacked(contractAddress, version))
        });
        
        emit ContractUpdated(name, contractAddress, version);
    }
    
    /**
     * @dev Execute a single operation on a specific contract
     */
    function executeOperation(
        string memory contractName,
        bytes memory callData,
        uint256 value
    ) external payable nonReentrant whenNotPaused validContract(contractName) {
        _collectFee(msg.sender, contractName, value);
        
        address target = contracts[contractName].contractAddress;
        
        (bool success, bytes memory result) = target.call{value: value}(callData);
        if (!success) {
            revert OperationFailed(_getRevertMsg(result));
        }
        
        userLastActivity[msg.sender] = block.timestamp;
        totalOperations++;
        
        bytes32 operationId = keccak256(abi.encodePacked(
            msg.sender,
            contractName,
            callData,
            block.timestamp
        ));
        
        emit OperationExecuted(operationId, msg.sender, contractName);
    }
    
    /**
     * @dev Execute multiple operations atomically
     */
    function executeMultipleOperations(
        string[] memory opContractNames,
        bytes[] memory callDataArray,
        uint256[] memory values
    ) external payable nonReentrant whenNotPaused {
        if (opContractNames.length != callDataArray.length || 
            callDataArray.length != values.length) {
            revert InvalidOperation();
        }
        
        uint256 totalValue = 0;
        for (uint256 i = 0; i < values.length; i++) {
            totalValue += values[i];
        }
        
        _collectFee(msg.sender, "MultiOp", totalValue);
        
        for (uint256 i = 0; i < opContractNames.length; i++) {
            if (contracts[opContractNames[i]].contractAddress == address(0) ||
                !contracts[opContractNames[i]].isActive) {
                revert ContractNotFound(opContractNames[i]);
            }
            
            address target = contracts[opContractNames[i]].contractAddress;
            (bool success, bytes memory result) = target.call{value: values[i]}(callDataArray[i]);
            
            if (!success) {
                revert OperationFailed(_getRevertMsg(result));
            }
        }
        
        userLastActivity[msg.sender] = block.timestamp;
        totalOperations++;
        
        bytes32 operationId = keccak256(abi.encode(
            msg.sender,
            opContractNames,
            callDataArray,
            block.timestamp
        ));
        
        emit OperationExecuted(operationId, msg.sender, "MultipleOperations");
    }
    
    /**
     * @dev Execute cross-chain strategy (placeholder for future CCIP integration)
     */
    function executeMultiChainStrategy(
        uint64[] memory chains,
        address[] memory targets,
        bytes[] memory callDataArray,
        uint256[] memory values
    ) external payable nonReentrant whenNotPaused onlyRole(STRATEGY_MANAGER_ROLE) {
        if (chains.length != targets.length || 
            targets.length != callDataArray.length ||
            callDataArray.length != values.length) {
            revert InvalidOperation();
        }
        
        uint256 totalValue = 0;
        for (uint256 i = 0; i < values.length; i++) {
            totalValue += values[i];
        }
        
        bytes32 operationId = keccak256(abi.encodePacked(
            msg.sender,
            chains,
            targets,
            block.timestamp
        ));
        
        // Store operations for tracking
        for (uint256 i = 0; i < chains.length; i++) {
            multiChainOperations[operationId].push(MultiChainOperation({
                chainId: chains[i],
                target: targets[i],
                callData: callDataArray[i],
                value: values[i],
                executed: false
            }));
        }
        
        // In a full implementation, this would trigger CCIP messages
        // For now, we mark as executed
        for (uint256 i = 0; i < multiChainOperations[operationId].length; i++) {
            multiChainOperations[operationId][i].executed = true;
        }
        
        emit MultiChainOperationExecuted(operationId, chains, totalValue);
    }
    
    /**
     * @dev Get protocol statistics
     */
    function getProtocolStats() external view returns (ProtocolStats memory) {
        return protocolStats;
    }
    
    /**
     * @dev Update protocol statistics (only authorized callers)
     */
    function updateProtocolStats(
        uint256 totalTVL,
        uint256 totalVolume24h,
        uint256 totalUsers,
        uint256 totalFees
    ) external onlyAuthorized {
        protocolStats = ProtocolStats({
            totalTVL: totalTVL,
            totalVolume24h: totalVolume24h,
            totalUsers: totalUsers,
            totalFees: totalFees,
            lastUpdated: block.timestamp
        });
        
        emit ProtocolStatsUpdated(totalTVL, totalVolume24h, totalUsers, totalFees);
    }
    
    /**
     * @dev Get contract information
     */
    function getContractInfo(string memory name) external view returns (ContractInfo memory) {
        return contracts[name];
    }
    
    /**
     * @dev Get all contract names
     */
    function getAllContractNames() external view returns (string[] memory) {
        return contractNames;
    }
    
    /**
     * @dev Set authorized caller status
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerUpdated(caller, authorized);
    }
    
    /**
     * @dev Update operation fee
     */
    function setOperationFee(uint256 newFee) external onlyOwner {
        if (newFee > 1000) revert InvalidOperation(); // Max 10%
        operationFee = newFee;
    }
    
    /**
     * @dev Update fee collector
     */
    function setFeeCollector(address newCollector) external onlyOwner {
        if (newCollector == address(0)) revert InvalidContractAddress(newCollector);
        feeCollector = newCollector;
    }
    
    /**
     * @dev Pause contract operations
     */
    function pause(string memory reason) external onlyRole(OPERATOR_ROLE) {
        _pause();
        emit EmergencyPaused(msg.sender, reason);
    }
    
    /**
     * @dev Unpause contract operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Deactivate a contract
     */
    function deactivateContract(string memory name) external onlyOwner {
        if (contracts[name].contractAddress == address(0)) {
            revert ContractNotFound(name);
        }
        contracts[name].isActive = false;
    }
    
    /**
     * @dev Emergency withdrawal
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).transfer(owner(), amount);
        }
    }
    
    /**
     * @dev Get user activity info
     */
    function getUserActivity(address user) external view returns (
        uint256 lastActivity,
        bool isActive
    ) {
        lastActivity = userLastActivity[user];
        isActive = lastActivity > 0 && (block.timestamp - lastActivity) < 30 days;
    }
    
    /**
     * @dev Collect operation fees
     */
    function _collectFee(address user, string memory operation, uint256 operationValue) internal {
        if (operationFee > 0) {
            uint256 fee = (operationValue * operationFee) / 10000;
            if (msg.value < fee) {
                revert InsufficientFee(fee, msg.value);
            }
            
            if (fee > 0) {
                payable(feeCollector).transfer(fee);
                contractFees[operation] += fee;
                emit FeeCollected(user, operation, fee);
            }
        }
    }
    
    /**
     * @dev Extract revert message from failed call
     */
    function _getRevertMsg(bytes memory returnData) internal pure returns (string memory) {
        if (returnData.length < 68) return "Operation reverted";
        
        assembly {
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string));
    }
    
    /**
     * @dev Receive ETH
     */
    receive() external payable {}
}