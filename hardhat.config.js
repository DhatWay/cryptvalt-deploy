require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  ssolidity: {
  version: "0.8.28",
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "cancun",
    viaIR: true,
  },
},
  networks: {
    hardhat: {},
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "https://rpc.sepolia.org",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
};
