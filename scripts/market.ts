// scripts/marketManagement.ts
import { ethers } from "hardhat";
import { config } from "dotenv";

config();

// Contract addresses (replace with your deployed addresses)
const TRADING_ENGINE_ADDRESS = "0x..."; // Your deployed TradingEngine address
const LIQUIDITY_POOL_ADDRESS = "0x..."; // Your deployed Pool address
const ORACLE_ADDRESS = "0x..."; // Your deployed Oracle address

// Chainlink Price Feed addresses for different networks
const CHAINLINK_FEEDS = {
  sepolia: {
    "BTC/USD": "0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43",
    "ETH/USD": "0x694AA1769357215DE4FAC081bf1f309aDC325306",
    "LINK/USD": "0xc59E3633BAAC79493d908e63626716e204A45EdF"
  },
  baseSepolia: {
    "BTC/USD": "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1",
    "ETH/USD": "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1",
    "LINK/USD": "0xb113F5A928BCfF189C998ab20d753a47F9dE5A61"
  },
  arbitrumSepolia: {
    "BTC/USD": "0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69",
    "ETH/USD": "0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165",
    "LINK/USD": "0xb113F5A928BCfF189C998ab20d753a47F9dE5A61"
  }
};

async function getContractInstances() {
  const [signer] = await ethers.getSigners();
  
  const TradingEngine = await ethers.getContractAt("OmniTradingEngine", TRADING_ENGINE_ADDRESS, signer);
  const LiquidityPool = await ethers.getContractAt("OmniLiquidityPool", LIQUIDITY_POOL_ADDRESS, signer);
  const Oracle = await ethers.getContractAt("OmniPriceOracle", ORACLE_ADDRESS, signer);
  
  return { TradingEngine, LiquidityPool, Oracle, signer };
}

async function addNewMarket(market: string, priceFeedAddress: string) {
  console.log(`\n🏪 Adding new market: ${market}`);
  
  const { TradingEngine, LiquidityPool, Oracle } = await getContractInstances();
  
  try {
    // Add market to trading engine
    const tx1 = await TradingEngine.addMarket(market);
    await tx1.wait();
    console.log(`✅ Market ${market} added to TradingEngine`);
    
    // Add market to liquidity pool
    const tx2 = await LiquidityPool.addMarket(market);
    await tx2.wait();
    console.log(`✅ Market ${market} added to LiquidityPool`);
    
    // Add price feed to oracle
    const tx3 = await Oracle.addPriceFeed(market.split('/')[0], priceFeedAddress);
    await tx3.wait();
    console.log(`✅ Price feed for ${market} added to Oracle`);
    
    // Add price feed to trading engine
    const tx4 = await TradingEngine.addPriceFeed(market, priceFeedAddress);
    await tx4.wait();
    console.log(`✅ Price feed for ${market} added to TradingEngine`);
    
    console.log(`🎉 Market ${market} successfully added to all contracts!`);
    
  } catch (error) {
    console.error(`❌ Error adding market ${market}:`, error);
  }
}

async function setupInitialMarkets() {
  console.log("🚀 Setting up initial markets...");
  
  const network = await ethers.provider.getNetwork();
  const networkName = getNetworkName(network.chainId);
  
  if (!CHAINLINK_FEEDS[networkName as keyof typeof CHAINLINK_FEEDS]) {
    console.error(`❌ Network ${networkName} not supported`);
    return;
  }
  
  const feeds = CHAINLINK_FEEDS[networkName as keyof typeof CHAINLINK_FEEDS];
  
  for (const [market, feedAddress] of Object.entries(feeds)) {
    await addNewMarket(market, feedAddress);
    await new Promise(resolve => setTimeout(resolve, 2000)); // Wait 2 seconds between operations
  }
}

async function checkMarketStatus() {
  console.log("📊 Checking market status...");
  
  const { LiquidityPool } = await getContractInstances();
  
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];
  
  for (const market of markets) {
    try {
      const poolInfo = await LiquidityPool.getPoolInfo(market);
      console.log(`\n📈 ${market}:`);
      console.log(`  Long Pool: ${ethers.formatUnits(poolInfo.longPool, 6)} USDC`);
      console.log(`  Short Pool: ${ethers.formatUnits(poolInfo.shortPool, 6)} USDC`);
      console.log(`  Total Volume: ${ethers.formatUnits(poolInfo.totalVolume, 6)} USDC`);
      console.log(`  Fees Collected: ${ethers.formatUnits(poolInfo.feesCollected, 6)} USDC`);
      console.log(`  Utilization: ${poolInfo.utilization}%`);
    } catch (error) {
      if (error instanceof Error) {
        console.log(`❌ Error getting info for ${market}:`, error.message);
      } else {
        console.log(`❌ Error getting info for ${market}:`, error);
      }
    }
  }
}

async function checkPrices() {
  console.log("💰 Checking current prices...");
  
  const { TradingEngine } = await getContractInstances();
  
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];
  
  for (const market of markets) {
    try {
      const priceData = await TradingEngine.getPriceSafe(market);
      if (priceData.success) {
        const price = ethers.formatUnits(priceData.price, 8);
        const timestamp = new Date(Number(priceData.timestamp) * 1000);
        console.log(`📊 ${market}: $${price} (Updated: ${timestamp.toLocaleString()})`);
      } else {
        console.log(`❌ Failed to get price for ${market}`);
      }
    } catch (error) {
      if (error instanceof Error) {
        console.log(`❌ Error getting price for ${market}:`, error.message);
      } else {
        console.log(`❌ Error getting price for ${market}:`, error);
      }
    }
  }
}

function getNetworkName(chainId: bigint): string {
  const networks: Record<string, string> = {
    "11155111": "sepolia",
    "84532": "baseSepolia",
    "421614": "arbitrumSepolia",
    "43113": "avaxTestnet"
  };
  return networks[chainId.toString()] || "unknown";
}

// CLI interface
async function main() {
  const args = process.argv.slice(2);
  const command = args[0];
  
  switch (command) {
    case "setup":
      await setupInitialMarkets();
      break;
    case "add":
      if (args.length < 3) {
        console.log("Usage: npm run market add <MARKET> <PRICE_FEED_ADDRESS>");
        return;
      }
      await addNewMarket(args[1], args[2]);
      break;
    case "status":
      await checkMarketStatus();
      break;
    case "prices":
      await checkPrices();
      break;
    default:
      console.log(`
📋 Available commands:
  npm run market setup           - Setup initial markets (BTC, ETH, LINK)
  npm run market add <market> <feed> - Add new market with price feed
  npm run market status          - Check all market statuses
  npm run market prices          - Check current prices
      `);
  }
}

if (require.main === module) {
  main().catch(console.error);
}

export { addNewMarket, setupInitialMarkets, checkMarketStatus, checkPrices };