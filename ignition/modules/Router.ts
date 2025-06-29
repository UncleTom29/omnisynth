import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const RouterModule = buildModule("RouterModule", (m) => {
  // Get the deployer account
  const deployer = m.getAccount(0);
  
  // Fee collector (can be same as deployer initially)
  const feeCollector = m.getParameter("feeCollector", deployer);
  
  // Deploy Router contract
  const router = m.contract("OmniRouter", [feeCollector], {
    from: deployer,
  });

  return { router };
});

export default RouterModule;