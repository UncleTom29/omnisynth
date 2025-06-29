import { ethers, Contract, Wallet, JsonRpcProvider, formatUnits, parseUnits } from "ethers";
import * as dotenv from "dotenv";
import { argv } from "process";
dotenv.config();

// ENV config
const RPC_URL = process.env.RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY!;
const provider = new JsonRpcProvider(RPC_URL);
const wallet = new Wallet(PRIVATE_KEY, provider);

// Addresses
const TRADING_ENGINE_ADDRESS = "0x0989a224e2730d0595628704f4d18C14696A4087";
const USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

// ABIs
const TRADING_ENGINE_ABI = require("../artifacts/contracts/TradingEngine.sol/OmniTradingEngine.json").abi;
const USDC_ABI = require("../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json").abi;

function parseBool(value: string): boolean {
  const val = value.toLowerCase();
  if (["true", "yes", "1", "long"].includes(val)) return true;
  if (["false", "no", "0", "short"].includes(val)) return false;
  throw new Error(`Invalid boolean: "${value}". Use "long", "short", "true", or "false".`);
}

class TradingBot {
  tradingEngine: Contract;
  usdc: Contract;
  signer = wallet;

  constructor() {
    this.tradingEngine = new Contract(TRADING_ENGINE_ADDRESS, TRADING_ENGINE_ABI, wallet);
    this.usdc = new Contract(USDC_ADDRESS, USDC_ABI, wallet);
  }

  

  async depositCollateral(amount: string) {
    const amountWei = parseUnits(amount, 6);
    const balance = await this.usdc.balanceOf(this.signer.address);

    if (balance < amountWei) throw new Error("Insufficient USDC balance");

    const allowance = await this.usdc.allowance(this.signer.address, TRADING_ENGINE_ADDRESS);
    if (allowance < amountWei) {
      console.log("Approving USDC...");
      const tx = await this.usdc.approve(TRADING_ENGINE_ADDRESS, amountWei);
      await tx.wait();
    }

    const tx = await this.tradingEngine.depositCollateral(amountWei);
    await tx.wait();
    console.log("✅ Deposited:", tx.hash);
  }

  

  async withdrawCollateral(amount: string) {
    const amountWei = parseUnits(amount, 6);
    const available = await this.tradingEngine.getAvailableCollateral(this.signer.address);

    if (available < amountWei) throw new Error("Insufficient available collateral");

    const tx = await this.tradingEngine.withdrawCollateral(amountWei);
    await tx.wait();
    console.log("✅ Withdrawn:", tx.hash);
  }

  

  async placeMarketOrder(market: string, isLong: boolean, size: string, leverage: number) {
    const sizeWei = parseUnits(size, 6);
    const required = parseUnits((parseFloat(size) / leverage).toString(), 6);
    const available = await this.tradingEngine.getAvailableCollateral(this.signer.address);

    if (available < required) throw new Error("Not enough collateral");

    const tx = await this.tradingEngine.placeOrder(market, isLong, sizeWei, 0, leverage, true);
    const receipt = await tx.wait();

    console.log("✅ Market Order:", tx.hash);

     // Extract order ID from events
  const event = receipt.logs.find((log: { topics: any ; }) =>
    log.topics[0] === ethers.id("OrderPlaced(uint256,address,string,bool,uint256,uint256)")
  );

  if (!event) throw new Error("❌ OrderPlaced event not found");

  const orderId = ethers.toBigInt(event.topics[1]);
  console.log(`📦 Order ID: ${orderId}`);

    // Confirm if order got executed internally
  const order = await this.tradingEngine.orders(orderId);
  if (order.isActive) {
    console.log("⚠️ Internal execution failed. Manually executing...");

    const execTx = await this.tradingEngine.executeOrder(orderId);
    await execTx.wait();

    console.log("✅ Order executed manually:", execTx.hash);
  } else {
    console.log("✅ Order executed internally");
  }
  }

