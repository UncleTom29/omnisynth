import { ethers } from "ethers";
import { config } from "dotenv";
import * as fs from "fs";
import * as path from "path";

config();

const LIQUIDITY_POOL_ABI = require("../artifacts/contracts/Pool.sol/OmniLiquidityPool.json").abi;
const IERC20_ABI = require("../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json").abi;

const LIQUIDITY_POOL_ADDRESS = "0x49e91BDa64F81006DEC75E2110722db068c05614";

const USDC_ADDRESSES = {
  sepolia: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  baseSepolia: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
  arbitrumSepolia: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
};

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);
const signer = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

function getNetworkName(chainId: string): keyof typeof USDC_ADDRESSES | "unknown" {
  const map: Record<string, keyof typeof USDC_ADDRESSES> = {
    "11155111": "sepolia",
    "84532": "baseSepolia",
    "421614": "arbitrumSepolia",
  };
  return map[chainId] || "unknown";
}

async function getContractInstances() {
  const network = await provider.getNetwork();
  const networkName = getNetworkName(network.chainId.toString());
  if (
    networkName !== "sepolia" &&
    networkName !== "baseSepolia" &&
    networkName !== "arbitrumSepolia"
  ) {
    throw new Error(`Unsupported network: ${network.chainId}`);
  }
  const usdcAddress = ethers.getAddress(USDC_ADDRESSES[networkName]);

  const LiquidityPool = new ethers.Contract(LIQUIDITY_POOL_ADDRESS, LIQUIDITY_POOL_ABI, signer);
  const USDC = new ethers.Contract(usdcAddress, IERC20_ABI, signer);

  return { LiquidityPool, USDC, signer };
}

function parseBool(value: string): boolean {
  const val = value.toLowerCase();
  if (["true", "yes", "1", "long"].includes(val)) return true;
  if (["false", "no", "0", "short"].includes(val)) return false;
  throw new Error(`Invalid boolean: "${value}". Use "long", "short", "true", or "false".`);
}


async function addLiquidity(amount: string) {
  console.log(`💰 Adding ${amount} USDC liquidity...`);
  const { LiquidityPool, USDC } = await getContractInstances();
  const amountWei = ethers.parseUnits(amount, 6);

  const balance: bigint = await USDC.balanceOf(signer.address);
  if (balance < amountWei) return console.log("❌ Insufficient USDC");

  const allowance: bigint = await USDC.allowance(signer.address, LIQUIDITY_POOL_ADDRESS);
  if (allowance < amountWei) {
    console.log("🔓 Approving...");
    const approveTx = await USDC.approve(LIQUIDITY_POOL_ADDRESS, amountWei);
    await approveTx.wait();
  }

  const tx = await LiquidityPool.addLiquidity(amountWei);
  await tx.wait();
  console.log("✅ Liquidity added");
  await showLiquidityStats();
}

async function removeLiquidity(shares: string) {
  console.log(`🏧 Removing ${shares} LP shares...`);
  const { LiquidityPool } = await getContractInstances();
  const sharesWei = ethers.parseEther(shares);

  const balance: bigint = await LiquidityPool.balanceOf(signer.address);
  if (balance < sharesWei) return console.log("❌ Insufficient LP tokens");

  const [totalPoolValue, totalSupply] = await Promise.all([
    LiquidityPool.totalPoolValue(),
    LiquidityPool.totalSupply()
  ]);

  const withdrawAmount = (sharesWei * totalPoolValue) / totalSupply;
  const canWithdraw = await LiquidityPool.canWithdraw(withdrawAmount);
  if (!canWithdraw) return console.log("❌ Withdrawal not allowed");

  const tx = await LiquidityPool.removeLiquidity(sharesWei);
  await tx.wait();
  console.log("✅ Liquidity removed");
  await showLiquidityStats();
}

