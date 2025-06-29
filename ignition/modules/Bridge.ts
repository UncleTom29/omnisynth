// ignition/modules/TokenTransferor.js
const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("TokenTransferorModule", (m: { getParameter: (arg0: string, arg1: string) => any; contract: (arg0: string, arg1: any[]) => any; }) => {
  // Parameters with default values (can be overridden during deployment)
  const router = m.getParameter("router", "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59");
  const link = m.getParameter("link", "0x779877A7B0D9E8603169DdbD7836e478b4624789");
  
  // Deploy the TokenTransferor contract
  const tokenTransferor = m.contract("TokenTransferor", [router, link]);

  // Return the deployed contract
  return { tokenTransferor };
});