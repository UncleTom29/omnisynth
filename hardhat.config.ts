import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ignition";
import * as dotenv from "dotenv";

dotenv.config();

// Load environment variables
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0000000000000000000000000000000000000000000000000000000000000000";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY!;
const ARBISCAN_API_KEY =  process.env.ARBISCAN_API_KEY!;
const BASESCAN_API_KEY = process.env.BASESCAN_API_KEY!;

// RPC URLs
const SEPOLIA_RPC = process.env.SEPOLIA_RPC 
const BASE_SEPOLIA_RPC = process.env.BASE_SEPOLIA_RPC 
const ARBITRUM_SEPOLIA_RPC = process.env.ARBITRUM_SEPOLIA_RPC
const AVAX_TESTNET_RPC = process.env.AVAX_TESTNET_RPC

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
    
  }, 
  networks: {
    // Testnet networks
    sepolia: {
      url: SEPOLIA_RPC,
      accounts: [PRIVATE_KEY],
      chainId: 11155111,
      gasPrice: 20000000000, // 20 gwei
    },
    baseSepolia: {
      url: BASE_SEPOLIA_RPC,
      accounts: [PRIVATE_KEY],
      chainId: 84532,
      gasPrice: 1000000000, // 1 gwei
    },
    arbitrumSepolia: {
      url: ARBITRUM_SEPOLIA_RPC,
      accounts: [PRIVATE_KEY],
      chainId: 421614,
      gasPrice: 100000000, // 0.1 gwei
    },
    avaxTestnet: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      accounts: [PRIVATE_KEY],
      chainId: 43113,
      gasPrice: 25000000000, // 25 nAVAX
    },
    // // Local network
    // hardhat: {
    //   chainId: 31337,
    //   gas: 12000000,
    //   blockGasLimit: 12000000,
    //   allowUnlimitedContractSize: true,
    // },
    // localhost: {
    //   url: "http://127.0.0.1:8545",
    //   chainId: 31337,
    // },
  },
  etherscan: {
    apiKey: {
      sepolia: ETHERSCAN_API_KEY,
      baseSepolia: BASESCAN_API_KEY,
      arbitrumSepolia: ARBISCAN_API_KEY,
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org"
        }
      },
      {
        network: "arbitrumSepolia",
        chainId: 421614,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io"
        }
      }
    ]
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
    ignition: "./ignition",
  },
  mocha: {
    timeout: 60000,
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
  },
};

export default config;