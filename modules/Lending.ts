import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const LendingModule = buildModule("OmniLendingModule", (m) => {
  const deployer = m.getAccount(0);
  const treasury = '0x99B56175fC807e35493460DFEf9192211d598F37'; // Second account as treasury

  // Contract addresses for Sepolia testnet
  const USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
  const ETH_USD_PRICE_FEED = "0x694AA1769357215DE4FAC081bf1f309aDC325306";

  // Deploy OmniLending
  const omniLending = m.contract("OmniLending", [
    USDC_ADDRESS,
    ETH_USD_PRICE_FEED,
    treasury
  ], {
    id: "OmniLending",
    from: deployer
  });

  // Update protocol parameters for better user experience
  const updateProtocolParams = m.call(omniLending, "updateProtocolParameters", [
    500,              // 5% protocol fee (reduced from 10%)
    0.005 * 1e18,     // 0.005 ETH minimum collateral
    5e6              // 5 USDC minimum lending (reduced from 100)
  ], {
    id: "updateLendingProtocolParams",
    after: [omniLending]
  });


  return { 
    omniLending
  };
});

export default LendingModule;