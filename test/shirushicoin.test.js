/**
 * ShirushiCoin v3.1 test suite.
 *
 *   npm test        (= sh scripts/build.sh && hardhat run --no-compile test/shirushicoin.test.js)
 *
 * Runs against the bytecode produced from solc-input.json, i.e. the same bytecode that gets
 * verified on the explorer - not a separate Hardhat compilation. Exits non-zero on any failure.
 */
const { ethers, network } = require("hardhat");
const fs = require("fs"), path = require("path");
// solc-input.json（ビルドの唯一の正本）から scripts/build.sh が生成した成果物を使う。
// Hardhat 自身にはコンパイルさせない: 検証対象は「エクスプローラで検証するのと同じバイトコード」。
const ARTIFACT = path.join(__dirname, "../build/ShirushiCoin.json");
if (!fs.existsSync(ARTIFACT)) {
  console.error("build/ShirushiCoin.json がありません。先に sh scripts/build.sh を実行してください");
  process.exit(1);
}
const artifact = JSON.parse(fs.readFileSync(ARTIFACT, "utf8"));
const ABI = artifact.abi;
const BIN = artifact.bytecode;
const D = 10n ** 18n;
let pass = 0, fail = 0;
const check = (n, ok, x = "") => { ok ? pass++ : fail++; console.log(`  ${ok ? "OK " : "NG "} ${n}${x ? "   [" + x + "]" : ""}`); };
async function rv(p, exp, I) {
  try { await p; return { ok: false, got: "revert しなかった" }; }
  catch (e) { const b = JSON.stringify(e, (k, v) => typeof v === "bigint" ? v.toString() : v);
    for (const d of (b.match(/0x[0-9a-fA-F]{8,}/g) || [])) { try { const q = I.parseError(d); if (q) return { ok: q.name === exp, got: q.name }; } catch (_) {} }
    return { ok: false, got: (e.shortMessage || "").slice(0, 55) }; }
}
const evs = (rc, I, name) => rc.logs.map(l => { try { return I.parseLog(l); } catch (_) { return null; } })
                               .filter(Boolean).filter(p => !name || p.name === name);
let S, F;
const roles = () => ({ admin: S[1].address, freezer: S[2].address, whitelistAdmin: S[3].address,
                       miningAdmin: S[4].address, miner: S[5].address, recorder: S[6].address });
const deploy = async (pool, h, a, l) => { const c = await F.deploy(roles(), pool, h, a, l); await c.waitForDeployment(); return c; };

