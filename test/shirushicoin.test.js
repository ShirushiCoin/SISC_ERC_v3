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
  check("poolAccount は未登録", !(await c.isWhitelisted(pool.address)));
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
        evs(uAllowed, I, "AccountFrozen").length === 0 && await c.isWhitelisted(ex1.address));
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


  console.log("\n【11】外部レビュー指摘への追加（F-08 / F-05 不足分）");
  const c11 = await deploy(pool.address, [h1.address], [1000n * D], 0);
  const I11 = c11.interface;
  const self11 = await c11.getAddress();

  // --- F-08: トークン契約自身への送金を全経路で拒否 ---
  r = await rv(c11.connect(h1).transfer(self11, D), "ERC20InvalidReceiver", I11);
  check("transfer(トークン自身) を拒否", r.ok, r.got);
  r = await rv(c11.connect(h1).multiTransfer([self11], [D]), "ERC20InvalidReceiver", I11);
  check("multiTransfer(トークン自身) を拒否", r.ok, r.got);
  await (await c11.connect(h1).approve(other.address, 10n * D)).wait();
  r = await rv(c11.connect(other).transferFrom(h1.address, self11, D), "ERC20InvalidReceiver", I11);
  check("transferFrom(→トークン自身) を拒否", r.ok, r.got);
  await (await c11.connect(h1).transfer(dest.address, D)).wait();
  check("（対照）通常の送金は従来どおり通る", (await c11.balanceOf(dest.address)) === D);

  // --- 削除 7 関数の ABI 不在 ---
  for (const fn of ["burn", "burnFrom", "adminMint", "adminBurn", "pause", "unpause", "paused"]) {
    check(`ABI に ${fn} が無い`, !ABI.some(x => x.type === "function" && x.name === fn));
  }

  // --- MINER 以外からの mine 拒否 ---
  r = await rv(c11.connect(other).mine(2026), "AccessControlUnauthorizedAccount", I11);
  check("MINER 以外の mine を拒否", r.ok, r.got);
  r = await rv(c11.connect(admin).mine(2026), "AccessControlUnauthorizedAccount", I11);
  check("admin 直接の mine も拒否", r.ok, r.got);

  // --- 凍結中アドレスの登録拒否 ---
  await (await c11.connect(fr).freeze(other.address)).wait();
  r = await rv(c11.connect(wl).registerExchange(other.address), "FrozenAddressCannotBeRegistered", I11);
  check("凍結中アドレスの登録を拒否", r.ok, r.got);

  // --- 凍結 spender の transferFromAndCall ---
  const TFAC = "transferFromAndCall(address,address,uint256)";
  r = await rv(c11.connect(other)[TFAC](h1.address, dest.address, D), "ERC20UserRestricted", I11);
  check("凍結 spender の transferFromAndCall を拒否", r.ok, r.got);
  await (await c11.connect(fr).unfreeze(other.address)).wait();
  r = await rv(c11.connect(other)[TFAC](h1.address, dest.address, D), "ERC1363InvalidReceiver", I11);
  check("（対照）解凍後は受信者検査まで到達する", r.ok, r.got);

  // --- permit の成功と再利用拒否 ---
  const n0 = await c11.nonces(h1.address);
  // deadline は EVM の block.timestamp 基準で取る。先行テストで evm_increaseTime を使っており、
  // 壁時計から計算すると署名時点で既に期限切れ（ERC2612ExpiredSignature）になる。
  const dl = (await ethers.provider.getBlock("latest")).timestamp + 3600;
  const dm = await c11.eip712Domain();
  const sig = ethers.Signature.from(await h1.signTypedData(
    { name: dm[1], version: dm[2], chainId: dm[3], verifyingContract: dm[4] },
    { Permit: [{ name: "owner", type: "address" }, { name: "spender", type: "address" },
               { name: "value", type: "uint256" }, { name: "nonce", type: "uint256" },
               { name: "deadline", type: "uint256" }] },
    { owner: h1.address, spender: ex1.address, value: 5n * D, nonce: n0, deadline: dl }));
  await (await c11.permit(h1.address, ex1.address, 5n * D, dl, sig.v, sig.r, sig.s)).wait();
  check("permit で allowance が立つ", (await c11.allowance(h1.address, ex1.address)) === 5n * D);
  check("permit で nonce が進む", (await c11.nonces(h1.address)) === n0 + 1n);
  r = await rv(c11.permit(h1.address, ex1.address, 5n * D, dl, sig.v, sig.r, sig.s), "ERC2612InvalidSigner", I11);
  check("permit の再利用を拒否", r.ok, r.got);

  // --- cap 境界 ---
  const CAP = 300_000_000n * D;
  const cCap = await deploy(pool.address, [h1.address], [CAP], 0);
  check("genesis 合計 = cap でデプロイできる", (await cCap.totalSupply()) === CAP);
  r = await rv(cCap.connect(mi).mine(2026), "ERC20ExceededCap", cCap.interface);
  check("cap 到達後の mine は ERC20ExceededCap", r.ok, r.got);
  r = await rv(F.deploy(roles(), pool.address, [h1.address], [CAP + 1n], 0), "ERC20ExceededCap", I11);
  check("cap + 1 wei はデプロイ不可", r.ok, r.got);

  // --- constructor の不正引数 ---
  const ok = roles();
  const bad = (m) => ({ ...ok, ...m });
  for (const [label, rolesArg] of [["admin", bad({ admin: ethers.ZeroAddress })],
                                    ["freezer", bad({ freezer: ethers.ZeroAddress })],
                                    ["whitelistAdmin", bad({ whitelistAdmin: ethers.ZeroAddress })],
                                    ["miningAdmin", bad({ miningAdmin: ethers.ZeroAddress })],
                                    ["miner", bad({ miner: ethers.ZeroAddress })]]) {
    r = await rv(F.deploy(rolesArg, pool.address, [h1.address], [D], 0), "ZeroAddress", I11);
    check(`constructor: ${label} = 0x0 を拒否`, r.ok, r.got);
  }
  r = await rv(F.deploy(ok, ethers.ZeroAddress, [h1.address], [D], 0), "ZeroAddress", I11);
  check("constructor: poolAccount = 0x0 を拒否", r.ok, r.got);
  r = await rv(F.deploy(ok, pool.address, [], [], 0), "InvalidBatchSize", I11);
  check("constructor: genesisHolders 空を拒否", r.ok, r.got);
  r = await rv(F.deploy(ok, pool.address, [h1.address], [D, D], 0), "LengthMismatch", I11);
  check("constructor: 長さ不一致を拒否", r.ok, r.got);
  r = await rv(F.deploy(ok, pool.address, [ethers.ZeroAddress], [D], 0), "ZeroAddress", I11);
  check("constructor: genesisHolders に 0x0 を拒否", r.ok, r.got);
  r = await rv(F.deploy(ok, pool.address, [h1.address], [0n], 0), "AmountZero", I11);
  check("constructor: genesisAmounts に 0 を拒否", r.ok, r.got);

  const many = [], amts = [];
  for (let i = 0; i < 101; i++) {
    many.push(ethers.getCreateAddress({ from: dep.address, nonce: 900000 + i })); amts.push(D);
  }
  r = await rv(F.deploy(ok, pool.address, many, amts, 0), "InvalidBatchSize", I11);
  check("constructor: genesisHolders 101 件を拒否", r.ok, r.got);

  // --- genesis 100 件 / recorder 省略 ---
  const c100 = await F.deploy(ok, pool.address, many.slice(0, 100), amts.slice(0, 100), 0);
  await c100.waitForDeployment();
  const g100 = (await c100.deploymentTransaction().wait()).gasUsed;
  check("genesis 100 件でデプロイできる", (await c100.genesisSupply()) === 100n * D, `gas ${g100}`);
  const cNoRec = await F.deploy(bad({ recorder: ethers.ZeroAddress }), pool.address, [h1.address], [D], 0);
  await cNoRec.waitForDeployment();
  check("recorder = 0x0 なら RECORDER_ROLE の保持者なし",
        (await cNoRec.getRoleMemberCount(ethers.id("RECORDER_ROLE"))) === 0n);


  console.log("\n【12】ERC-1363 受信コントラクト / 一括送金 / データ記録");
  const solcjs = require("solc");
  const RECV_SRC = [
    "// SPDX-License-Identifier: MIT",
    "pragma solidity 0.8.36;",
    "interface IERC20Min { function balanceOf(address) external view returns (uint256); }",
    "interface IERC1363Receiver {",
    "  function onTransferReceived(address operator, address from, uint256 value, bytes calldata data)",
    "    external returns (bytes4);",
    "}",
    "contract TestReceiver is IERC1363Receiver {",
    "  address public token; address public lastOperator; address public lastFrom;",
    "  uint256 public lastValue; uint256 public calls; uint256 public balanceAtCallback;",
    "  bool public reject;",
    "  constructor(address t) { token = t; }",
    "  function setReject(bool v) external { reject = v; }",
    "  function onTransferReceived(address operator, address from, uint256 value, bytes calldata)",
    "    external returns (bytes4)",
    "  {",
    "    calls++; lastOperator = operator; lastFrom = from; lastValue = value;",
    "    balanceAtCallback = IERC20Min(token).balanceOf(address(this));",
    "    if (reject) return bytes4(0xdeadbeef);",
    "    return IERC1363Receiver.onTransferReceived.selector;",
    "  }",
    "}",
  ].join("\n");
  const rOut = JSON.parse(solcjs.compile(JSON.stringify({
    language: "Solidity",
    sources: { "TestReceiver.sol": { content: RECV_SRC } },
    settings: { optimizer: { enabled: false, runs: 200 }, evmVersion: "prague",
                outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
  })));
  const rFatal = (rOut.errors || []).filter(e => e.severity === "error");
  check("テスト用 ERC-1363 受信コントラクトをコンパイル", rFatal.length === 0,
        rFatal.map(e => e.message).join("; ").slice(0, 70));
  const RC = rOut.contracts["TestReceiver.sol"].TestReceiver;

  const c12 = await deploy(pool.address, [h1.address], [200_000_000n * D], 0);
  const I12 = c12.interface;
  const recv = await new ethers.ContractFactory(RC.abi, "0x" + RC.evm.bytecode.object, dep)
    .deploy(await c12.getAddress());
  await recv.waitForDeployment();
  const recvAddr = await recv.getAddress();

  const TAC = "transferAndCall(address,uint256)";
  await (await c12.connect(h1)[TAC](recvAddr, 10n * D)).wait();
  check("transferAndCall が適合受信者へ成功", (await c12.balanceOf(recvAddr)) === 10n * D);
  check("コールバックが 1 回発火", (await recv.calls()) === 1n);
  check("コールバックの from / value が正しい",
        (await recv.lastFrom()) === h1.address && (await recv.lastValue()) === 10n * D);
  check("コールバック時点で残高が確定済み（再入の余地なし）",
        (await recv.balanceAtCallback()) === 10n * D);

  await (await recv.setReject(true)).wait();
  r = await rv(c12.connect(h1)[TAC](recvAddr, D), "ERC1363InvalidReceiver", I12);
  check("誤セレクタを返す受信者を拒否", r.ok, r.got);
  await (await recv.setReject(false)).wait();

  await (await c12.connect(fr).freeze(recvAddr)).wait();
  r = await rv(c12.connect(h1)[TAC](recvAddr, D), "ERC20UserRestricted", I12);
  check("凍結した受信コントラクトへの transferAndCall を拒否", r.ok, r.got);
  await (await c12.connect(fr).unfreeze(recvAddr)).wait();

  const rcpts = [], amts100 = [];
  for (let i = 0; i < 100; i++) {
    rcpts.push(ethers.getCreateAddress({ from: dep.address, nonce: 700000 + i }));
    amts100.push(D);
  }
  const mtRc = await (await c12.connect(h1).multiTransfer(rcpts, amts100)).wait();
  check("multiTransfer 100 件が成功", (await c12.balanceOf(rcpts[99])) === D,
        `gas ${mtRc.gasUsed} / 1 件あたり約 ${Math.round(Number(mtRc.gasUsed) / 100)}`);

  const dataHash = ethers.id("SISC test payload");
  r = await rv(c12.connect(other).storeWeb3MakerAIData(dataHash), "AccessControlUnauthorizedAccount", I12);
  check("RECORDER 以外の storeWeb3MakerAIData を拒否", r.ok, r.got);
  r = await rv(c12.connect(rc).storeWeb3MakerAIData(ethers.ZeroHash), "InvalidNumber", I12);
  check("0 ハッシュを拒否", r.ok, r.got);
  const swRc = await (await c12.connect(rc).storeWeb3MakerAIData(dataHash)).wait();
  check("記録が保存される", (await c12.lastWeb3MakerAIData()) === dataHash);
  check("lastRecordedAt が設定される", (await c12.lastRecordedAt()) > 0n);
  check("Web3MakerAIDataStored が emit される", evs(swRc, I12, "Web3MakerAIDataStored").length === 1);

  console.log(`\n==== 合計 ${pass + fail} 件 / 成功 ${pass} / 失敗 ${fail} ====`);
  if (fail) process.exit(1);
}
main().catch(e => { console.error(e); process.exit(1); });
