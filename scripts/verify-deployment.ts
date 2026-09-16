/**
 * Verify a deployed ShirushiCoin against scripts/sisc.config.ts AND against the audited build.
 *
 *   CONTRACT=0x... RPC_URL=... npx ts-node scripts/verify-deployment.ts
 *
 * Run this BEFORE any other post-deploy action. Nothing here writes to the chain.
 * Role assignment cannot be corrected afterwards, so a mismatch means: stop and redeploy.
 *
 * LIMITATION worth knowing: this script imports the SAME scripts/sisc.config.ts that
 * deploy-sisc.ts used. It therefore proves "the chain matches the config", not "the config was
 * right". A transposition inside the config file itself passes every check below. The role
 * addresses are printed in full so a second person can read them against an independent source.
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import { config } from "./sisc.config";

const ARTIFACT = process.env.ARTIFACT || path.join(__dirname, "../build/ShirushiCoin.json");
let bad = 0;
const check = (name: string, ok: boolean, detail = "") => {
  if (!ok) bad++;
  console.log(`  ${ok ? "OK " : "NG "} ${name}${detail ? "   " + detail : ""}`);
};
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** Strip the trailing CBOR metadata blob, whose hash differs for any comment-only change. */
function stripMetadata(hex: string): string {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length < 4) return h;
  const raw = parseInt(h.slice(-4), 16);
  // A malformed or absent trailing length leaves the string untouched. Both sides are stripped
  // the same way, so this can only ever cause a mismatch (fail-safe), never a false match.
  if (!Number.isFinite(raw) || raw <= 0) return h;
  const len = raw + 2;
  return len * 2 < h.length ? h.slice(0, h.length - len * 2) : h;
}

/** Zero out the immutable slots, which are written at construction and so differ per deployment. */
function maskImmutables(hex: string, refs: Record<string, { start: number; length: number }[]>): string {
  const bytes = Buffer.from(hex, "hex");
  for (const spans of Object.values(refs || {})) {
    for (const { start, length } of spans) {
      // Skip spans that fall outside the buffer. This happens whenever the code at the address
      // is not this contract (an EOA, a proxy, a different token). Without the guard Buffer.fill
      // throws RangeError and the whole report dies - at the one check that matters most.
      if (start < 0 || start + length > bytes.length) continue;
      bytes.fill(0, start, start + length);
    }
  }
  return bytes.toString("hex");
}

