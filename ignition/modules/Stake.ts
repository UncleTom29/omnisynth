import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const StakeModule = buildModule("OmniStakeModule", (m) => {
  const deployer = m.getAccount(0);

  // Contract addresses for Sepolia testnet
  const VRF_COORDINATOR = "0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625";
  const USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
  const ETH_USD_PRICE_FEED = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
  
  // VRF Configuration for Sepolia
  const VRF_SUBSCRIPTION_ID =12434; // Replace with actual subscription ID
  const KEY_HASH = "0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c";

  // Deploy OmniStake
  const omniStake = m.contract("OmniStake", [
    VRF_COORDINATOR,
    VRF_SUBSCRIPTION_ID,
    KEY_HASH,
    USDC_ADDRESS,
    ETH_USD_PRICE_FEED,
    "Omni Staked USDC",  // Token name
    "osUSDC"             // Token symbol
  ], {
    id: "OmniStake",
    from: deployer
  });

  // Add initial validators
  const validator1Address = '0x99B56175fC807e35493460DFEf9192211d598F37'; // Third account as validator
  const validator2Address = '0xA79364f4F844Eedd511d7Bc25aD2F611CC9Af5c6'; // Fourth account as validator
  const validator3Address = '0x59ee649f1D4437374B42Dbe3897AB894937F2744'; // Fifth account as validator

  const addValidator1 = m.call(omniStake, "addValidator", [
    validator1Address,
    500  // 5% commission
  ], {
    id: "addValidator1",
    after: [omniStake]
  });

  const addValidator2 = m.call(omniStake, "addValidator", [
    validator2Address,
    300  // 3% commission
  ], {
    id: "addValidator2",
    after: [addValidator1]
  });

  const addValidator3 = m.call(omniStake, "addValidator", [
    validator3Address,
    400  // 4% commission
  ], {
    id: "addValidator3",
    after: [addValidator2]
  });

  // Update protocol parameters for better user experience
  const updateProtocolFee = m.call(omniStake, "updateProtocolFee", [
    800  // 8% protocol fee (reduced from 10%)
  ], {
    id: "updateStakeProtocolFee",
    after: [addValidator3]
  });

  const updateMinStakeAmount = m.call(omniStake, "updateMinStakeAmount", [
    5e6  // 5 USDC minimum stake (reduced from 100)
  ], {
    id: "updateMinStakeAmount",
    after: [updateProtocolFee]
  });

  const updateUnstakingPeriod = m.call(omniStake, "updateUnstakingPeriod", [
    3 * 24 * 60 * 60  // 3 days unstaking period (reduced from 7)
  ], {
    id: "updateUnstakingPeriod",
    after: [updateMinStakeAmount]
  });


  return { 
    omniStake
  };
});

export default StakeModule;