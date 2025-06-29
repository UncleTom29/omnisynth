import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import PoolModule from "./Pool";

const TradingModule = buildModule("TradingModuleV3", (m) => {
  // Get dependencies from previous modules
  const { liquidityPool } = m.useModule(PoolModule);
  const deployer = m.getAccount(0);

   const USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  // Deploy the Trading Engine
  const tradingEngine = m.contract("OmniTradingEngine", [
    USDC,
    liquidityPool,
    deployer
  ], {
    id: "OmniTradingEngine"
  });

  // Add markets to trading engine
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];
  
const addMarketFutures: ReturnType<typeof m.call>[] = [];

markets.forEach((market, index) => {
  const future = m.call(tradingEngine, "addMarket", [market], {
    id: `addTradingMarket_${market.replace("/", "_")}`,
    after: index === 0 ? [] : [addMarketFutures[index - 1]]
  });
  addMarketFutures.push(future);
});


  // Add price feeds to trading engine (same as oracle addresses)
  const priceFeeds = {
   "BTC/USD": "0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43",
    "ETH/USD": "0x694AA1769357215DE4FAC081bf1f309aDC325306", 
    "LINK/USD": "0xc59E3633BAAC79493d908e63626716e204A45EdF"
  };

 Object.entries(priceFeeds).forEach(([symbol, feedAddress]) => {
  const marketFuture = addMarketFutures.find(f => f.id === `addTradingMarket_${symbol.replace("/", "_")}`);
  m.call(tradingEngine, "addPriceFeed", [symbol, feedAddress], {
    id: `addTradingPriceFeed_${symbol.replace("/", "_")}`,
    after: marketFuture ? [marketFuture] : []
  });
});


  return { tradingEngine };
});

export default TradingModule;