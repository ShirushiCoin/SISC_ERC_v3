# Solidity コンパイラ互換性調査レポート

**調査日**: 2026-08-31
**対象**: `contracts/ShirushiCoin.sol`
**ブランチ**: `feature/20260831`

---

## 1. 調査サマリ

調査時点で最新の **solc 0.8.36** および **OpenZeppelin Contracts 5.6.1** を実際にインストールし、
本コントラクトをコンパイルして検証した。

結果、**import パス 1 行が原因で最新の OpenZeppelin ではコンパイルできない**状態であることが判明した。
コントラクト本体のコードそのものは最新コンパイラに完全に対応しており、警告は 1 件も発生しない。

本レポートの指摘はすべて本ブランチで対応済みである（[4. 適用した修正](#4-適用した修正)を参照）。
併せて、コンパイラ設定の固定・`artifacts/` の再生成・検証用 Standard JSON Input の追加まで完了している。

### バージョン対照表

| 項目 | 修正前 | 修正後 |
|---|---|---|
| solc | 0.8.30（`pragma ^0.8.30`）| **0.8.36**（`pragma 0.8.36` に固定）|
| OpenZeppelin Contracts | 5.4.0 と表記（実体は一部 4.9.0 混在）| **5.6.1**（`.deps/` を全面同期）|
| evmVersion | 未指定（コンパイラ既定に依存）| **`prague` を明示指定** |
| `artifacts/` | solc 0.8.30 / 修正前ソースの出力 | solc 0.8.36 / 修正後ソースで再生成 |

> 参考: evmVersion を無指定にした場合のコンパイラ既定値は solc 0.8.30 が `prague`、solc 0.8.36 が `osaka` であり、
> バージョン間で変化する。本リポジトリではこれに依存しないよう `prague` を明示的に固定した（3 章・4-4 参照）。

---

## 2. 【重大】`security/ReentrancyGuard.sol` が最新 OpenZeppelin に存在しない

### 現象

修正前の [`contracts/ShirushiCoin.sol`](contracts/ShirushiCoin.sol) 13 行目は以下だった。

```solidity
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
```

OpenZeppelin Contracts **v5.0 で `security/` ディレクトリは廃止**され、
`ReentrancyGuard` は `utils/` 配下へ移動している。
このため実際の `@openzeppelin/contracts@5.6.1` に対してコンパイルすると失敗する。

```
[error] 6275 ParserError: Source "@openzeppelin/contracts/security/ReentrancyGuard.sol" not found:
        File not found: @openzeppelin/contracts/security/ReentrancyGuard.sol
  --> contracts/ShirushiCoin.sol:13:1:
   |
13 | import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
```

### これまでコンパイルが通っていた理由

Remix の依存キャッシュ `.deps/` が、**この 1 ファイルだけ OpenZeppelin v4.9.0 版を
フォールバックで取得していた**ため、エラーにならずに通過していた。

| `.deps/` 内のファイル | ヘッダに記載された OZ バージョン |
|---|---|
| `@openzeppelin/contracts/security/ReentrancyGuard.sol` | **v4.9.0**（`pragma ^0.8.0`）|
| `@openzeppelin/contracts/utils/ReentrancyGuard.sol` | v5.1.0（存在するが未使用だった）|
| `@openzeppelin/contracts/token/ERC20/ERC20.sol` ほか全ファイル | v5.4.0 |

`artifacts/build-info/` のコンパイル入力を確認したところ、
実際に `@openzeppelin/contracts/security/ReentrancyGuard.sol` がソースとして渡されている。

### 影響

- ソースコード 4 行目の `// Compatible with OpenZeppelin Contracts ^5.4.0` という記述が実態と異なっていた。
- Remix 以外の環境（Hardhat / Foundry / npm 経由の OpenZeppelin）では**ビルド不能**だった。
- デプロイ済みバイトコードは **OZ v4.9 と v5.4 が混在**した状態でビルドされている。
  （`ReentrancyGuard` の実装は v4.9 / v5 でいずれも `uint256` 1 スロットのセンチネル方式であり、
  ロジック上の脆弱性はないが、依存バージョンの一貫性が失われていた。）

---

## 3. 【要注意】evmVersion のデフォルトが変更されている

solc のデフォルト evmVersion がバージョン間で変化している。実測値は以下のとおり。

| コンパイラ | evmVersion 無指定時のデフォルト |
|---|---|
| 0.8.30（既存 `artifacts/` のビルドに使用）| `prague` |
| 0.8.36（最新）| `osaka` |

### 対応が必要なケース

- **エクスプローラでのソース検証（Verify）**: バイトコードが完全一致しないと検証に失敗するため、
  デプロイ時と同じ evmVersion を明示指定する必要がある。
- **Osaka (Fusaka) 未対応のチェーン / L2 へのデプロイ**: 新しいオペコードが混入すると
  デプロイまたは実行が失敗する。`prague` 等を明示指定すること。

なお本コントラクトは `evmVersion` に `osaka` / `prague` のいずれを指定してもコンパイル可能であることを確認済み。

---

## 4. 適用した修正

本ブランチ `feature/20260831` にて以下を適用した。

### 4-1. import パスの修正（必須）

```diff
- import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
+ import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
```

この修正により、ソース 4 行目のヘッダコメントが実態と一致するようになった
（コメントは後述 4-5 で `// Compatible with OpenZeppelin Contracts ^5.6.1` に更新）。

### 4-2. バージョン定数の更新

```diff
- // Shirushi Coin ver 2.0
+ // Shirushi Coin ver 3.0

-     string public constant VERSION = "2.00";
+     string public constant VERSION = "3.00";
```

### 4-3. `.deps/` の OpenZeppelin 5.6.1 への全面同期

まず `.deps/npm/@openzeppelin/contracts/security/ReentrancyGuard.sol`（OZ v4.9.0）を削除した。
import 修正後は参照されないファイルであり、残置すると再び v4.9 と v5.x の混在を招くためである。

さらに調査を進めたところ、`.deps/` には他にも OZ v4 系の遺物が残っていた。

| ファイル | ヘッダの OZ バージョン | 対応 |
|---|---|---|
| `access/AccessControlEnumerable.sol` | **v4.5.0** | 削除（OZ 5.x では `access/extensions/` へ移動しており、本コントラクトからは未参照）|
| `access/IAccessControlEnumerable.sol` | **v4.4.1** | 同上 |

そのうえで `.deps/npm/@openzeppelin/contracts/` 配下の全 `.sol`（38 ファイル）を
npm の `@openzeppelin/contracts@5.6.1` の内容で上書き同期した。
また OZ 5.6.1 の `utils/Strings.sol` が新たに依存する `utils/Bytes.sol` を追加取得している。

これにより `.deps/` は **OZ 5.6.1 単一バージョン**となり、混在が解消された。

### 4-4. evmVersion の明示指定と `artifacts/` の再生成

`artifacts/` は solc 0.8.30 かつ import 修正前のソースでビルドされたものが残っていたため、
以下の設定で全面的に再生成した。

| 設定 | 値 |
|---|---|
| コンパイラ | `0.8.36+commit.8a079791` |
| evmVersion | **`prague`（明示指定）** |
| optimizer | 無効 / runs 200（従来設定を踏襲）|
| 依存 | `.deps/`（OZ 5.6.1）|

evmVersion を明示指定した理由は 3 章のとおりで、無指定にすると solc のバージョン更新に伴って
`prague` → `osaka` と勝手に切り替わり、デプロイ済みバイトコードとの一致が崩れるためである。

再生成の結果は以下のとおり。

- `artifacts/*.json` / `artifacts/*_metadata.json`: 36 コントラクト分を更新（`Bytes` が新規追加）
- `artifacts/build-info/`: 旧 2 ファイルを削除し、`803c1398f3dd5104b7de997441789ab6.json` を生成
  - 削除した `c2d8332cb19dcc4d08b70c54d5ea9ab8.json` は、既にリポジトリに存在しない
    `contracts/ShirushiCoin_flattened.sol` のビルド結果であり、参照先を失った孤立ファイルだった

**Remix で再コンパイルする場合は、Solidity Compiler タブで以下を必ず設定すること。**
設定が異なると生成されるバイトコードが変わり、エクスプローラでの検証に失敗する。

- COMPILER: `0.8.36+commit.8a079791`
- EVM VERSION: `prague`
- Enable optimization: **オフ**（runs 200）

### 4-5. pragma のバージョン固定

```diff
- // Compatible with OpenZeppelin Contracts ^5.4.0
- pragma solidity ^0.8.30;
+ // Compatible with OpenZeppelin Contracts ^5.6.1
+ pragma solidity 0.8.36;
```

`^0.8.30` のままでは 0.8.30〜0.8.x のどのバージョンでビルドされたかがソースから確定できず、
エクスプローラでの Verify 時にコンパイラバージョンを取り違える余地が残る。
トークンコントラクトでは固定運用が一般的であるため、`0.8.36` に固定した。

### 4-6. 検証用 Standard JSON Input の追加

リポジトリ直下に [`solc-input.json`](solc-input.json) を追加した。
コンパイラ設定（`evmVersion: "prague"`、optimizer 無効 / runs 200）と全 36 ソースを
1 ファイルに固定した Standard JSON Input であり、次の用途にそのまま使える。

- Etherscan 等での **Standard-Json-Input 方式のソース検証**
- `solc --standard-json < solc-input.json` による再現ビルド

### 修正後の検証結果

solc 0.8.36 + OpenZeppelin Contracts 5.6.1 でコンパイル成功。

```
solc: 0.8.36+commit.8a079791
COMPILED OK. evmVersion = prague  | compiler = 0.8.36+commit.8a079791
COMPILED OK. evmVersion = osaka   | compiler = 0.8.36+commit.8a079791
COMPILED OK. evmVersion = cancun  | compiler = 0.8.36+commit.8a079791
ShirushiCoin.sol 由来の警告: 0 件
```

さらに `solc-input.json` から独立にコンパイルし、`artifacts/ShirushiCoin.json` の
バイトコードと突き合わせて再現性を確認した。

```
solc-input.json settings: optimizer={"enabled":false,"runs":200} evmVersion=prague sources=36
bytecode 一致        : OK (完全一致)
deployedBytecode 一致 : OK
```

---

## 5. コントラクト本体は最新コンパイラに対応済み

solc 0.8.31 では、次期メジャーリリース 0.9.0 に向けて第 1 弾の非推奨化が行われたが、
**本コントラクトはこれらの機能を一切使用していない**。

| 0.8.31 で非推奨化された機能 | 本コントラクトでの使用 |
|---|---|
| ABI coder v1 | 未使用（`pragma abicoder` 指定なし → v2）|
| `virtual` modifier | 未使用 |
| `address.send()` / `address.transfer()` | 未使用 |
| contract 型変数の比較 | 未使用 |
| `memory-safe-assembly` 特殊コメント | 未使用 |

また solc 0.8.35 で追加された「将来キーワード化される識別子」の警告
（`at`, `error`, `layout`, `leave`, `super`, `transient`, `this`）についても、
`contracts/ShirushiCoin.sol` 由来の警告は **0 件**である。

### 唯一の警告は依存ライブラリ側（対応不要）

```
[warning] 6335 Warning: "error" will be promoted to keyword in the future and
                will not be allowed as an identifier anymore.
  --> @openzeppelin/contracts/utils/cryptography/ECDSA.sol:125:29
```

OpenZeppelin 5.6.1 側が `error` を識別子として使用していることによる警告が 5 件発生する。
**警告のみでコンパイルは正常に完了する**ため、現時点での対応は不要。
将来 Solidity 0.9.0 へ移行する際には、対応済みの OpenZeppelin へのアップデートが必要になる。

---

## 6. 今後の推奨事項

### 対応済み

| # | 項目 | 優先度 | 状態 |
|---|---|---|---|
| 1 | import パス修正 | **必須** | 対応済み（4-1）|
| 2 | evmVersion の明示指定 | **高** | 対応済み。`prague` に固定（4-4）|
| 3 | pragma のバージョン固定 | 中 | 対応済み。`pragma solidity 0.8.36;`（4-5）|
| 4 | `artifacts/` の再生成 | 中 | 対応済み。solc 0.8.36 / prague で全面再生成（4-4）|
| 5 | 依存バージョンの統一 | 中 | 対応済み。`.deps/` を OZ 5.6.1 に統一（4-3）|

### 未対応（今後の検討事項）

| # | 項目 | 優先度 | 内容 |
|---|---|---|---|
| 6 | `ReentrancyGuardTransient` への移行検討 | 低 | OpenZeppelin 5.1+ が提供。EIP-1153（transient storage）を利用し<br>`nonReentrant` のガスコストを大幅に削減できる。Cancun 以降のチェーンが必要。<br>ストレージレイアウトが変わるため、新規デプロイ時に検討すること。 |
| 7 | 既存デプロイ済みコントラクトの扱い | — | 既にデプロイ済みのバイトコードは **solc 0.8.30 / OZ v4.9 混在 / 修正前ソース**でビルドされたものであり、<br>本ブランチのソースとはバイトコードが一致しない。<br>本ブランチの成果物は**新規デプロイ向け**であり、既存デプロイの Verify には使えない。 |
| 8 | `scripts/` の整理 | 低 | `scripts/` 配下は Remix の雛形（`Storage` コントラクトをデプロイする内容）のままで、<br>本コントラクトとは無関係。README が記載する `src/` `abi/` `.env.example` も未整備。 |

---

## 7. 検証環境

| 項目 | 値 |
|---|---|
| solc | `0.8.36+commit.8a079791.Emscripten.clang`（npm `solc@latest`）|
| OpenZeppelin Contracts | `5.6.1`（npm `@openzeppelin/contracts@latest`）|
| evmVersion | `prague`（明示指定）。`osaka` / `cancun` でもコンパイル可能なことを確認済み |
| optimizer | 無効 / runs 200（既存 `artifacts/` の設定に合わせた）|
| 依存解決 | 調査時は npm 版 OpenZeppelin のみを参照。<br>`artifacts/` の再生成時は同期後の `.deps/`（OZ 5.6.1）を参照 |

---

## 参考リンク

- [Solidity 0.8.31 Release Announcement](https://www.soliditylang.org/blog/2025/12/03/solidity-0.8.31-release-announcement/)
- [Solidity 0.8.32 / 0.8.33 Release Announcement](https://www.soliditylang.org/blog/2025/12/18/solidity-0.8.32-0.8.33-release-announcement/)
- [Solidity Changelog](https://github.com/ethereum/solidity/blob/develop/Changelog.md)
- [Solidity Blog: Releases](https://www.soliditylang.org/blog/category/releases/)
- [OpenZeppelin Contracts 5.0 Migration Guide](https://docs.openzeppelin.com/contracts/5.x/upgrades)
