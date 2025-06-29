// scripts/poolAnalytics.ts
import { ethers } from "hardhat";
import { OmniLiquidityPool, OmniTradingEngine } from "../typechain-types";

interface PoolAnalytics {
  market: string;
  longPool: string;
  shortPool: string;
  totalLiquidity: string;
  utilization: string;
  feesCollected: string;
  totalVolume: string;
  longShortRatio: string;
  efficiency: string;
}

interface GlobalMetrics {
  totalPoolValue: string;
  insuranceFund: string;
  totalSupply: string;
  activeProviders: number;
  averageAPY: string;
  riskMetrics: {
    utilizationRate: string;
    concentrationRisk: string;
    liquidityRisk: string;
  };
}

async function main() {
  console.log("📊 Starting Liquidity Pool Analytics...\n");

  // Contract addresses
  const TRADING_ENGINE_ADDRESS = process.env.TRADING_ENGINE_ADDRESS || "";
  const LIQUIDITY_POOL_ADDRESS = process.env.LIQUIDITY_POOL_ADDRESS || "";

  if (!TRADING_ENGINE_ADDRESS || !LIQUIDITY_POOL_ADDRESS) {
    throw new Error("Please set contract addresses in your .env file");
  }

  const liquidityPool = await ethers.getContractAt("OmniLiquidityPool", LIQUIDITY_POOL_ADDRESS) as OmniLiquidityPool;
  const tradingEngine = await ethers.getContractAt("OmniTradingEngine", TRADING_ENGINE_ADDRESS) as OmniTradingEngine;

  // Get supported markets
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];
  
  console.log("🏊 LIQUIDITY POOL OVERVIEW");
  console.log("=" .repeat(100));

  // Global metrics
  const globalMetrics = await getGlobalMetrics(liquidityPool, tradingEngine);
  displayGlobalMetrics(globalMetrics);

  console.log("\n💰 MARKET-SPECIFIC ANALYTICS");
  console.log("=" .repeat(100));

  const marketAnalytics: PoolAnalytics[] = [];

  // Analyze each market
  for (const market of markets) {
    try {
      const analytics = await getMarketAnalytics(liquidityPool, market);
      marketAnalytics.push(analytics);
    } catch (error) {
      console.error(`Error analyzing ${market}:`, error);
    }
  }

  // Display market analytics table
  displayMarketAnalytics(marketAnalytics);

  // Risk analysis
  console.log("\n⚠️  RISK ANALYSIS");
  console.log("=" .repeat(80));
  await displayRiskAnalysis(liquidityPool, marketAnalytics);

  // Liquidity provider analysis
  console.log("\n👥 LIQUIDITY PROVIDER ANALYSIS");
  console.log("=" .repeat(80));
  await displayLPAnalysis(liquidityPool);

  // Performance metrics
  console.log("\n📈 PERFORMANCE METRICS");
  console.log("=" .repeat(80));
  await displayPerformanceMetrics(liquidityPool, marketAnalytics);

  console.log("\n✅ Pool analytics complete!");
}

async function getGlobalMetrics(liquidityPool: OmniLiquidityPool, tradingEngine: OmniTradingEngine): Promise<GlobalMetrics> {
  const totalPoolValue = await liquidityPool.totalPoolValue();
  const insuranceFund = await liquidityPool.insuranceFund();
  const totalSupply = await liquidityPool.totalSupply();
  
  // Count active providers (simplified)
  let activeProviders = 0;
  try {
    // In production, you'd maintain a list of all providers
    // This is a simplified approach
    activeProviders = totalSupply > 0 ? 1 : 0;
  } catch (error) {
    console.error("Error counting providers:", error);
  }

  // Calculate utilization rate
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];
  let totalUtilized = BigInt(0);
  
  for (const market of markets) {
    try {
      const poolInfo = await liquidityPool.getPoolInfo(market);
      totalUtilized += poolInfo.longPool + poolInfo.shortPool;
    } catch (error) {
      console.error(`Error getting pool info for ${market}:`, error);
    }
  }

  const utilizationRate = totalPoolValue > 0 ? 
    (Number(totalUtilized) / Number(totalPoolValue) * 100).toFixed(2) : "0";

  return {
    totalPoolValue: ethers.formatUnits(totalPoolValue, 6),
    insuranceFund: ethers.formatUnits(insuranceFund, 6),
    totalSupply: ethers.formatUnits(totalSupply, 18),
    activeProviders,
    averageAPY: "0", // Would need historical data
    riskMetrics: {
      utilizationRate,
      concentrationRisk: "Low", // Simplified
      liquidityRisk: utilizationRate > "80" ? "High" : "Low"
    }
  };
}

async function getMarketAnalytics(liquidityPool: OmniLiquidityPool, market: string): Promise<PoolAnalytics> {
  const poolInfo = await liquidityPool.getPoolInfo(market);
  
  const longPool = ethers.formatUnits(poolInfo.longPool, 6);
  const shortPool = ethers.formatUnits(poolInfo.shortPool, 6);
  const totalLiquidity = (parseFloat(longPool) + parseFloat(shortPool)).toFixed(2);
  const utilization = poolInfo.utilization.toString();
  const feesCollected = ethers.formatUnits(poolInfo.feesCollected, 6);
  const totalVolume = ethers.formatUnits(poolInfo.totalVolume, 6);
  
  const longShortRatio = parseFloat(shortPool) > 0 ? 
    (parseFloat(longPool) / parseFloat(shortPool)).toFixed(2) : "∞";
  
  const efficiency = parseFloat(totalVolume) > 0 ? 
    (parseFloat(feesCollected) / parseFloat(totalVolume) * 100).toFixed(4) : "0";

  return {
    market,
    longPool,
    shortPool,
    totalLiquidity,
    utilization,
    feesCollected,
    totalVolume,
    longShortRatio,
    efficiency
  };
}

