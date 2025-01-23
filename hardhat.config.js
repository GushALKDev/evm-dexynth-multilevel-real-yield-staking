require("@nomicfoundation/hardhat-toolbox");
require("hardhat-deploy")
require('hardhat-coverage');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.19",
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 31337,
      blockConfirmations: 1,
    },
    hardhatNode: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    ganache: {
      url: "http://127.0.0.1:7545",
      chainId: 1337,
    },
  }
};
