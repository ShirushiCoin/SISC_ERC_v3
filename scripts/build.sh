#!/bin/sh
# Build the deployment artifact from solc-input.json, the single source of truth for the build.
#
#   sh scripts/build.sh   ->  build/ShirushiCoin.json
#       { abi, bytecode, deployedBytecode, immutableReferences, solcInputHash }
#
# Uses the exact pinned settings embedded in solc-input.json (solc 0.8.36, evmVersion prague,
# optimizer off / runs 200), so the result matches contracts/ShirushiCoin_flattened.sol and
# whatever you verify on the explorer.
#
# `deployedBytecode` is what lets verify-deployment.ts prove that the audited code is the code
# actually living at an address; `solcInputHash` lets deploy-sisc.ts refuse a stale artifact.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
npx solc --standard-json < solc-input.json > build/solc-output.json
node -e '
const fs = require("fs"), crypto = require("crypto");
const out = JSON.parse(fs.readFileSync("build/solc-output.json", "utf8"));
const fatal = (out.errors || []).filter(e => e.severity === "error");
if (fatal.length) { fatal.forEach(e => console.error(e.formattedMessage)); process.exit(1); }
const c = out.contracts["contracts/ShirushiCoin.sol"].ShirushiCoin;
const solcInputHash = crypto.createHash("sha256")
  .update(fs.readFileSync("solc-input.json")).digest("hex");
fs.writeFileSync("build/ShirushiCoin.json", JSON.stringify({
  abi: c.abi,
  bytecode: "0x" + c.evm.bytecode.object,
  deployedBytecode: "0x" + c.evm.deployedBytecode.object,
  immutableReferences: c.evm.deployedBytecode.immutableReferences || {},
  solcInputHash,
}, null, 2));
console.log("build/ShirushiCoin.json written | deployed size "
  + c.evm.deployedBytecode.object.length / 2 + " bytes / 24576");
console.log("solc-input.json sha256: " + solcInputHash);
'