function displayGlobalMetrics(metrics: GlobalMetrics) {
  console.log(`💼 Total Pool Value: $${parseFloat(metrics.totalPoolValue).toLocaleString()}`);
  console.log(`🛡️  Insurance Fund: $${parseFloat(metrics.insuranceFund).toLocaleString()}`);
  console.log(`🎫 Total LP Tokens: ${parseFloat(metrics.totalSupply).toLocaleString()}`);
  console.log(`👥 Active Providers: ${metrics.activeProviders}`);
  console.log(`📊 Utilization Rate: ${metrics.riskMetrics.utilizationRate}%`);
  console.log(`⚠️  Liquidity Risk: ${metrics.riskMetrics.liquidityRisk}`);
}

function displayMarketAnalytics(analytics: PoolAnalytics[]) {
  console.log("Market".padEnd(12) + "Long Pool".padEnd(15) + "Short Pool".padEnd(15) + 
              "Total Liq".padEnd(15) + "Util%".padEnd(8) + "Fees".padEnd(12) + 
              "L/S Ratio".padEnd(10) + "Fee%".padEnd(8));
  console.log("-".repeat(95));

  for (const marketAnalytics of analytics) {
    console.log(
      marketAnalytics.market.padEnd(12) +
      `$${parseFloat(marketAnalytics.longPool).toLocaleString()}`.padEnd(15) +
      `$${parseFloat(marketAnalytics.shortPool).toLocaleString()}`.padEnd(15) +
      `$${parseFloat(marketAnalytics.totalLiquidity).toLocaleString()}`.padEnd(15) +
      `${marketAnalytics.utilization}%`.padEnd(8) +
      `$${parseFloat(marketAnalytics.feesCollected).toLocaleString()}`.padEnd(12) +
      marketAnalytics.longShortRatio.padEnd(10) +
      `${marketAnalytics.efficiency}%`.padEnd(8)
    );
  }
}

async function displayRiskAnalysis(liquidityPool: OmniLiquidityPool, marketAnalytics: PoolAnalytics[]) {
  const maxUtilization = await liquidityPool.MAX_POOL_UTILIZATION();
  
  console.log(`📋 Risk Assessment:`);
  console.log(`  Max Utilization Limit: ${maxUtilization}%`);
  
  // Check utilization warnings
  const highUtilizationMarkets = marketAnalytics.filter(m => parseFloat(m.utilization) > 70);
  if (highUtilizationMarkets.length > 0) {
    console.log(`  🚨 High Utilization Markets:`);
    for (const market of highUtilizationMarkets) {
      console.log(`    - ${market.market}: ${market.utilization}%`);
    }
  } else {
    console.log(`  ✅ All markets within safe utilization limits`);
  }

  // Check imbalance warnings
  const imbalancedMarkets = marketAnalytics.filter(m => {
    const ratio = parseFloat(m.longShortRatio);
    return ratio > 3 || ratio < 0.33;
  });
  
  if (imbalancedMarkets.length > 0) {
    console.log(`  ⚖️  Imbalanced Markets:`);
    for (const market of imbalancedMarkets) {
      console.log(`    - ${market.market}: L/S Ratio ${market.longShortRatio}`);
    }
  } else {
    console.log(`  ✅ All markets reasonably balanced`);
  }
}

async function displayLPAnalysis(liquidityPool: OmniLiquidityPool) {
  const totalSupply = await liquidityPool.totalSupply();
  const totalPoolValue = await liquidityPool.totalPoolValue();
  
  const tokenPrice = totalSupply > 0 ? 
    (Number(totalPoolValue) / Number(totalSupply)).toFixed(6) : "0";
  
  console.log(`🎫 LP Token Analysis:`);
  console.log(`  Token Price: $${tokenPrice} USDC per LP token`);
  console.log(`  Total Supply: ${ethers.formatUnits(totalSupply, 18)} LP tokens`);
  console.log(`  Market Cap: $${parseFloat(ethers.formatUnits(totalPoolValue, 6)).toLocaleString()}`);
  
  // Note: In production, you'd track individual LP positions
  console.log(`  📊 Individual LP tracking would require additional data structures`);
}

async function displayPerformanceMetrics(liquidityPool: OmniLiquidityPool, marketAnalytics: PoolAnalytics[]) {
  let totalFees = 0;
  let totalVolume = 0;
  
  for (const market of marketAnalytics) {
    totalFees += parseFloat(market.feesCollected);
    totalVolume += parseFloat(market.totalVolume);
  }
  
  const averageFeeRate = totalVolume > 0 ? (totalFees / totalVolume * 100).toFixed(4) : "0";
  
  console.log(`💹 Performance Summary:`);
  console.log(`  Total Fees Collected: $${totalFees.toLocaleString()}`);
  console.log(`  Total Volume: $${totalVolume.toLocaleString()}`);
  console.log(`  Average Fee Rate: ${averageFeeRate}%`);
  
  // Most profitable market
  const mostProfitable = marketAnalytics.reduce((max, market) => 
    parseFloat(market.feesCollected) > parseFloat(max.feesCollected) ? market : max
  );
  
  console.log(`  🏆 Most Profitable Market: ${mostProfitable.market} ($${parseFloat(mostProfitable.feesCollected).toLocaleString()} fees)`);
  
  // Most active market
  const mostActive = marketAnalytics.reduce((max, market) => 
    parseFloat(market.totalVolume) > parseFloat(max.totalVolume) ? market : max
  );
  
  console.log(`  🔥 Most Active Market: ${mostActive.market} ($${parseFloat(mostActive.totalVolume).toLocaleString()} volume)`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });