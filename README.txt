*** SISC (ShirushiCoin) – Overview

SISC is an ERC-20 compatible token with role-based access control and a built-in mining schedule.
This branch (feature/v3.1) contains version 3.1. There is no burn path of any kind, so nothing
can reduce totalSupply, and no role can seize another account's balance: every transfer needs
either the holder's own call or an allowance the holder granted. (Ordinary transfers and approved
transferFrom do of course reduce the sender's balance - that is not what this says.)
Issuance is NOT a fixed on-chain schedule: see "Issuance limits" below.

See docs/v3.1-changes.md for the full v3.0 -> v3.1 difference and for the deployment arguments.

*** Key Features
- ERC-20 Core: name(), symbol(), decimals(), totalSupply(), transfer, approve, transferFrom, etc.
- Maximum supply of 300,000,000 coins, enforced by OpenZeppelin ERC20Capped (cap() / maxSupply()).
- Role-Based Access Control (AccessControl + AccessControlEnumerable):
 + DEFAULT_ADMIN_ROLE – manages the other roles. Fixed at deployment: it cannot be granted
   to another address, revoked or renounced.
 + FREEZER_ROLE – can freeze(address) / unfreeze(address) individual accounts.
 + WHITELIST_ROLE - can registerExchange(address). Registration is PERMANENT:
   there is no unregister function and no role can remove or change an entry.
 + MINING_ADMIN_ROLE – can setPoolAccount(address) / setMiningReward(year, reward).
 + MINER_ROLE – can call mine(year) to mint the yearly reward to the pool account.
 + RECORDER_ROLE – can call storeWeb3MakerAIData(bytes32).
- Address restrictions (OpenZeppelin Community Contracts ERC20Restricted, vendored unchanged
  at a pinned commit – see contracts/vendor/README.md):
 + BLOCKED = frozen. A frozen address can neither send nor receive.
 + ALLOWED = registered exchange address. It can never be frozen (SISC transition guard).
 + A frozen address cannot be registered, and unfreeze() cannot remove the ALLOWED state.
 + A frozen address also cannot SPEND an allowance: transferFrom reverts when the spender is
   frozen, so freezing an approval drainer actually stops it (see _spendAllowance).
 + The pool account is NOT auto-registered: it stays freezable, so an abusive mint can still
   be contained. setPoolAccount rejects only a frozen address. Registering the pool is an
   operational choice with a permanent cost - see docs/v3.1-security-notes.md S-5.
- Mining Schedule:
 + Fixed start year MINING_START_YEAR (2022, a constant), 90% of the previous year from the
   3rd year. The plan covers exactly 2022-2121; mine() reverts NoRewardForYear from 2122.
 + Reward calculation via getMiningReward(uint256 year)
 + mine(year) mints the reward to the pool account (set via setPoolAccount)
 + Enforces a minimum interval of 23 hours between mine calls. Note this is a sliding 23h,
   not a calendar day: up to 381 mints fit in 365 days, so a year can pay ~4.4% above the
   annual figure in the reward table.
 + Caps issuance so that totalSupply() never exceeds the cap
- Migration supply: minted once by the constructor to the given holders. There is no
  adminMint(), so the amounts cannot be corrected after deployment.