async function main() {
  const addr = process.env.CONTRACT;
  if (!addr || !process.env.RPC_URL) { console.error("CONTRACT と RPC_URL が必要です"); process.exit(1); }
  if (!fs.existsSync(ARTIFACT)) { console.error(`${ARTIFACT} がありません。sh scripts/build.sh を実行してください`); process.exit(1); }
  const artifact = JSON.parse(fs.readFileSync(ARTIFACT, "utf8"));
  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
  const c = new ethers.Contract(addr, artifact.abi, provider);
  const r = config.roleHolders;

  console.log("\n=== 接続先と成果物 ===");
  const net = await provider.getNetwork();
  check(`chainId = ${config.expectedChainId}`, net.chainId === BigInt(config.expectedChainId),
        `実際: ${net.chainId}`);
  const solcInputHash = crypto.createHash("sha256")
    .update(fs.readFileSync(path.join(__dirname, "../solc-input.json"))).digest("hex");
  check("成果物が現在の solc-input.json から生成されている",
        artifact.solcInputHash === solcInputHash);

  console.log("\n=== デプロイ済みコードが監査対象と同一か（最重要）===");
  const onChain = await provider.getCode(addr);
  const hasCode = onChain !== "0x" && onChain.length > 2;
  check("アドレスにコードが存在する", hasCode);
  if (!hasCode) {
    console.error("\n  このアドレスにコントラクトがありません。CONTRACT の指定を確認してください。\n");
    process.exit(1);
  }
  const a = maskImmutables(stripMetadata(artifact.deployedBytecode), artifact.immutableReferences);
  const b = maskImmutables(stripMetadata(onChain), artifact.immutableReferences);
  const codeMatches = a === b;
  check("デプロイ済み runtime コードがビルド結果と一致（メタデータと immutable を除く）",
        codeMatches, `ビルド ${a.length / 2} bytes / チェーン ${b.length / 2} bytes`);

  console.log("\n=== 削除済み機能が実際のコードに無いか ===");
  if (!codeMatches) {
    // セレクタ走査は「このランタイムの dispatch table に無い」ことしか示さない。コードが違う
    // 場合、例えば proxy なら全セレクタが不在に見えて委譲先には存在しうる（誤った安心）。
    // したがってバイトコードが一致したときだけ意味を持つ検査として扱う。
    console.log("  スキップ: デプロイ済みコードがビルド結果と一致しないため、この走査は無意味です");
    console.log("  （proxy 等では全セレクタが不在に見え、委譲先に実装が存在しえます）");
  } else {
    const runtime = onChain.slice(2).toLowerCase();
    for (const sig of ["adminMint(address,uint256)", "adminBurn(address,uint256)", "burn(uint256)",
                       "burnFrom(address,uint256)", "pause()", "unpause()",
                       "unregisterExchange(address)"]) {
      const selector = ethers.id(sig).slice(2, 10);
      check(`${sig} のセレクタ 0x${selector} が存在しない`, !runtime.includes(selector));
    }
  }

  console.log("\n=== トークン ===");
  check("name = Shirushi Coin", (await c.name()) === "Shirushi Coin");
  check("symbol = SISC", (await c.symbol()) === "SISC");
  check("decimals = 18", (await c.decimals()) === 18n);
  check("VERSION = 3.10", (await c.VERSION()) === "3.10");

  console.log("\n=== ロール（admin の誤りは回復不能。独立した資料と突き合わせること）===");
  const ROLES: [string, string][] = [
    ["DEFAULT_ADMIN_ROLE", r.admin], ["FREEZER_ROLE", r.freezer], ["WHITELIST_ROLE", r.whitelistAdmin],
    ["MINING_ADMIN_ROLE", r.miningAdmin], ["MINER_ROLE", r.miner], ["RECORDER_ROLE", r.recorder],
  ];
  for (const [name, expected] of ROLES) {
    const id = name === "DEFAULT_ADMIN_ROLE" ? ethers.ZeroHash : ethers.id(name);
    const members: string[] = await c.getRoleMembers(id);
    if (expected === ethers.ZeroAddress) { check(`${name} は保持者なし`, members.length === 0); continue; }
    check(`${name} = ${expected}`, members.length === 1 && same(members[0], expected),
          members.length ? `実際: ${members.join(", ")}` : "実際: (なし)");
  }
  check("fixedAdminAccount が config の admin と一致", same(await c.fixedAdminAccount(), r.admin));

  // EIP-712 のドメインは immutable としてコードに焼かれるため、上のバイトコード照合では
  // マスクされて比較対象外になる。permit が想定どおり動くかは view で別途確かめる。
  const dom = await c.eip712Domain();
  check("EIP-712 domain name = Shirushi Coin", dom[1] === "Shirushi Coin", dom[1]);
  check("EIP-712 domain version = 1", dom[2] === "1", dom[2]);
  check("EIP-712 domain chainId が接続先と一致", dom[3] === net.chainId, dom[3].toString());
  check("EIP-712 domain verifyingContract = このアドレス", same(dom[4], addr), dom[4]);
  const expectedSep = ethers.TypedDataEncoder.hashDomain(
    { name: dom[1], version: dom[2], chainId: dom[3], verifyingContract: dom[4] });
  check("DOMAIN_SEPARATOR が再計算値と一致", (await c.DOMAIN_SEPARATOR()) === expectedSep);

  console.log("\n=== 供給会計 ===");
  const total = config.genesisAmounts.reduce((s, x) => s + x, 0n);
  const cap = await c.cap(), supply = await c.totalSupply();
  check("genesisSupply = 設定の合計", (await c.genesisSupply()) === total, ethers.formatEther(total));
  check("totalSupply = genesisSupply", supply === total);
  check("legacyMinedSupply = 設定値", (await c.legacyMinedSupply()) === config.legacyMinedSupply);
  check("minedByThisContract = 0（未採掘）", (await c.minedByThisContract()) === 0n);
  check("cap = 300,000,000", cap === 300_000_000n * 10n ** 18n);
  console.log("     残り発行可能量 = cap - totalSupply =", ethers.formatEther(cap - supply), "SISC");
  console.log("     ※ cap - totalMiningSupply は残枠ではありません（legacy 分を含むため）");

  console.log("\n=== genesis 配分 ===");
  for (let i = 0; i < config.genesisHolders.length; i++) {
    const h = config.genesisHolders[i];
    check(`balanceOf(${h})`, (await c.balanceOf(h)) === config.genesisAmounts[i],
          ethers.formatEther(config.genesisAmounts[i]) + " SISC");
  }

  console.log("\n=== pool / ホワイトリスト ===");
  check("poolAccount = 設定値", same(await c.getPoolAccount(), config.poolAccount));
  check("poolAccount が凍結されていない", !(await c.isFrozen(config.poolAccount)));
  const list: string[] = await c.getRegisteredExchanges();
  check("登録簿は空（デプロイ時に自動登録はしない）", list.length === 0, list.join(", "));
  console.log("     poolAccount をホワイトリスト登録するかは運用判断です。登録すると恒久的に");
  console.log("     凍結不能になり、採掘先を事後に封じ込める手段を失います（security-notes S-5）。");

  console.log(bad === 0
    ? "\n  すべて一致しました。運用を開始できます。\n"
    : `\n  ${bad} 件が一致しません。これ以上の操作を行わず、再デプロイを検討してください。\n`);
  if (bad) process.exit(1);
}

main().catch(e => { console.error(e); process.exit(1); });
