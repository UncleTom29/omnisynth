import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const PoolModule = buildModule("PoolModuleV2", (m) => {
  // Get the deployer account
  const deployer = m.getAccount(0);

  // Deploy mock USDC for testing (only on testnets)
  const USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"

  // Deploy the Liquidity Pool contract
  const liquidityPool = m.contract("OmniLiquidityPool", [USDC, deployer], {
    id: "OmniLiquidityPool"
  });

  // Add supported markets
  const markets = ["BTC/USD", "ETH/USD", "LINK/USD"];
  
  const addMarketFutures: any[] = [];
  markets.forEach((market, index) => {
    const future = m.call(liquidityPool, "addMarket", [market], {
      id: `addMarket_${market.replace("/", "_")}`,
      after: index === 0 ? [] : [addMarketFutures[index - 1]]
    });
    addMarketFutures.push(future);
  });

  return { liquidityPool};
});

export default PoolModule;