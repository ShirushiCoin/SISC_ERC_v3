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
# `deployedBytecode` and `immutableReferences` are what let verify-deployment.ts prove that the
# audited code is the code actually living at an address; `solcInputHash` refuses a stale artifact.
#
# NOTE: this calls solc through its Node API, NOT the `solc` CLI. The CLI writes diagnostics such
# as ">>> Cannot retry compilation with SMT because there are no SMT solvers available." to
# stdout (node_modules/solc/solc.js), which corrupts the JSON on any machine without z3/cvc5
# installed - i.e. on most auditor, exchange and CI machines. The Node API returns the JSON
# string directly and has no such behaviour.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
node -e '
const fs = require("fs"), crypto = require("crypto"), solc = require("solc");
const inputJson = fs.readFileSync("solc-input.json", "utf8");
const out = JSON.parse(solc.compile(inputJson));
const fatal = (out.errors || []).filter(e => e.severity === "error");
if (fatal.length) { fatal.forEach(e => console.error(e.formattedMessage)); process.exit(1); }
const c = out.contracts["contracts/ShirushiCoin.sol"].ShirushiCoin;
const solcInputHash = crypto.createHash("sha256").update(inputJson).digest("hex");
fs.writeFileSync("build/ShirushiCoin.json", JSON.stringify({
  abi: c.abi,
  bytecode: "0x" + c.evm.bytecode.object,
  deployedBytecode: "0x" + c.evm.deployedBytecode.object,
  immutableReferences: c.evm.deployedBytecode.immutableReferences || {},
  solcInputHash,
}, null, 2));
console.log("build/ShirushiCoin.json written | deployed size "
  + c.evm.deployedBytecode.object.length / 2 + " bytes / 24576");
console.log("solc version: " + solc.version());
console.log("solc-input.json sha256: " + solcInputHash);
'
