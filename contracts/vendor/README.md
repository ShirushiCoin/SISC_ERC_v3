# Vendored third-party sources

## openzeppelin-community-contracts / ERC20Restricted.sol

| | |
|---|---|
| Upstream repository | https://github.com/OpenZeppelin/openzeppelin-community-contracts |
| Upstream path | `contracts/token/ERC20/extensions/ERC20Restricted.sol` |
| Pinned commit | `a12b30ca7affe3320777378eddf2d0cebae8c5b2` (2026-01-13, "Update IERC7943, ERC20uRWA and ERC20Restricted (#227)") |
| Local path | `contracts/vendor/openzeppelin-community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol` |
| SHA-256 | `9d3f175984c2b580550180cc03b940c592008fb03038f85a9e2765531e2bda7b` |
| License | MIT |
| Modifications | **None.** The file is byte-identical to the upstream commit. |

### Why it is vendored

`openzeppelin-community-contracts` is a separate library from `@openzeppelin/contracts`
and is **not covered by OpenZeppelin's own audits**. We therefore do not depend on a
floating package version: the exact commit is copied into this repository unchanged, so
the file is part of our own review, our own tests and the third-party audit scope, and it
cannot change under us.

`ERC20Restricted` replaces the private `_frozenAccounts` mapping of v3.0 and provides the
three-state model used by v3.1:

| `Restriction` | Meaning in SISC |
|---|---|
| `DEFAULT` | ordinary address |
| `BLOCKED` | frozen (`freeze()` / `unfreeze()`, FREEZER_ROLE) |
| `ALLOWED` | registered exchange address (`registerExchange()` / `unregisterExchange()`, WHITELIST_ROLE) |

`canTransact()` is left at the upstream default (a blocklist: only `BLOCKED` is stopped),
so `ALLOWED` is **not** a transfer gate for anyone else — it only marks the addresses that
`ShirushiCoin._setRestriction()` protects from being frozen.

### Re-verifying the file

```sh
curl -sSL https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-community-contracts/a12b30ca7affe3320777378eddf2d0cebae8c5b2/contracts/token/ERC20/extensions/ERC20Restricted.sol \
  | sha256sum
# 9d3f175984c2b580550180cc03b940c592008fb03038f85a9e2765531e2bda7b

sha256sum contracts/vendor/openzeppelin-community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol
```

### 日本語

`ERC20Restricted` は OpenZeppelin Community Contracts のファイルで、OpenZeppelin の正式監査の
対象外です。そのため npm のバージョン指定に依存せず、上記 commit の内容を**無改変**でこの
リポジトリに同梱し、自社レビュー・自社テスト・第三者監査のスコープに含めます。SHA-256 は上の
コマンドで再検証できます。
