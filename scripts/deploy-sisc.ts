/**
 * Deploy ShirushiCoin (SISC) v3.1.
 *
 *   sh scripts/build.sh                                  # produce build/ShirushiCoin.json
 *   npx ts-node scripts/deploy-sisc.ts                   # dry run: checks only, no transaction
 *   CONFIRM=DEPLOY RPC_URL=... PRIVATE_KEY=... npx ts-node scripts/deploy-sisc.ts
 *
 * The deployer receives NO role.
 *
 * Why this script rather than Remix or Etherscan: the constructor takes a struct of six
 * addresses, which ABI-encodes as six bare address words. The field names survive only when
 * the call is built from a named object, as it is below. In Remix the tuple is a single text
 * field and on Etherscan it is raw hex, so a transposition there is silent - and putting the
 * wrong address in `admin` is UNRECOVERABLE.
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import { config } from "./sisc.config";

const CAP = 300_000_000n * 10n ** 18n;
const MAX_BATCH = 100;
const ARTIFACT = process.env.ARTIFACT || path.join(__dirname, "../build/ShirushiCoin.json");

function fail(msg: string): never {
  console.error(`\n  設定エラー: ${msg}\n`);
  process.exit(1);
}

function preflight(): bigint {
  const r = config.roleHolders;
  for (const [name, addr] of Object.entries({ ...r, poolAccount: config.poolAccount })) {
    if (!ethers.isAddress(addr)) fail(`${name} が不正なアドレスです: ${addr}`);
    if (name !== "recorder" && addr === ethers.ZeroAddress) fail(`${name} はゼロアドレスにできません`);
  }
  if (config.genesisHolders.length === 0) fail("genesisHolders が空です");
  if (config.genesisHolders.length > MAX_BATCH) fail(`genesisHolders は最大 ${MAX_BATCH} 件です`);
  if (config.genesisHolders.length !== config.genesisAmounts.length) {
    fail("genesisHolders と genesisAmounts の長さが違います");
  }
  const seen = new Set<string>();
  for (const h of config.genesisHolders) {
    if (!ethers.isAddress(h)) fail(`genesisHolders に不正なアドレス: ${h}`);
    if (h === ethers.ZeroAddress) fail("genesisHolders にゼロアドレスは使えません");
    if (seen.has(h.toLowerCase())) fail(`genesisHolders が重複しています: ${h}（コントラクト側でも revert します）`);
    seen.add(h.toLowerCase());
  }
  for (const a of config.genesisAmounts) if (a <= 0n) fail("genesisAmounts はすべて 0 より大きい必要があります");

  const total = config.genesisAmounts.reduce((s, a) => s + a, 0n);
  if (total > CAP) fail(`genesisAmounts の合計 ${ethers.formatEther(total)} が cap 300,000,000 を超えます`);
  if (config.legacyMinedSupply > CAP) fail("legacyMinedSupply が cap を超えます");
  // Measured constructor gas: 7,919,946 (1 holder) .. 11,512,077 (100). A flat floor let a
  // 100-holder config through and then ran out of gas on-chain, burning the whole limit.
  const estimated = 7_950_000n + 36_500n * BigInt(config.genesisHolders.length - 1);
  const required = (estimated * 115n) / 100n;
  if (config.gasLimit < required) {
    fail(`gasLimit ${config.gasLimit} が不足しています。genesisHolders ${config.genesisHolders.length} 件の`
       + ` 推定消費は約 ${estimated}、15% の余裕を含めて ${required} 以上にしてください`);
  }
  if (!Number.isInteger(config.expectedChainId) || config.expectedChainId <= 0) {
    fail("expectedChainId を設定してください（Ethereum メインネットは 1）");
  }

  // admin スロットの誤りだけは回復不能（S-13）。運用鍵との同一指定は事故の兆候として強く警告する。
  const hot: [string, string][] = [["freezer", r.freezer], ["whitelistAdmin", r.whitelistAdmin],
                                   ["miningAdmin", r.miningAdmin], ["miner", r.miner]];
  for (const [name, addr] of hot) {
    if (addr.toLowerCase() === r.admin.toLowerCase()) {
      console.warn(`\n  警告: admin と ${name} が同じアドレスです。admin は永久に変更できないため、`);
      console.warn("        日常運用の鍵とは必ず分離してください。取り違えの可能性も確認を。\n");
    }
  }
  if (config.genesisHolders.some(h => h.toLowerCase() === config.poolAccount.toLowerCase())) {
    console.warn("  注意: poolAccount が genesisHolders に含まれています。意図した構成か確認してください。\n");
  }
  return total;
}

async function main() {
  const total = preflight();
  const r = config.roleHolders;

  console.log("\n=== デプロイ内容（すべてデプロイ後は変更不能）===");
  console.log("  admin          :", r.admin, " ← DEFAULT_ADMIN_ROLE。永久固定、間違えたら再デプロイのみ");
  console.log("  freezer        :", r.freezer);
  console.log("  whitelistAdmin :", r.whitelistAdmin);
  console.log("  miningAdmin    :", r.miningAdmin);
  console.log("  miner          :", r.miner);
  console.log("  recorder       :", r.recorder === ethers.ZeroAddress ? "(なし)" : r.recorder);
  console.log("  poolAccount    :", config.poolAccount, " ← 自動登録はされません。凍結可能なままです（登録するかは運用判断）");
  console.log("  genesis 配分   :");
  config.genesisHolders.forEach((h, i) =>
    console.log(`     ${h}  ${ethers.formatEther(config.genesisAmounts[i])} SISC`));
  console.log("  genesis 合計   :", ethers.formatEther(total), "SISC");
  console.log("  legacyMined    :", ethers.formatEther(config.legacyMinedSupply), "SISC（mint されません）");
  console.log("  デプロイ後の残枠:", ethers.formatEther(CAP - total), "SISC  (= cap - totalSupply)");
  console.log("  gasLimit       :", config.gasLimit.toString());

  if (process.env.CONFIRM !== "DEPLOY") {
    console.log("\n  事前チェックは通りました。実行するには CONFIRM=DEPLOY を付けてください。\n");
    return;
  }
  if (!process.env.RPC_URL || !process.env.PRIVATE_KEY) fail("RPC_URL と PRIVATE_KEY が必要です");
  if (!fs.existsSync(ARTIFACT)) fail(`${ARTIFACT} がありません。先に sh scripts/build.sh を実行してください`);

  const artifact = JSON.parse(fs.readFileSync(ARTIFACT, "utf8"));
  // 成果物が現在の solc-input.json から作られたものか（build/ は gitignore なので古い可能性がある）
  const solcInputHash = crypto.createHash("sha256")
    .update(fs.readFileSync(path.join(__dirname, "../solc-input.json"))).digest("hex");
  if (artifact.solcInputHash !== solcInputHash) {
    fail(`${ARTIFACT} が現在の solc-input.json と一致しません。sh scripts/build.sh を再実行してください`);
  }

  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

  // 最初のネットワーク接触を不可逆な tx にしない: 先に接続先を確認する
  const net = await provider.getNetwork();
  console.log("\n  接続先 chainId :", net.chainId.toString(), "(期待値", config.expectedChainId + ")");
  if (net.chainId !== BigInt(config.expectedChainId)) {
    fail(`接続先チェーンが違います: ${net.chainId} != ${config.expectedChainId}`);
  }

  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  // このデプロイで生まれるアドレスを先に求め、poolAccount / genesisHolders と衝突しないか見る。
  // トークン自身に送られた分は burn も rescue も無いため永久に失われる。
  const predicted = ethers.getCreateAddress({ from: wallet.address, nonce: await wallet.getNonce("pending") });
  console.log("  生成予定アドレス:", predicted);
  const collides = [config.poolAccount, ...config.genesisHolders]
    .filter(a => a.toLowerCase() === predicted.toLowerCase());
  if (collides.length) fail(`poolAccount / genesisHolders がこのコントラクト自身のアドレスと一致します: ${predicted}`);

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

  const contract = await factory.deploy(
    r,                        // 名前付きオブジェクト。フィールド名を保持するのはこの形だけ
    config.poolAccount,
    config.genesisHolders,
    config.genesisAmounts,
    config.legacyMinedSupply,
    { gasLimit: config.gasLimit },
  );
  console.log("\n  tx:", contract.deploymentTransaction()?.hash);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log("  デプロイ完了:", address);
  console.log("\n  他の操作を行う前に、必ず次を実行して突合してください:");
  console.log(`    CONTRACT=${address} RPC_URL=$RPC_URL npx ts-node scripts/verify-deployment.ts`);
}

main().catch(e => { console.error(e); process.exit(1); });
