*** SISC (ShirushiCoin) – Overview

SISC is an ERC-20 compatible token with role-based access control and a built-in mining schedule.
This branch (feature/v3.1) contains version 3.1, in which no function can increase, decrease or
move the balance of another account: issuance is the fixed mining schedule only.

See docs/v3.1-changes.md for the full v3.0 -> v3.1 difference and for the deployment arguments.

*** Key Features
- ERC-20 Core: name(), symbol(), decimals(), totalSupply(), transfer, approve, transferFrom, etc.
- Maximum supply of 300,000,000 coins, enforced by OpenZeppelin ERC20Capped (cap() / maxSupply()).
- Role-Based Access Control (AccessControl + AccessControlEnumerable):
 + DEFAULT_ADMIN_ROLE – manages the other roles. Fixed at deployment: it cannot be granted
   to another address, revoked or renounced.
 + FREEZER_ROLE – can freeze(address) / unfreeze(address) individual accounts.
 + WHITELIST_ROLE – can registerExchange(address) / unregisterExchange(address).
 + MINING_ADMIN_ROLE – can setPoolAccount(address) / setMiningReward(year, reward).
 + MINER_ROLE – can call mine(year) to mint the yearly reward to the pool account.
 + RECORDER_ROLE – can call storeWeb3MakerAIData(bytes32).
- Address restrictions (OpenZeppelin Community Contracts ERC20Restricted, vendored unchanged
  at a pinned commit – see contracts/vendor/README.md):
 + BLOCKED = frozen. A frozen address can neither send nor receive.
 + ALLOWED = registered exchange address. It can never be frozen (SISC transition guard).
 + A frozen address cannot be registered, and unfreeze() cannot remove the ALLOWED state.
- Mining Schedule:
 + Configurable start year MINING_START_YEAR (2022), 90% of the previous year from the 3rd year.
 + Reward calculation via getMiningReward(uint256 year)
 + mine(year) mints the reward to the pool account (set via setPoolAccount)
 + Enforces a minimum interval of 23 hours between mine calls
 + Caps issuance so that totalSupply() never exceeds the cap
- Migration supply: minted once by the constructor to the given holders. There is no
  discretionary mint, so the amounts cannot be corrected after deployment.
- EIP-2612 permit support (gasless approvals), ERC-1363 transferAndCall / approveAndCall.
- multiTransfer(address[] recipients, uint256[] amounts) – up to 100 recipients, no role
  required (it moves only the caller's own balance).
- Re-entrancy protection via ReentrancyGuardTransient (requires evmVersion cancun or later).

*** Removed in 3.1 (present in 3.0)
- burn / burnFrom (ERC20Burnable is not inherited)
- adminBurn (forced burn from any address)
- adminMint (discretionary mint)
- pause / unpause (ERC20Pausable is not inherited), and PAUSER_ROLE
- POOLER_ROLE (multiTransfer is permissionless)
- Any transfer of DEFAULT_ADMIN_ROLE

*** Repository Structure
.
├─ contracts/
│  ├─ ShirushiCoin.sol              # The main SISC (ShirushiCoin) Solidity contract
│  ├─ ShirushiCoin_flattened.sol    # Single-file version for verification (same bytecode)
│  └─ vendor/                       # Third-party sources, vendored unchanged (see its README)
├─ docs/
│  └─ v3.1-changes.md               # v3.0 -> v3.1 difference, guard rules, deployment arguments
├─ scripts/                         # Remix deployment helpers
├─ solc-input.json                  # solc standard-json input (0.8.36, evmVersion prague)
└─ README.txt                       # This file

*** Build
solc 0.8.36, evmVersion prague, optimizer disabled (runs 200), OpenZeppelin Contracts 5.6.1.
The flattened file compiles to the same bytecode (metadata excluded) as the modular sources.

*** Roles & Typical Operations

Grant/Revoke a Role

grantRole(bytes32 role, address account)     # DEFAULT_ADMIN_ROLE; not for DEFAULT_ADMIN_ROLE itself
revokeRole(bytes32 role, address account)    # DEFAULT_ADMIN_ROLE; not for DEFAULT_ADMIN_ROLE itself
getRoleMembers(bytes32 role)                 # all current holders, on-chain

Role constants are public: DEFAULT_ADMIN_ROLE, FREEZER_ROLE, WHITELIST_ROLE, MINING_ADMIN_ROLE,
MINER_ROLE, RECORDER_ROLE.

Freeze/Unfreeze Accounts

freeze(address) / unfreeze(address)          # FREEZER_ROLE
isFrozen(address)

Exchange whitelist

registerExchange(address) / unregisterExchange(address)   # WHITELIST_ROLE
isRegisteredExchange(address)

Mining

Check reward: getMiningReward(year)
Execute: mine(year)                          # MINER_ROLE, respects the 23h interval and the cap
Settings: setPoolAccount(address) / setMiningReward(year, reward)   # MINING_ADMIN_ROLE
getPoolAccount()

Events (Selected)

GenesisSupplyMinted(uint256 genesisSupply, uint256 legacyMinedSupply)
MineEvent(address miner, address pool, uint256 amount)
AccountFrozen(address account, bool isFrozen)
ExchangeRegistered(address account, bool isRegistered)
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
freeze / unfreeze has no expiry; registered exchange addresses can never be frozen.
Assign roles carefully and prefer a multisig for each role holder.
Always test with a testnet and/or fork before mainnet deployments.

License

MIT (SPDX-License-Identifier: MIT).