- EIP-2612 permit support (gasless approvals), ERC-1363 transferAndCall / approveAndCall.
- multiTransfer(address[] recipients, uint256[] amounts) - up to 100 recipients, no role
  required (it moves only the caller's own balance). ALL OR NOTHING: if any recipient is
  frozen the whole batch reverts, so pre-screen with canTransact()/isFrozen().
- Re-entrancy: mine() and multiTransfer() carry nonReentrant as defence in depth, but neither
  makes an external call so the guard cannot currently trip. The ERC-1363 callbacks are
  unguarded by design - they fire only after _update and _spendAllowance have settled.
- Requires an EVM with Cancun complete. The build uses both EIP-1153 (TSTORE/TLOAD, via
  ReentrancyGuardTransient) and EIP-5656 (MCOPY, emitted by solc at evmVersion cancun+), so
  dropping the reentrancy guard alone would NOT make it deployable on a pre-Cancun chain.

*** Removed in 3.1 (present in 3.0)
- burn / burnFrom (ERC20Burnable is not inherited)
- adminBurn (forced burn from any address)
- adminMint (discretionary mint)
- pause / unpause (ERC20Pausable is not inherited), and PAUSER_ROLE
- POOLER_ROLE (multiTransfer is permissionless)
- Any transfer of DEFAULT_ADMIN_ROLE

*** Issuance limits (read this together with the list above)
Removing adminMint() removed the function, not the capability. mine() is not a schedule that
the contract enforces:
- MINING_ADMIN_ROLE can set any year's reward to any value with setMiningReward(year, reward).
  There is no upper bound and no "decrease only" rule.
- MINING_ADMIN_ROLE can repoint the recipient at any time with setPoolAccount(address).
- MINER_ROLE supplies the year to mine(year) and may replay any past year every 23 hours.
MINING_ADMIN_ROLE + MINER_ROLE together can therefore mint the whole remaining cap headroom
to an address of their choosing, and DEFAULT_ADMIN_ROLE can grant itself both roles.
The only hard limit on issuance is the 300,000,000 cap (ERC20Capped).
See docs/v3.1-security-notes.md S-1 and S-2.

*** Repository Structure
.
├─ contracts/
│  ├─ ShirushiCoin.sol              # The main SISC (ShirushiCoin) Solidity contract
│  ├─ ShirushiCoin_flattened.sol    # Single-file version for verification (same bytecode)
│  └─ vendor/                       # Third-party sources, vendored unchanged (see its README)
├─ docs/
│  ├─ v3.1-changes.md               # v3.0 -> v3.1 difference, guard rules, deployment arguments
│  └─ v3.1-security-notes.md        # Self-review findings S-1..S-15. READ THIS.
├─ scripts/
│  ├─ build.sh                      # solc-input.json -> build/ShirushiCoin.json
│  ├─ sisc.config.example.ts        # copy to sisc.config.ts and fill in
│  ├─ deploy-sisc.ts                # checked deploy (named struct, pre-flight assertions)
│  └─ verify-deployment.ts          # post-deploy reconciliation, run this FIRST
├─ test/                            # Hardhat test suite (npm test)
├─ solc-input.json                  # solc standard-json input - the single build source
├─ COMPATIBILITY.md                 # v3.0-era solc/OpenZeppelin compatibility record
├─ package.json / tsconfig.json     # build + deploy tooling
├─ LICENSE / NOTICE                 # MIT, plus third-party copyright notices
└─ README.txt                       # This file

Not committed: build/ (generated), node_modules/, scripts/sisc.config.ts (your real addresses).
There is no artifacts/ or .deps/ directory - both were removed because they shipped stale
copies of sources that no longer match the build.

*** Build
solc 0.8.36, evmVersion prague, optimizer disabled (runs 200), OpenZeppelin Contracts 5.6.1.
solc-input.json is the single source of truth for the build; there is no committed artifacts/.
The flattened file compiles to the same bytecode (metadata excluded) as the modular sources.
For explorer verification submit the standard-json input (solc-input.json): the flattened file
produces the same runtime but a different metadata hash, so it can only be a partial match.

  npm install
  npm run build                 # solc-input.json -> build/ShirushiCoin.json
  npm test                      # 101 checks against that exact bytecode
  cp scripts/sisc.config.example.ts scripts/sisc.config.ts   # then fill it in
  npm run deploy                # dry run (pre-flight checks only)
  CONFIRM=DEPLOY RPC_URL=... PRIVATE_KEY=... npm run deploy
  CONTRACT=0x... RPC_URL=... npm run verify                  # run this FIRST after deploying

*** Roles & Typical Operations

Grant/Revoke a Role

grantRole(bytes32 role, address account)     # DEFAULT_ADMIN_ROLE; not for DEFAULT_ADMIN_ROLE itself
revokeRole(bytes32 role, address account)    # DEFAULT_ADMIN_ROLE; not for DEFAULT_ADMIN_ROLE itself
getRoleMembers(bytes32 role)                 # all current holders, on-chain

Role constants are public: DEFAULT_ADMIN_ROLE, FREEZER_ROLE, WHITELIST_ROLE, MINING_ADMIN_ROLE,
MINER_ROLE, RECORDER_ROLE.

Freeze/Unfreeze Accounts

freeze(address) / unfreeze(address)          # FREEZER_ROLE
   Both are idempotent: if the account is already in the requested state the call succeeds,
   changes nothing and emits no event. (A revert would abort a whole multi-address Safe batch
   during an incident - see docs/v3.1-security-notes.md S-10.)
   freeze on a whitelisted address reverts ExchangeAddressProtected; unfreeze on one is a
   silent no-op that does NOT remove the ALLOWED state.
isFrozen(address)

Exchange whitelist

registerExchange(address)                      # WHITELIST_ROLE (permanent, append-only)
isWhitelisted(address) -> bool          # view
registeredExchangeCount() -> uint256           # view
registeredExchangeAt(uint256) -> address       # view
getRegisteredExchanges() -> address[]          # view, whole registry in one call

Supply accounting

totalSupply()                                # the only figure for existing tokens
genesisSupply()                              # minted once by the constructor
legacyMinedSupply()                          # mined by PREVIOUS versions; not minted here
minedByThisContract()                        # totalMiningSupply - legacyMinedSupply
cap() / maxSupply()                          # 300,000,000 SISC
   Remaining issuance is cap() - totalSupply(). It is NOT cap() - totalMiningSupply(),
   because totalMiningSupply starts at legacyMinedSupply, which this contract never minted.

Mining

Check reward: getMiningReward(year)
Execute: mine(year)                          # MINER_ROLE, respects the 23h interval and the cap
Settings: setPoolAccount(address) / setMiningReward(year, reward)   # MINING_ADMIN_ROLE
   setPoolAccount rejects the zero address, the token contract itself, and any frozen address.
   It does NOT require the new pool to be whitelisted: the pool deliberately stays freezable, so
   that an abusive mint can still be contained. Registering the pool is an operational choice
   with a permanent cost - see docs/v3.1-security-notes.md S-5.
   Both setters are idempotent: re-applying the current value succeeds, changes nothing and
   emits no event. setPoolAccount still rejects a frozen address first, so a success always
   means the pool is currently usable.
getPoolAccount()

Events (Selected)

GenesisSupplyMinted(uint256 genesisSupply, uint256 legacyMinedSupply)
MineEvent(address miner, address pool, uint256 amount)
AccountFrozen(address account, bool isFrozen)
ExchangeRegistered(address indexed account, uint256 index)
   topic0 = 0x39d9349acc85a9d11b25b8e360e9a8837f3cd85681bb2094bf0aed1fc2d03e36
   Changed from v3.0's (address,bool). An indexer still filtering the old topic0 returns
   ZERO logs with no error, i.e. the whitelist silently looks empty. Give integrators this hash.
UserRestrictionsUpdated(address account, Restriction restriction)   # from ERC20Restricted
PoolAccountChanged(address oldAccount, address newAccount)
MiningRewardChanged(uint256 year, uint256 oldReward, uint256 newReward)
MultiTransferEvent(address sender, uint256 totalCount, uint256 totalAmount)
Web3MakerAIDataStored(address sender, bytes32 web3MakerAIData)
Standard ERC-20 events: Transfer, Approval
Access control events: RoleGranted, RoleRevoked, RoleAdminChanged

Security Notes

The contract is not upgradeable (no proxy): every change requires a redeployment.
DEFAULT_ADMIN_ROLE is fixed at deployment and only manages the other roles.
freeze / unfreeze has no expiry; registered exchange addresses can never be frozen, and
registration itself can never be undone - a wrong address is permanent.
Deploy ONLY with scripts/deploy-sisc.ts and reconcile with scripts/verify-deployment.ts:
the constructor struct does not protect against transposed addresses, and a wrong `admin`
is unrecoverable.
Assign roles carefully and prefer a multisig for each role holder.
Always test with a testnet and/or fork before mainnet deployments.

License

MIT (SPDX-License-Identifier: MIT).
