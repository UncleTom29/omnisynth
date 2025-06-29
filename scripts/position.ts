// scripts/checkPositions.ts
import { ethers } from "ethers";
import dotenv from "dotenv";
import OmniTradingEngineAbi from "../artifacts/contracts/TradingEngine.sol/OmniTradingEngine.json";
import OmniLiquidityPoolAbi from "../artifacts/contracts/Pool.sol/OmniLiquidityPool.json";

dotenv.config();

const RPC_URL = process.env.RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY!;
const TRADING_ENGINE_ADDRESS = "0x0989a224e2730d0595628704f4d18C14696A4087";
const LIQUIDITY_POOL_ADDRESS = "0x49e91BDa64F81006DEC75E2110722db068c05614";

if (!RPC_URL || !PRIVATE_KEY) throw new Error("Missing RPC_URL or PRIVATE_KEY in .env");

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

const tradingEngine = new ethers.Contract(
  TRADING_ENGINE_ADDRESS,
  OmniTradingEngineAbi.abi,
  wallet
);

const liquidityPool = new ethers.Contract(
  LIQUIDITY_POOL_ADDRESS,
  OmniLiquidityPoolAbi.abi,
  wallet
);

interface PositionData {
  id: number;
  trader: string;
  market: string;
  isLong: boolean;
  size: string;
  entryPrice: string;
  leverage: number;
  collateral: string;
  liquidationPrice: string;
  timestamp: number;
  isActive: boolean;
  currentPnL?: string;
  currentPrice?: string;
}

interface UserAnalytics {
  totalPositions: number;
  activePositions: number;
  totalCollateral: string;
  availableCollateral: string;
  totalPnL: string;
  winRate: number;
}

async function main() {
  console.log("🔍 Starting Position Monitor...\n");

  const nextPositionId: bigint = await tradingEngine.nextPositionId();
  console.log(`📊 Total positions created: ${nextPositionId - 1n}`);

  const activePositions: PositionData[] = [];
  const inactivePositions: PositionData[] = [];

  for (let i = 1; i < Number(nextPositionId); i++) {
    try {
      const position = await tradingEngine.positions(i);
      const posData = await getPositionDetails(i, position);
      (position.isActive ? activePositions : inactivePositions).push(posData);
    } catch (err) {
      console.error(`❌ Failed to fetch position ${i}:`, err);
    }
  }

  printActivePositions(activePositions);
  await checkLiquidations(activePositions);
  await printUserAnalytics(activePositions, inactivePositions);

  console.log(`\n✅ Position monitoring complete!`);
}