async function showLiquidityStats() {
  console.log("📊 Pool Stats:");
  const { LiquidityPool } = await getContractInstances();

  const [totalPoolValue, insuranceFund, totalSupply, userLpBalance, userLpInfo, rewards] =
    await Promise.all([
      LiquidityPool.totalPoolValue(),
      LiquidityPool.insuranceFund(),
      LiquidityPool.totalSupply(),
      LiquidityPool.balanceOf(signer.address),
      LiquidityPool.liquidityProviders(signer.address),
      LiquidityPool.getLPRewards(signer.address)
    ]);

  console.log(`💎 Pool Value: ${ethers.formatUnits(totalPoolValue, 6)} USDC`);
  console.log(`🛡 Insurance: ${ethers.formatUnits(insuranceFund, 6)} USDC`);
  console.log(`🪙 LP Supply: ${ethers.formatEther(totalSupply)}`);

  if (userLpBalance > 0n) {
    const currentValue = (userLpBalance * totalPoolValue) / totalSupply;
    console.log(`\n👤 Your Stats:`);
    console.log(`🪙 LP Tokens: ${ethers.formatEther(userLpBalance)}`);
    console.log(`💰 Deposited: ${ethers.formatUnits(userLpInfo.totalDeposited, 6)} USDC`);
    console.log(`🏧 Withdrawn: ${ethers.formatUnits(userLpInfo.totalWithdrawn, 6)} USDC`);
    console.log(`💎 Current Value: ${ethers.formatUnits(currentValue, 6)} USDC`);
    console.log(`🎁 Rewards: ${ethers.formatUnits(rewards, 6)} USDC`);
  }
}

async function claimRewards() {
  const { LiquidityPool } = await getContractInstances();
  const rewards: bigint = await LiquidityPool.getLPRewards(signer.address);
  if (rewards === 0n) return console.log("💸 No rewards to claim");

  const tx = await LiquidityPool.claimRewards();
  await tx.wait();
  console.log("✅ Rewards claimed");
}

async function showMarketLiquidity() {
  const { LiquidityPool } = await getContractInstances();
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];

  for (const market of markets) {
    try {
      const info = await LiquidityPool.getPoolInfo(market);
      console.log(`\n📈 ${market}:`);
      console.log(`  Long Pool: ${ethers.formatUnits(info.longPool, 6)} USDC`);
      console.log(`  Short Pool: ${ethers.formatUnits(info.shortPool, 6)} USDC`);
      console.log(`  Volume: ${ethers.formatUnits(info.totalVolume, 6)} USDC`);
      console.log(`  Fees: ${ethers.formatUnits(info.feesCollected, 6)} USDC`);
      console.log(`  Utilization: ${info.utilization}%`);

      const total = info.longPool + info.shortPool;
      if (total > 0n) {
        const longRatio = (info.longPool * 100n) / total;
        console.log(`  ⚖️ Long/Short: ${longRatio}%/${100n - longRatio}%`);
      }
    } catch (err) {
      console.log(`❌ Error fetching ${market}:`, (err as Error).message);
    }
  }
}

async function simulateWithdrawal(shares: string) {
  const { LiquidityPool } = await getContractInstances();
  const sharesWei = ethers.parseEther(shares);

  const [totalPoolValue, totalSupply] = await Promise.all([
    LiquidityPool.totalPoolValue(),
    LiquidityPool.totalSupply()
  ]);

  if (totalSupply === 0n) return console.log("❌ No LP tokens in circulation");

  const withdrawAmount = (sharesWei * totalPoolValue) / totalSupply;
  console.log(`💰 You'd receive: ${ethers.formatUnits(withdrawAmount, 6)} USDC`);

  const canWithdraw = await LiquidityPool.canWithdraw(withdrawAmount);
  console.log(`✅ Can Withdraw: ${canWithdraw}`);

  const userBalance = await LiquidityPool.balanceOf(signer.address);
  console.log(`🪙 Your LP Balance: ${ethers.formatEther(userBalance)}`);
  console.log(`✅ Sufficient Balance: ${userBalance >= sharesWei}`);
}

export async function allocateLiquidity(market: string, isLong: boolean, amount: string) {
  const { LiquidityPool } = await getContractInstances();
  const amountWei = ethers.parseUnits(amount, 6);

  console.log(`📥 Allocating ${amount} USDC to ${market} (${isLong ? "long" : "short"}) pool...`);

  try {
    const tx = await LiquidityPool.allocateLiquidity(market, isLong, amountWei);
    await tx.wait();
    console.log("✅ Liquidity allocated successfully.");
  } catch (error) {
    console.error("❌ Error allocating liquidity:", error);
  }
}

export async function deallocateLiquidity(market: string, isLong: boolean, amount: string) {
  const { LiquidityPool } = await getContractInstances();
  const amountWei = ethers.parseUnits(amount, 6);
  console.log(`📤 Deallocating ${amount} USDC from ${market} (${isLong ? "long" : "short"}) pool...`);

  try {
    const tx = await LiquidityPool.deallocateLiquidity(market, isLong, amountWei);
    await tx.wait();
    console.log("✅ Liquidity deallocated successfully.");
  } catch (error) {
    console.error("❌ Error deallocating liquidity:", error);
  }
}

