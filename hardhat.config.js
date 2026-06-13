require('@nomicfoundation/hardhat-toolbox');
require('@nomicfoundation/hardhat-verify');
require('dotenv').config();

const PRIVATE_KEY    = process.env.PRIVATE_KEY    || '';
const ALCHEMY_SEPOLIA = process.env.ALCHEMY_SEPOLIA || '';
const ALCHEMY_MAINNET = process.env.ALCHEMY_MAINNET || '';
const ETHERSCAN_KEY  = process.env.ETHERSCAN_API_KEY || '';

module.exports = {
  solidity: {
    compilers: [
      { version: '0.8.20', settings: { optimizer: { enabled: true, runs: 200 } } },
      { version: '0.8.0',  settings: { optimizer: { enabled: true, runs: 200 } } },
    ],
  },

  networks: {
    // ── Sepolia Testnet ──────────────────────────────────
    sepolia: {
      url:      ALCHEMY_SEPOLIA,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      chainId:  11155111,
    },

    // ── Ethereum Mainnet ─────────────────────────────────
    // Uncomment after Sepolia testing is complete
    // mainnet: {
    //   url:      ALCHEMY_MAINNET,
    //   accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    //   chainId:  1,
    // },
  },

  etherscan: {
    apiKey: ETHERSCAN_KEY,
  },

  sourcify: {
    enabled: true,
  },
};
