import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const OracleModule = buildModule("OracleModule", (m) => {
  // Get the deployer account
  const deployer = m.getAccount(0);

  // Deploy the Oracle contract
  const oracle = m.contract("OmniPriceOracle", [deployer]);

  // Add price feeds for major assets
  // These are Chainlink price feed addresses for Sepolia testnet
  const priceFeeds = {
    "BTC/USD": "0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43",
    "ETH/USD": "0x694AA1769357215DE4FAC081bf1f309aDC325306", 
    "LINK/USD": "0xc59E3633BAAC79493d908e63626716e204A45EdF"
  };

  // Add price feeds after deployment
  Object.entries(priceFeeds).forEach(([symbol, feedAddress]) => {
    m.call(oracle, "addPriceFeed", [symbol, feedAddress], {
      id: `addPriceFeed_${symbol.replace("/", "_")}`
    });
  });

  return { oracle };
});

export default OracleModule;