# omnisynth
AI-powered DeFi protocol combining perpetual leverage trading, intelligent yield optimization, liquid staking, bridging, lending &amp; borrowing in one unified ecosystem and liquidity, powered by Chainlink. OmniSynth is a cross-chain DeFi protocol that leverages Chainlink's decentralized services to create a secure, efficient, and feature-rich financial ecosystem.

Sepolia Deployments:

  LiquidityPool: 0x49e91BDa64F81006DEC75E2110722db068c05614

  TradingEngine: 0x0989a224e2730d0595628704f4d18C14696A4087

  Lending: 0x1f2725c3Ace742d9DcBaBD896733c4B57394A326

  Stake: 0x217e2922d85AF382F5F9B02ef393644C3E542555

  Vault: 0xA73F8C70DcC2C711508A6bB880eFc5bCf6fEF47B
  
  Bridge: 0xb6BC50B0C16c8F97aF1288Cf72028Cfa0ed9483D



## Project Description

OmniSynth integrates multiple DeFi products into a cohesive platform:

- **AI-Powered Vault**: Uses Chainlink Functions for dynamic strategy optimization and VRF for secure, randomized rebalancing.
- **Perpetual Trading Engine**: Employs Chainlink Price Feeds for accurate asset pricing and Automation for timely upkeep tasks.
- **Liquid Staking**: Implements VRF for unbiased validator selection and Price Feeds for reward calculations.
- **Cross-Chain Bridge**: Facilitates seamless token transfers across blockchains using Chainlink CCIP.
- **Lending Protocol**: Enables borrowing and lending with collateral valuation powered by Chainlink Price Feeds.

### Architecture

The protocol's modular architecture ensures seamless interaction between components:

- **Vault**: Manages AI-driven investment strategies.
- **Trading Engine**: Handles perpetual trading with real-time pricing.
- **Staking**: Provides liquid staking with fair reward distribution.
- **Liquidity Pool**: Supports trading with necessary liquidity.
- **Bridge**: Enables cross-chain asset transfers.
- **Lending**: Offers secure borrowing and lending services.

### Stack

- **Smart Contracts**: Solidity
- **Oracles**: Chainlink (Functions, VRF, Price Feeds, Automation, CCIP)
- **Standards**: OpenZeppelin (ERC20, Ownable, etc.)
- **Development**: Hardhat

## Chainlink Integrations

OmniSynth extensively utilizes Chainlink's decentralized services:

- **Functions**: AI-powered strategy optimization ([Vault.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/Vault.sol))
- **VRF**: Randomized rebalancing [Vault.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/Vault.sol), validator selection ([Stake.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/Stake.sol))
- **Price Feeds**: Asset pricing ([TradingEngine.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/TradingEngine.sol), [Stake.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/Stake.sol), [Lending.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/Lending.sol))
- **Automation**: Upkeep tasks ([TradingEngine.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/TradingEngine.sol))
- **CCIP**: Cross-chain transfers ([Bridge.sol](https://github.com/uncletom29/OmniSynth/blob/main/contracts/Bridge.sol))