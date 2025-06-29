import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const VaultModule = buildModule("OmniVaultModuleV2", (m) => {
  const deployer = m.getAccount(0);

  // Contract addresses for Sepolia testnet
  const CHAINLINK_FUNCTIONS_ROUTER = "0xb83E47C2bC239B3bf370bc41e1459A34b41238D0";
  const VRF_COORDINATOR = "0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625";
  const USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
  
  // VRF Subscription ID (needs to be created beforehand)
  const VRF_SUBSCRIPTION_ID = 12434; // Replace with actual subscription ID

  // Deploy OmniVault
  const omniVault = m.contract("OmniVault", [
    CHAINLINK_FUNCTIONS_ROUTER,
    VRF_COORDINATOR,
    VRF_SUBSCRIPTION_ID,
    USDC_ADDRESS
  ], {
    id: "OmniVault",
    from: deployer
  });

  // Initialize strategies (already done in constructor)
  
  // Set up initial AI strategy (optional - uses default from contract)
  const updateAIStrategy = m.call(omniVault, "updateAIStrategy", [
    `const marketData = await Functions.makeHttpRequest({
      url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,chainlink&vs_currencies=usd"
    });
    
    if (marketData.error) {
      throw Error("API request failed");
    }
    
    const data = marketData.data;
    const btcPrice = data.bitcoin.usd;
    const ethPrice = data.ethereum.usd;
    const linkPrice = data.chainlink.usd;
    
    let allocation = 4000; // Base 40% allocation
    
    // Dynamic allocation based on market conditions
    if (btcPrice > 50000) allocation += 500;
    if (ethPrice > 3000) allocation += 300;
    if (linkPrice > 15) allocation += 200;
    
    return Functions.encodeUint256(Math.min(allocation, 6000));`
  ], {
    id: "updateVaultAIStrategy",
    after: [omniVault]
  });

  // Update fees to more reasonable levels
  const updateFees = m.call(omniVault, "updateFees", [
    1500, // 15% performance fee
    150   // 1.5% management fee
  ], {
    id: "updateVaultFees",
    after: [omniVault]
  });

  return { 
    omniVault
  };
});

export default VaultModule;