async function main() {
  S = await ethers.getSigners();
  F = new ethers.ContractFactory(ABI, BIN, S[0]);
  const [dep, admin, fr, wl, ma, mi, rc, pool, h1, ex1, pool2, T, v1, v2, dest, other] = S;
  let c = await deploy(pool.address, [h1.address], [200_000_000n * D], 9_690_500n * D);
  let I = c.interface;

  console.log("\n【1】pool は自動登録されない（F-1 の撤回）");
  check("登録簿は空", (await c.registeredExchangeCount()) === 0n);
  check("poolAccount は未登録", !(await c.isRegisteredExchange(pool.address)));
  await (await c.connect(fr).freeze(pool.address)).wait();
  check("poolAccount は凍結できる（封じ込め手段が戻った）", await c.isFrozen(pool.address));
  let r = await rv(c.connect(mi).mine(2026), "ERC20UserRestricted", I);
  check("凍結中は mine が止まる（S-5・可逆な仕様）", r.ok, r.got);
  await (await c.connect(fr).unfreeze(pool.address)).wait();
  await (await c.connect(mi).mine(2026)).wait();
  check("解凍すれば採掘は復旧する", (await c.balanceOf(pool.address)) === 7290n * D);

  console.log("\n【2】ホワイトリストは追記専用のまま（回帰）");
  const rc1 = await (await c.connect(wl).registerExchange(ex1.address)).wait();
  check("registerExchange(ex1) の index=0", evs(rc1, I, "ExchangeRegistered")[0]?.args[1] === 0n);
  r = await rv(c.connect(fr).freeze(ex1.address), "ExchangeAddressProtected", I);
  check("登録済みは freeze 不可", r.ok, r.got);
  r = await rv(c.connect(admin).grantRole(await c.FREEZER_ROLE(), admin.address), "", I);
  await (await c.connect(admin).grantRole(await c.WHITELIST_ROLE(), admin.address)).wait();
  r = await rv(c.connect(admin).freeze(ex1.address), "ExchangeAddressProtected", I);
  check("DEFAULT_ADMIN でも freeze 不可", r.ok, r.got);
  check("ABI に unregisterExchange なし", !ABI.some(x => x.type === "function" && x.name === "unregisterExchange"));

  console.log("\n【3】冪等性：空振りは revert せずイベントも出さない（F-4）");
  const f1 = await (await c.connect(fr).freeze(v1.address)).wait();
  check("1回目の freeze: AccountFrozen が出る", evs(f1, I, "AccountFrozen").length === 1);
  const f2 = await (await c.connect(fr).freeze(v1.address)).wait();
  check("2回目の freeze: 成功するがイベントは出ない", evs(f2, I, "AccountFrozen").length === 0);
  await (await c.connect(fr).unfreeze(v1.address)).wait();
  const u2 = await (await c.connect(fr).unfreeze(v1.address)).wait();
  check("2回目の unfreeze: 成功するがイベントは出ない", evs(u2, I, "AccountFrozen").length === 0);
  const g2 = await (await c.connect(wl).registerExchange(ex1.address)).wait();
  check("2回目の registerExchange: イベントなし・重複なし",
        evs(g2, I, "ExchangeRegistered").length === 0 && (await c.registeredExchangeCount()) === 1n);
  const uAllowed = await (await c.connect(fr).unfreeze(ex1.address)).wait();
  check("unfreeze(登録済み) は no-op で ALLOWED を剥がさない",
        evs(uAllowed, I, "AccountFrozen").length === 0 && await c.isRegisteredExchange(ex1.address));
  const p0 = await (await c.connect(ma).setPoolAccount(pool.address)).wait();
  check("setPoolAccount(同値): イベントなし", evs(p0, I, "PoolAccountChanged").length === 0);
  const cur = await c.getMiningReward(2030);
  const m0 = await (await c.connect(ma).setMiningReward(2030, cur)).wait();
  check("setMiningReward(同値): イベントなし", evs(m0, I, "MiningRewardChanged").length === 0);
  const m1 = await (await c.connect(ma).setMiningReward(2030, cur + 1n)).wait();
  check("値が変わる時だけイベントが出る", evs(m1, I, "MiningRewardChanged").length === 1);

  console.log("\n【4】凍結した spender は他人の残高を抜けない（回帰）");
  const c4 = await deploy(pool.address, [v1.address, v2.address], [1000n * D, 1000n * D], 0);
  const I4 = c4.interface;
  await (await c4.connect(v1).approve(T.address, ethers.MaxUint256)).wait();
  await (await c4.connect(fr).freeze(T.address)).wait();
  r = await rv(c4.connect(T).transferFrom(v1.address, dest.address, 1000n * D), "ERC20UserRestricted", I4);
  check("凍結中 spender の transferFrom が revert", r.ok, r.got);
  check("被害者の残高は無傷", (await c4.balanceOf(v1.address)) === 1000n * D);
  await (await c4.connect(fr).unfreeze(T.address)).wait();
  await (await c4.connect(T).transferFrom(v1.address, dest.address, 10n * D)).wait();
  check("解凍後は正常に通る（過剰規制でない）", (await c4.balanceOf(dest.address)) === 10n * D);

  console.log("\n【5】setPoolAccount のガード（F-1 撤回後）");
  check("未登録アドレスにも切替できる", await (async () => {
    await (await c.connect(ma).setPoolAccount(pool2.address)).wait();
    return (await c.getPoolAccount()) === pool2.address; })());
  await (await c.connect(fr).freeze(other.address)).wait();
  r = await rv(c.connect(ma).setPoolAccount(other.address), "PoolAccountIsFrozen", I);
  check("凍結中アドレスは pool にできない", r.ok, r.got);
  r = await rv(c.connect(ma).setPoolAccount(ethers.ZeroAddress), "ZeroAddress", I);
  check("0x0 は不可", r.ok, r.got);

  console.log("\n【6】address(this) ガード（L-1）");
  const nonce = await ethers.provider.getTransactionCount(dep.address);
  const selfAddr = ethers.getCreateAddress({ from: dep.address, nonce });
  r = await rv(F.deploy(roles(), selfAddr, [h1.address], [1000n * D], 0), "InvalidExchangeAddress", I);
  check("poolAccount = 自分自身 は拒否", r.ok, r.got);
  const nonce2 = await ethers.provider.getTransactionCount(dep.address);
  const selfAddr2 = ethers.getCreateAddress({ from: dep.address, nonce: nonce2 });
  r = await rv(F.deploy(roles(), pool.address, [selfAddr2], [1000n * D], 0), "InvalidExchangeAddress", I);
  check("genesisHolders に自分自身 は拒否", r.ok, r.got);
  r = await rv(c.connect(wl).registerExchange(await c.getAddress()), "InvalidExchangeAddress", I);
  check("registerExchange(自分自身) は拒否", r.ok, r.got);

  console.log("\n【7】genesis 重複・供給会計");
  r = await rv(F.deploy(roles(), pool.address, [h1.address, h1.address], [100n * D, 50n * D], 0), "DuplicateGenesisHolder", I);
  check("genesisHolders の重複を拒否", r.ok, r.got);
  const c7 = await deploy(pool.address, [h1.address], [1000n * D], 900n * D);
  check("legacyMinedSupply() が読める", (await c7.legacyMinedSupply()) === 900n * D);
  check("minedByThisContract() = 0", (await c7.minedByThisContract()) === 0n);
  await (await c7.connect(mi).mine(2026)).wait();
  check("mine 後 minedByThisContract() = 7290", (await c7.minedByThisContract()) === 7290n * D);
  const c7b = await deploy(pool.address, [h1.address], [1000n * D], 5000n * D);
  check("累積実績 > 残存供給 でもデプロイ可", (await c7b.legacyMinedSupply()) === 5000n * D);
  r = await rv(F.deploy(roles(), pool.address, [h1.address], [1000n * D], 300_000_001n * D), "InvalidMiningSupply", I);
  check("cap 超の legacy は拒否", r.ok, r.got);

  console.log("\n【8】採掘スケジュール・ロール・ERC165（回帰）");
  check("getMiningReward(2122) == 0", (await c.getMiningReward(2122)) === 0n);
  // mine() は間隔チェックを最初に行うので、年の検証を確かめるにはクールダウンを明けておく
  await network.provider.send("evm_increaseTime", [23 * 3600]);
  r = await rv(c.connect(mi).mine(2122), "NoRewardForYear", I); check("2122 は NoRewardForYear", r.ok, r.got);
  r = await rv(c.connect(mi).mine(2021), "InvalidNumber", I); check("2021 は InvalidNumber", r.ok, r.got);
  r = await rv(c.connect(admin).grantRole(ethers.ZeroHash, other.address), "AdminIsFixed", I);
  check("DEFAULT_ADMIN の付与は不可", r.ok, r.got);
  r = await rv(c.connect(admin).renounceRole(ethers.ZeroHash, admin.address), "AdminIsFixed", I);
  check("保持者の放棄は不可", r.ok, r.got);
  await (await c.connect(other).renounceRole(ethers.ZeroHash, other.address)).wait();
  check("未保持者の renounce は no-op で成功", !(await c.hasRole(ethers.ZeroHash, other.address)));
  check("DEFAULT_ADMIN は admin 1 名のまま", (await c.getRoleMembers(ethers.ZeroHash)).length === 1);
  check("IERC5267 0x84b0196e", await c.supportsInterface("0x84b0196e"));
  check("IERC1363 0xb0202a11", await c.supportsInterface("0xb0202a11"));
  check("0xffffffff は false", !(await c.supportsInterface("0xffffffff")));

  console.log("\n【9】送金・バッチ（回帰）");
  await (await c.connect(h1).transfer(v2.address, 100n * D)).wait();
  check("通常送金", (await c.balanceOf(v2.address)) === 100n * D);
  await (await c.connect(v2).multiTransfer([dest.address, ex1.address], [D, D])).wait();
  check("multiTransfer は無権限で成功", (await c.balanceOf(ex1.address)) === D);
  r = await rv(c.connect(v2).multiTransfer([other.address, dest.address], [D, D]), "ERC20UserRestricted", I);
  check("凍結宛先を含むバッチは全体が revert（仕様 S-12）", r.ok, r.got);
  const poolNow = await c.getPoolAccount();
  const balBeforeMine = await c.balanceOf(poolNow);
  await (await c.connect(mi).mine(2026)).wait();
  check("クールダウン明けの mine は成功", (await c.balanceOf(poolNow)) === balBeforeMine + 7290n * D);
  r = await rv(c.connect(mi).mine(2026), "CooldownPeriod", I);
  check("直後の再 mine は CooldownPeriod", r.ok, r.got);
  r = await rv(c.connect(mi).mine(2021), "CooldownPeriod", I);
  check("間隔チェックは年の検証より先に走る（仕様）", r.ok, r.got);


  console.log("\n【10】今回追加したガード（R-1 / R-4 / R-5）");
  const cg = await deploy(pool.address, [h1.address], [1000n * D], 0);
  const Ig = cg.interface;
  r = await rv(cg.connect(ma).setPoolAccount(await cg.getAddress()), "InvalidExchangeAddress", Ig);
  check("setPoolAccount(コントラクト自身) を拒否", r.ok, r.got);
  await (await cg.connect(fr).freeze(pool.address)).wait();
  r = await rv(cg.connect(ma).setPoolAccount(pool.address), "PoolAccountIsFrozen", Ig);
  check("凍結中の現 pool を再設定すると revert（成功と誤報しない）", r.ok, r.got);
  check("その間 mine は止まったまま",
        (await rv(cg.connect(mi).mine(2026), "ERC20UserRestricted", Ig)).ok);
  r = await rv(cg.connect(fr).unfreeze(ethers.ZeroAddress), "ZeroAddress", Ig);
  check("unfreeze(0x0) は ZeroAddress（freeze と対称）", r.ok, r.got);
  r = await rv(cg.connect(fr).freeze(ethers.ZeroAddress), "ZeroAddress", Ig);
  check("freeze(0x0) も ZeroAddress", r.ok, r.got);

  console.log(`\n==== 合計 ${pass + fail} 件 / 成功 ${pass} / 失敗 ${fail} ====`);
  if (fail) process.exit(1);
}
main().catch(e => { console.error(e); process.exit(1); });