export async function collectTradingFees(market: string, amount: string) {
  const { LiquidityPool } = await getContractInstances();
  const amountWei = ethers.parseUnits(amount, 6);
  console.log(`💸 Collecting ${amount} USDC in fees for ${market}...`);

  try {
    const tx = await LiquidityPool.collectTradingFees(market, amountWei);
    await tx.wait();
    console.log("✅ Trading fees collected.");
  } catch (error) {
    console.error("❌ Error collecting trading fees:", error);
  }
}

export async function processProfit(market: string, isLong: boolean, amount: string) {
  const { LiquidityPool } = await getContractInstances();
  const amountWei = ethers.parseUnits(amount, 6);
  console.log(`📈 Processing profit of ${amount} USDC for ${market} (${isLong ? "long" : "short"})...`);

  try {
    const tx = await LiquidityPool.processProfit(market, isLong, amountWei);
    await tx.wait();
    console.log("✅ Profit processed.");
  } catch (error) {
    console.error("❌ Error processing profit:", error);
  }
}

export async function processLoss(market: string, isLong: boolean, amount: string) {
  const { LiquidityPool } = await getContractInstances();
  const amountWei = ethers.parseUnits(amount, 6);
  console.log(`📉 Processing loss of ${amount} USDC for ${market} (${isLong ? "long" : "short"})...`);

  try {
    const tx = await LiquidityPool.processLoss(market, isLong, amountWei);
    await tx.wait();
    console.log("✅ Loss processed.");
  } catch (error) {
    console.error("❌ Error processing loss:", error);
  }
}



// CLI
async function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];

  switch (cmd) {
    case "add":
      return args[1] ? addLiquidity(args[1]) : console.log("Usage: add <amount>");
    case "remove":
      return args[1] ? removeLiquidity(args[1]) : console.log("Usage: remove <shares>");
    case "stats":
      return showLiquidityStats();
    case "markets":
      return showMarketLiquidity();
    case "claim":
      return claimRewards();
    case "allocate":
      return args[3] ? allocateLiquidity(args[1], parseBool(args[2]), args[3]) :  console.log("Usage: allocate <MARKET> <long|short> <AMOUNT>");

    case "deallocate":
  return args[3]
    ? deallocateLiquidity(args[1], parseBool(args[2]), args[3])
    : console.log("Usage: deallocate <MARKET> <long|short> <AMOUNT>");

    case "fees":
  return args[2]
    ? collectTradingFees(args[1], args[2])
    : console.log("Usage: fees <MARKET> <AMOUNT>");

  case "profit":
  return args[3]
    ? processProfit(args[1], parseBool(args[2]), args[3])
    : console.log("Usage: profit <MARKET> <long|short> <AMOUNT>");

  case "loss":
  return args[3]
    ? processLoss(args[1], parseBool(args[2]), args[3])
    : console.log("Usage: loss <MARKET> <long|short> <AMOUNT>");

    case "simulate":
      return args[1] ? simulateWithdrawal(args[1]) : console.log("Usage: simulate <shares>");
    default:
      return console.log(`
💰 Liquidity Manager (Ethers v6)
-----------------------------------------
Commands:
  ts-node liquidity.ts add <amount>              Add USDC
  ts-node liquidity.ts remove <shares>           Remove LP tokens
  ts-node liquidity.ts stats                     Show LP stats
  ts-node liquidity.ts markets                   Show market data
  ts-node liquidity.ts claim                     Claim rewards
  ts-node liquidity.ts simulate <shares>         Simulate withdrawal
  ts-node liquidity.ts allocate <MARKET> <long|short> <AMOUNT>   Allocate liquidity to market
  ts-node liquidity.ts deallocate <MARKET> <long|short> <AMOUNT> Deallocate liquidity from market
  ts-node liquidity.ts fees <MARKET> <AMOUNT>    Collect trading fees for market
  ts-node liquidity.ts profit <MARKET> <long|short> <AMOUNT>  Process profit
  ts-node liquidity.ts loss <MARKET> <long|short> <AMOUNT>    Process loss
`);

  }
}

if (require.main === module) {
  main().catch(console.error);
}

export {
  addLiquidity,
  removeLiquidity,
  showLiquidityStats,
  claimRewards,
  showMarketLiquidity,
  simulateWithdrawal,
};