  async placeLimitOrder(market: string, isLong: boolean, size: string, price: string, leverage: number) {
    const sizeWei = parseUnits(size, 6);
    const priceWei = parseUnits(price, 8);
    const required = parseUnits((parseFloat(size) / leverage).toString(), 6);
    const available = await this.tradingEngine.getAvailableCollateral(this.signer.address);

    if (available < required) throw new Error("Not enough collateral");

    const tx = await this.tradingEngine.placeOrder(market, isLong, sizeWei, priceWei, leverage, false);
    const receipt = await tx.wait();
    console.log("✅ Limit Order:", tx.hash);

       // Extract order ID from events
  const event = receipt.logs.find((log: { topics: any ; }) =>
    log.topics[0] === ethers.id("OrderPlaced(uint256,address,string,bool,uint256,uint256)")
  );

  if (!event) throw new Error("❌ OrderPlaced event not found");

  const orderId = ethers.toBigInt(event.topics[1]);
  console.log(`📦 Order ID: ${orderId}`);

    // Confirm if order got executed internally
  const order = await this.tradingEngine.orders(orderId);
  if (order.isActive) {
    console.log("⚠️ Internal execution failed. Manually executing...");

    const execTx = await this.tradingEngine.executeOrder(orderId);
    await execTx.wait();

    console.log("✅ Order executed manually:", execTx.hash);
  } else {
    console.log("✅ Order executed internally");
  }
  }

  async closePosition(id: number) {
    const position = await this.tradingEngine.positions(id);
    if (!position.isActive) throw new Error("Position is not active");
    if (position.trader.toLowerCase() !== this.signer.address.toLowerCase()) throw new Error("Unauthorized");

    const tx = await this.tradingEngine.closePosition(id);
    await tx.wait();
    console.log("✅ Position closed:", tx.hash);
  }

  async getCurrentPrice(market: string) {
    const [price, timestamp] = await this.tradingEngine.getPrice(market);
    console.log(`📈 ${market}: $${formatUnits(price, 8)} at ${new Date(Number(timestamp) * 1000).toLocaleString()}`);
  }

  async getCollateralInfo() {
    const total = await this.tradingEngine.userCollateral(this.signer.address);
    const available = await this.tradingEngine.getAvailableCollateral(this.signer.address);
    const used = total - available;

    console.log(`📊 Collateral Info:
- Total:     ${formatUnits(total, 6)} USDC
- Available: ${formatUnits(available, 6)} USDC
- Used:      ${formatUnits(used, 6)} USDC`);
  }
}

// CLI Entrypoint
async function main() {
  const bot = new TradingBot();
  const args = argv.slice(2);
  const cmd = args[0];

  try {
    switch (cmd) {
      case "deposit":
        return args[1] ? await bot.depositCollateral(args[1]) : console.log("Usage: deposit <amount>");
      case "withdraw":
        return args[1] ? await bot.withdrawCollateral(args[1]) : console.log("Usage: withdraw <amount>");
      case "market":
        return args[4]
          ? await bot.placeMarketOrder(args[1], parseBool(args[2]), args[3], parseInt(args[4]))
          : console.log("Usage: market <market> <long|short> <size> <leverage>");
      case "limit":
        return args[5]
          ? await bot.placeLimitOrder(args[1], parseBool(args[2]), args[3], args[4], parseInt(args[5]))
          : console.log("Usage: limit <market> <long|short> <size> <price> <leverage>");
      case "close":
        return args[1] ? await bot.closePosition(parseInt(args[1])) : console.log("Usage: close <positionId>");
      case "price":
        return args[1] ? await bot.getCurrentPrice(args[1]) : console.log("Usage: price <market>");
      case "collateral":
        return await bot.getCollateralInfo();
      default:
        console.log(`
📊 Trading CLI (Ethers v6)
--------------------------
Commands:
  deposit <amount>                                Deposit USDC as collateral
  withdraw <amount>                               Withdraw USDC collateral
  market <market> <long|short> <size> <lev>       Place a market order
  limit <market> <long|short> <size> <price> <lev> Place a limit order
  close <positionId>                              Close an open position
  price <market>                                  Get market price
  collateral                                      View collateral balances
`);
    }
  } catch (err) {
    console.error("❌ Error:", err);
  }
}

if (require.main === module) {
  main();
}