function getMarketFromHash(hash: string): string {
  const marketMap: { [key: string]: string } = {
    [ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"))]: "BTC/USD",
    [ethers.keccak256(ethers.toUtf8Bytes("ETH/USD"))]: "ETH/USD",
    [ethers.keccak256(ethers.toUtf8Bytes("LINK/USD"))]: "LINK/USD",
  };
  return marketMap[hash] || "UNKNOWN";
}

async function getPositionDetails(id: number, p: any): Promise<PositionData> {
  const market = getMarketFromHash(p.marketHash);
  let currentPrice: string | undefined;
  let currentPnL: string | undefined;

  if (p.isActive) {
    try {
      const [success, price] = await tradingEngine.getPriceSafe(market);
      if (success) {
        currentPrice = ethers.formatUnits(price, 8);
        const entryPrice = parseFloat(ethers.formatUnits(p.entryPrice, 8));
        const cp = parseFloat(currentPrice);
        const size = parseFloat(ethers.formatUnits(p.size, 6));
        const pnl = p.isLong ? (cp - entryPrice) * size / entryPrice : (entryPrice - cp) * size / entryPrice;
        const pnlPercentage = pnl * 100
        currentPnL = pnlPercentage.toFixed(2);
      }
    } catch (e) {
      console.error(`❌ Price fetch failed for ${market}`, e);
    }
  }

  return {
    id,
    trader: p.trader,
    market,
    isLong: p.isLong,
    size: ethers.formatUnits(p.size, 6),
    entryPrice: ethers.formatUnits(p.entryPrice, 8),
    leverage: Number(p.leverage),
    collateral: ethers.formatUnits(p.collateral, 6),
    liquidationPrice: ethers.formatUnits(p.liquidationPrice, 8),
    timestamp: Number(p.timestamp),
    isActive: p.isActive,
    currentPrice,
    currentPnL,
  };
}

function printActivePositions(activePositions: PositionData[]) {
  console.log(`\n🟢 ACTIVE POSITIONS (${activePositions.length})`);
  console.log("=".repeat(120));
  console.log("ID".padEnd(5) + "Trader".padEnd(12) + "Market".padEnd(10) + "Side".padEnd(6) +
    "Size".padEnd(12) + "Entry".padEnd(10) + "Current".padEnd(10) + "PnL".padEnd(12) +
    "Leverage".padEnd(10) + "Liquidation".padEnd(12));
  console.log("-".repeat(120));

  for (const pos of activePositions) {
    const side = pos.isLong ? "LONG" : "SHORT";
    const pnlColor = pos.currentPnL && parseFloat(pos.currentPnL) >= 0 ? "💚" : "❤️";
    console.log(
      pos.id.toString().padEnd(5) +
      `${pos.trader.slice(0, 10)}...`.padEnd(12) +
      pos.market.padEnd(10) +
      side.padEnd(6) +
      `$${pos.size}`.padEnd(12) +
      `$${pos.entryPrice}`.padEnd(10) +
      `$${pos.currentPrice || "N/A"}`.padEnd(10) +
      `${pnlColor}$${pos.currentPnL || "N/A"}`.padEnd(12) +
      `${pos.leverage}x`.padEnd(10) +
      `$${pos.liquidationPrice}`.padEnd(12)
    );
  }
}

async function checkLiquidations(activePositions: PositionData[]) {
  console.log(`\n⚠️  LIQUIDATION CHECK`);
  console.log("=".repeat(60));
  const liquidatable = [];

  for (const pos of activePositions) {
    try {
      const res = await tradingEngine.isLiquidatable(pos.id);
      if (res) liquidatable.push(pos);
    } catch (e) {
      console.error(`Error checking liquidation on ${pos.id}`, e);
    }
  }

  if (liquidatable.length === 0) {
    console.log("✅ No positions are currently liquidatable.");
  } else {
    for (const p of liquidatable) {
      console.log(`🚨 Position ${p.id} (${p.market} ${p.isLong ? "LONG" : "SHORT"})`);
    }
  }
}

async function printUserAnalytics(active: PositionData[], inactive: PositionData[]) {
  console.log(`\n👤 USER ANALYTICS`);
  console.log("=".repeat(80));
  const users = [...new Set([...active, ...inactive].map(p => p.trader))];

  for (const user of users) {
    const actives = active.filter(p => p.trader === user);
    const inactives = inactive.filter(p => p.trader === user);
    const total = actives.length + inactives.length;

    const totalCollateral = await tradingEngine.userCollateral(user);
    const availableCollateral = await tradingEngine.getAvailableCollateral(user);

    const totalPnL = actives.reduce((acc, p) => acc + (p.currentPnL ? parseFloat(p.currentPnL) : 0), 0);
    const wins = actives.filter(p => p.currentPnL && parseFloat(p.currentPnL) > 0).length;

    console.log(`\n📈 ${user.slice(0, 10)}...`);
    console.log(`  Active Positions: ${actives.length}/${total}`);
    console.log(`  Total Collateral: $${ethers.formatUnits(totalCollateral, 6)}`);
    console.log(`  Available Collateral: $${ethers.formatUnits(availableCollateral, 6)}`);
    console.log(`  Total PnL: $${totalPnL.toFixed(2)}`);
    console.log(`  Win Rate: ${(total > 0 ? (wins / total) * 100 : 0).toFixed(1)}%`);
  }
}

async function cli() {
  const args = process.argv.slice(2);
  const cmd = args[0];

  switch (cmd) {
    case "all":
    case "monitor":
      return await main();

    case "position":
      if (!args[1]) return console.log("Usage: position <id>");
      return await showPosition(Number(args[1]));

    case "liquidations":
      return await runLiquidationCheck();

    case "user":
      if (!args[1]) return console.log("Usage: user <address>");
      return await showUserAnalytics(args[1]);

    default:
      return console.log(`
📈 Position CLI (Ethers v6)
-------------------------------
Commands:
  ts-node position.ts all                   View all positions + analytics
  ts-node position.ts monitor               Same as 'all'
  ts-node position.ts position <id>         Show details of specific position
  ts-node position.ts liquidations          Show liquidatable positions
  ts-node position.ts user <address>        Show user analytics
`);
  }
}

async function showPosition(id: number) {
  const p = await tradingEngine.positions(id);
  const posData = await getPositionDetails(id, p);

  console.log("\n📌 Position Details:");
  console.log(`ID: ${posData.id}`);
  console.log(`Trader: ${posData.trader}`);
  console.log(`Market: ${posData.market}`);
  console.log(`Side: ${posData.isLong ? "LONG" : "SHORT"}`);
  console.log(`Size: $${posData.size}`);
  console.log(`Entry Price: $${posData.entryPrice}`);
  console.log(`Leverage: ${posData.leverage}x`);
  console.log(`Collateral: $${posData.collateral}`);
  console.log(`Liquidation Price: $${posData.liquidationPrice}`);
  console.log(`Active: ${posData.isActive}`);
  if (posData.isActive) {
    console.log(`Current Price: $${posData.currentPrice}`);
    console.log(`Current PnL: $${posData.currentPnL}`);
  }
}

async function runLiquidationCheck() {
  const nextPositionId: bigint = await tradingEngine.nextPositionId();
  const activePositions: PositionData[] = [];

  for (let i = 1; i < Number(nextPositionId); i++) {
    const p = await tradingEngine.positions(i);
    if (p.isActive) {
      const pos = await getPositionDetails(i, p);
      activePositions.push(pos);
    }
  }

  await checkLiquidations(activePositions);
}

async function showUserAnalytics(address: string) {
  const nextPositionId: bigint = await tradingEngine.nextPositionId();
  const activePositions: PositionData[] = [];
  const inactivePositions: PositionData[] = [];

  for (let i = 1; i < Number(nextPositionId); i++) {
    const p = await tradingEngine.positions(i);
    const pos = await getPositionDetails(i, p);
    if (p.trader.toLowerCase() === address.toLowerCase()) {
      (p.isActive ? activePositions : inactivePositions).push(pos);
    }
  }

  await printUserAnalytics(activePositions, inactivePositions);
}

// Only run CLI if script is called directly
if (require.main === module) {
  cli().catch(console.error);
}

