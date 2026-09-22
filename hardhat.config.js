/**
 * Hardhat is used ONLY as an EVM to run test/shirushicoin.test.js against the prebuilt
 * artifact from scripts/build.sh. Compilation is deliberately disabled: the contract is
 * built from solc-input.json (the single source of truth) so that the tests exercise the
 * exact bytecode that gets deployed and verified.
 *
 * hardfork "prague" is required - the contract uses EIP-1153 (TSTORE/TLOAD) and EIP-5656 (MCOPY).
 */
require("@nomicfoundation/hardhat-ethers");

module.exports = {
  solidity: { version: "0.8.36", settings: { optimizer: { enabled: false, runs: 200 }, evmVersion: "prague" } },
  paths: { sources: "./test/no-compile" },
  networks: { hardhat: { hardfork: "prague" } },
};
