// Shirushi Coin ver 3.1

// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.6.1
pragma solidity 0.8.36;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { ERC1363 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol"; // ERC-1363 Transfer And Call
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Capped } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol"; // EIP-2612 ERC20 Permit
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

// OpenZeppelin Community Contracts (not part of the audited @openzeppelin/contracts package).
// Vendored unchanged at a pinned commit. See contracts/vendor/README.md.
import { ERC20Restricted } from "./vendor/openzeppelin-community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";

/**
 * @title ShirushiCoin
 * @notice ShirushiCoin is the ERC20-compliant token.
 *         It supports mining, address freezing, an exchange whitelist,
 *         transfer callbacks (ERC1363) and gasless approvals (ERC20Permit).
 * @dev Changes from v3.0 (see SISC v3.1 Component Map):
 *      - Removed: burn / burnFrom (ERC20Burnable), adminBurn, adminMint,
 *        pause / unpause (ERC20Pausable) and any transfer of DEFAULT_ADMIN_ROLE.
 *        No function can increase, decrease or move the balance of another account.
 *      - Issuance is `mine()` only. The migration supply is minted once in the constructor.
 *      - Freezing is implemented with {ERC20Restricted} (BLOCKED) instead of a private mapping.
 *      - The exchange whitelist is {ERC20Restricted} (ALLOWED) plus the SISC transition guard
 *        in {_setRestriction}: a registered address can never be frozen.
 *      - `maxSupply` is enforced by {ERC20Capped}; re-entrancy by {ReentrancyGuardTransient};
 *        role holders are enumerable via {AccessControlEnumerable}.
 *      - Roles: DEFAULT_ADMIN_ROLE is fixed at deployment. PAUSER_ROLE is gone (pause removed)
 *        and POOLER_ROLE is gone (`multiTransfer` moves only the caller's own balance).
 *        MINING_ADMIN_ROLE is new and separates the mining settings from the top-level admin.
 *        - FREEZER_ROLE: Permission to freeze / unfreeze
 *        - WHITELIST_ROLE: Permission to register / unregister exchange addresses
 *        - MINING_ADMIN_ROLE: Permission to set the pool account and the mining reward plan
 *        - MINER_ROLE: Permission to mine
 *        - RECORDER_ROLE: Permission to record
 */
contract ShirushiCoin is
    ERC20,
    ERC20Capped,
    ERC20Restricted,
    AccessControlEnumerable,
    ERC1363,
    ERC20Permit,
    ReentrancyGuardTransient
{
    // --- Constants ---
    /// @dev String of system version.
    string public constant VERSION = "3.10";

    /// @dev Number of decimal places for the coin. Complies with the ERC20 standard of 18 decimals.
    uint256 public constant DECIMAL_FACTOR = 1e18;

    /// @dev Maximum supply (in wei). Enforced by {ERC20Capped}: 300,000,000 coins.
    ///      Unchanged from v3.0 and not settable at deployment.
    uint256 public constant MAX_SUPPLY = 300_000_000 * DECIMAL_FACTOR;

    /// @dev Annual reduction rate of mining rewards (9 = 90%).
    ///      Example: if last year's reward was 10,000, this year's reward is 9,000.
    uint256 public constant MINING_REWARD_REDUCTION_PERCENT = 9;

    /// @dev The starting year of mining.
    uint256 public constant MINING_START_YEAR = 2022;

    /// @dev Initial mining reward (in whole coins, not wei).
    ///      The actual reward is `INITIAL_MINING_REWARD * DECIMAL_FACTOR`.
    uint256 public constant INITIAL_MINING_REWARD = 10_000;

    /// @dev Maximum number of entries accepted by the genesis mint and by `multiTransfer()`.
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @dev Minimum interval between mining operations (23 hours).
    uint256 private constant _MINING_MIN_INTERVAL = 23 hours;

    // --- Roles ---
    /// @dev Role that allows freezing/unfreezing accounts. Required for `freeze()`/`unfreeze()`.
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    /// @dev Role that allows registering/unregistering exchange addresses.
    ///      Required for `registerExchange()`/`unregisterExchange()`.
    bytes32 public constant WHITELIST_ROLE = keccak256("WHITELIST_ROLE");

    /// @dev Role that allows managing the mining settings.
    ///      Required for `setPoolAccount()`/`setMiningReward()`.
    bytes32 public constant MINING_ADMIN_ROLE = keccak256("MINING_ADMIN_ROLE");

    /// @dev Role that allows claiming mining rewards. Required for `mine()`.
    bytes32 public constant MINER_ROLE = keccak256("MINER_ROLE");

    /// @dev Role that allows recording Web3 Maker AI Data (e.g., AI-generated data).
    ///      Required for `storeWeb3MakerAIData()`.
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    // --- State Variables ---
    /// @dev The single holder of DEFAULT_ADMIN_ROLE. Fixed in the constructor: the role can
    ///      never be granted to another address, revoked or renounced.
    address public immutable fixedAdminAccount;

    /// @dev Total amount minted by the constructor (in wei). The migration supply of v3.1.
    uint256 public immutable genesisSupply;

    /// @dev Total mining supply (in wei). Starts at the amount already mined by the previous
    ///      versions (constructor argument) and grows with every `mine()`.
    uint256 public totalMiningSupply;

    /// @dev The pool account. Mining rewards are granted to this single account.
    address private poolAccount;

    /// @dev GMT timestamp (Unix time) of the last mining operation.
    uint256 public lastMinedAt;

    /// @dev Amount of the last mining reward (in wei).
    uint256 public lastMiningReward;

    /// @dev GMT timestamp (Unix time) of the last Web3 Maker AI data record.
    uint256 public lastRecordedAt;

    /// @dev The last recorded Web3 Maker AI data.
    bytes32 public lastWeb3MakerAIData;

    /// @dev Annual mining reward plan (in wei). `[year] => [reward]`.
    mapping(uint256 => uint256) private _miningRewardPlan;

    // --- Errors ---
    /// @dev The zero address was given where a real address is required.
    error ZeroAddress();

    /// @dev An amount of zero was given where a positive amount is required.
    error AmountZero();

    /// @dev A number (year, hash, ...) is out of the accepted range.
    error InvalidNumber();

    /// @dev `mine()` was called before the minimum interval elapsed.
    error CooldownPeriod();

    /// @dev A batch argument is empty or longer than {MAX_BATCH_SIZE}.
    error InvalidBatchSize();

    /// @dev Two array arguments have different lengths.
    error LengthMismatch();

    /// @dev The already-mined supply given to the constructor exceeds the genesis supply.
    error InvalidMiningSupply();

    /// @dev DEFAULT_ADMIN_ROLE is fixed at deployment: it cannot be granted, revoked or renounced.
    error AdminIsFixed();

    /// @dev A registered exchange address cannot be frozen (ALLOWED -> BLOCKED is forbidden).
    error ExchangeAddressProtected(address account);

    /// @dev A frozen address cannot be registered as an exchange (BLOCKED -> ALLOWED is forbidden).
    error FrozenAddressCannotBeRegistered(address account);

    /// @dev `unfreeze()` was called on an address that is not frozen.
    error NotFrozen(address account);

    /// @dev `unregisterExchange()` was called on an address that is not registered.
    error NotRegistered(address account);

    // --- Events ---
    /// @notice Emitted once by the constructor with the migration supply figures
    /// @param genesisSupply The total amount minted by the constructor (in wei)
    /// @param legacyMinedSupply The amount already mined by the previous versions (in wei)
    event GenesisSupplyMinted(uint256 genesisSupply, uint256 legacyMinedSupply);

    /// @notice Emitted when the pool account is changed
    /// @param oldAccount The previous pool account address
    /// @param newAccount The new pool account address
    event PoolAccountChanged(address indexed oldAccount, address indexed newAccount);

    /// @notice Emitted when an account is frozen or unfrozen
    /// @param account The account being frozen/unfrozen
    /// @param isFrozen True if the account is now frozen, false if unfrozen
    event AccountFrozen(address indexed account, bool isFrozen);

    /// @notice Emitted when an exchange address is registered or unregistered
    /// @param account The exchange address
    /// @param isRegistered True if the address is now registered, false if unregistered
    event ExchangeRegistered(address indexed account, bool isRegistered);

    /// @notice Emitted when the mining reward of a year is changed
    /// @param year The target year
    /// @param oldReward The previous reward for that year (in wei)
    /// @param newReward The new reward for that year (in wei)
    event MiningRewardChanged(uint256 indexed year, uint256 oldReward, uint256 newReward);

    /**
     * @notice Initial role holders of ShirushiCoin.
     * @dev Passed as a single struct so that the six addresses cannot be mixed up positionally.
     *      Every field except `recorder` must be a non-zero address.
     * @param admin The single, permanent holder of DEFAULT_ADMIN_ROLE (role management only).
     * @param freezer The initial holder of FREEZER_ROLE.
     * @param whitelistAdmin The initial holder of WHITELIST_ROLE.
     * @param miningAdmin The initial holder of MINING_ADMIN_ROLE.
     * @param miner The initial holder of MINER_ROLE.
     * @param recorder The initial holder of RECORDER_ROLE. The zero address means no holder.
     */
    struct InitialRoleHolders {
        address admin;
        address freezer;
        address whitelistAdmin;
        address miningAdmin;
        address miner;
        address recorder;
    }

    /**
    * @notice Initialization process for ShirushiCoin.
    * @dev This constructor performs the following operations:
    *      Sets the token name ("Shirushi Coin") and symbol ("SISC").
    *      Sets the maximum supply to {MAX_SUPPLY} (300 million coins) via {ERC20Capped}.
    *      Mints the migration supply once, to the given holders in the given amounts.
    *      Grants each role to the given initial holder. The deployer receives no role.
    *      Sets the pool account.
    *      Initializes the mining reward plan (reward schedule for 100 years).
    *      Notes:
    *      - There is no `adminMint()` in v3.1, so `genesisHolders` / `genesisAmounts` and
    *        `legacyMinedSupply` cannot be corrected after deployment. They must match the
    *        supply snapshot taken when mining on the previous version was stopped.
    *      - The sum of `genesisAmounts` is capped by {MAX_SUPPLY} ({ERC20Capped}).
    * @param roleHolders The initial holder of each role. See {InitialRoleHolders}.
    * @param poolAccount_ The account that receives mining rewards. Cannot be the zero address.
    * @param genesisHolders The accounts that receive the migration supply (1..{MAX_BATCH_SIZE}).
    * @param genesisAmounts The amount for each account (in wei, each > 0). Same length as `genesisHolders`.
    * @param legacyMinedSupply The amount already mined by the previous versions (in wei).
    *                          It is accounting only: it is not minted here and must not exceed
    *                          the sum of `genesisAmounts`.
    */
    constructor(
        InitialRoleHolders memory roleHolders,
        address poolAccount_,
        address[] memory genesisHolders,
        uint256[] memory genesisAmounts,
        uint256 legacyMinedSupply
    )
        ERC20("Shirushi Coin", "SISC")
        ERC20Capped(MAX_SUPPLY)
        ERC20Permit("Shirushi Coin")
    {
        // --- Argument Validation ---
        if (
            roleHolders.admin == address(0) ||
            roleHolders.freezer == address(0) ||
            roleHolders.whitelistAdmin == address(0) ||
            roleHolders.miningAdmin == address(0) ||
            roleHolders.miner == address(0) ||
            poolAccount_ == address(0)
        ) revert ZeroAddress();

        uint256 holderCount = genesisHolders.length;
        if (holderCount == 0 || holderCount > MAX_BATCH_SIZE) revert InvalidBatchSize();
        if (holderCount != genesisAmounts.length) revert LengthMismatch();

        // --- Role Assignment ---
        /// @dev DEFAULT_ADMIN_ROLE is pinned to `roleHolders.admin` for the life of the contract:
        ///      the `_grantRole` / `_revokeRole` overrides below reject every later change.
        ///      `fixedAdminAccount` is assigned before the first grant so that the override can
        ///      read it here.
        fixedAdminAccount = roleHolders.admin;
        _grantRole(DEFAULT_ADMIN_ROLE, roleHolders.admin);
        _grantRole(FREEZER_ROLE, roleHolders.freezer);
        _grantRole(WHITELIST_ROLE, roleHolders.whitelistAdmin);
        _grantRole(MINING_ADMIN_ROLE, roleHolders.miningAdmin);
        _grantRole(MINER_ROLE, roleHolders.miner);
        if (roleHolders.recorder != address(0)) {
            _grantRole(RECORDER_ROLE, roleHolders.recorder);
        }

        // --- Pool Account Setup ---
        poolAccount = poolAccount_;
        emit PoolAccountChanged(address(0), poolAccount_);

        // --- Genesis Mint (the only mint outside `mine()`) ---
        uint256 total = 0;
        for (uint256 i = 0; i < holderCount; i++) {
            address holder = genesisHolders[i];
            uint256 amount = genesisAmounts[i];
            if (holder == address(0)) revert ZeroAddress();
            if (amount == 0) revert AmountZero();

            total += amount;
            _mint(holder, amount);
        }
        genesisSupply = total;

        // --- Supply Accounting ---
        /// @dev Mining total already achieved by the previous versions. Accounting value only.
        if (legacyMinedSupply > total) revert InvalidMiningSupply();
        totalMiningSupply = legacyMinedSupply;

        emit GenesisSupplyMinted(total, legacyMinedSupply);

        // --- Initialize Mining Reward Plan ---
        /// @dev Initialize the mining reward plan:
        ///      - Starting year (MINING_START_YEAR) and the following year: `INITIAL_MINING_REWARD * DECIMAL_FACTOR`.
        ///      - From the 3rd year onward: reduced to `MINING_REWARD_REDUCTION_PERCENT` (90%) of the previous year.
        ///      - Configure the schedule for 100 years.
        uint256 miningReward = INITIAL_MINING_REWARD * DECIMAL_FACTOR;

        // Set rewards for the starting year and the following year
        _miningRewardPlan[MINING_START_YEAR] = miningReward;
        _miningRewardPlan[MINING_START_YEAR + 1] = miningReward;
        for (uint256 year = MINING_START_YEAR + 2; year < MINING_START_YEAR + 100; year++) {
            // Use the following to reduce by 90% each year:
            miningReward = (miningReward * MINING_REWARD_REDUCTION_PERCENT) / 10; // 90% = 9/10
            _miningRewardPlan[year] = miningReward;
        }
    }

    // ------------------------------------------------------------------
    // Freezing and the exchange whitelist (ERC20Restricted)
    // ------------------------------------------------------------------

    /**
    * @notice Freeze the specified account, restricting its token transfers.
    * @dev This function can only be called by an account holding the `FREEZER_ROLE`.
    *      Sets the {ERC20Restricted} state of the account to BLOCKED.
    *      A frozen account is restricted from the following operations:
    *      - `transfer()` / `transferFrom()` (if the sender or recipient is a frozen account)
    *      - receiving mining rewards (`mine()` reverts while the pool account is frozen)
    *      Notes:
    *      - A frozen account can still check its balance via `balanceOf()`, but cannot transfer coins.
    *      - `approve()` / `permit()` are not restricted; the resulting transfer is.
    *      - Freezing is applied per account and has no expiry.
    *      - Execution fails if the account is the zero address, or if the account is a
    *        registered exchange address ({ExchangeAddressProtected}).
    * @param account The account to freeze.
    */
    function freeze(address account) external onlyRole(FREEZER_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        // Reverts on ALLOWED -> BLOCKED. See `_setRestriction`.
        _blockUser(account);

        emit AccountFrozen(account, true);
    }

    /**
    * @notice Unfreeze the specified account, lifting transfer restrictions.
    * @dev This function can only be called by an account holding the `FREEZER_ROLE`.
    *      Resets the {ERC20Restricted} state of the account from BLOCKED to DEFAULT.
    *      Execution fails if the account is not frozen ({NotFrozen}). In particular, the
    *      FREEZER_ROLE cannot use this function to remove the ALLOWED state of a registered
    *      exchange address; only `unregisterExchange()` (WHITELIST_ROLE) can do that.
    * @param account The account to unfreeze.
    */
    function unfreeze(address account) external onlyRole(FREEZER_ROLE) {
        if (getRestriction(account) != Restriction.BLOCKED) revert NotFrozen(account);

        _resetUser(account);

        emit AccountFrozen(account, false);
    }

    /**
    * @notice Register an exchange address, making it immune to freezing.
    * @dev This function can only be called by an account holding the `WHITELIST_ROLE`.
    *      Sets the {ERC20Restricted} state of the account to ALLOWED. While registered,
    *      `freeze()` on this address always reverts.
    *      Execution fails if the account is the zero address, or if the account is currently
    *      frozen ({FrozenAddressCannotBeRegistered}) - registering it would silently unfreeze it.
    * @param account The exchange address to register.
    */
    function registerExchange(address account) external onlyRole(WHITELIST_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        // Reverts on BLOCKED -> ALLOWED. See `_setRestriction`.
        _allowUser(account);

        emit ExchangeRegistered(account, true);
    }

    /**
    * @notice Unregister an exchange address.
    * @dev This function can only be called by an account holding the `WHITELIST_ROLE`.
    *      Resets the {ERC20Restricted} state of the account from ALLOWED to DEFAULT. This is
    *      the only path that can remove the ALLOWED state.
    *      Execution fails if the account is not registered ({NotRegistered}).
    * @param account The exchange address to unregister.
    */
    function unregisterExchange(address account) external onlyRole(WHITELIST_ROLE) {
        if (getRestriction(account) != Restriction.ALLOWED) revert NotRegistered(account);

        _resetUser(account);

        emit ExchangeRegistered(account, false);
    }

    /// @notice Returns true if the account is frozen.
    /// @param account The account to check.
    function isFrozen(address account) external view returns (bool) {
        return getRestriction(account) == Restriction.BLOCKED;
    }

    /// @notice Returns true if the account is a registered exchange address.
    /// @param account The account to check.
    function isRegisteredExchange(address account) external view returns (bool) {
        return getRestriction(account) == Restriction.ALLOWED;
    }

    /**
     * @dev The single write path of the {ERC20Restricted} state, with the SISC transition guard.
     *      {ERC20Restricted} on its own allows any transition, so the following three are
     *      forbidden here:
     *      - ALLOWED -> BLOCKED: a registered exchange address can never be frozen.
     *      - BLOCKED -> ALLOWED: registering a frozen address would unfreeze it.
     *      - ALLOWED -> DEFAULT is not blocked here, but it is only reachable from
     *        `unregisterExchange()` (WHITELIST_ROLE): `unfreeze()` (FREEZER_ROLE) requires the
     *        current state to be BLOCKED, so "unfreeze then freeze" cannot strip ALLOWED.
     */
    function _setRestriction(address account, Restriction next) internal override {
        Restriction current = getRestriction(account);
        if (current == Restriction.ALLOWED && next == Restriction.BLOCKED) {
            revert ExchangeAddressProtected(account);
        }
        if (current == Restriction.BLOCKED && next == Restriction.ALLOWED) {
            revert FrozenAddressCannotBeRegistered(account);
        }
        super._setRestriction(account, next);
    }

    // ------------------------------------------------------------------
    // Mining
    // ------------------------------------------------------------------

    /// @notice Returns the pool account that receives mining rewards.
    function getPoolAccount() external view returns (address) {
        return poolAccount;
    }

    /**
     * @notice Update the pool account that receives mining rewards.
     * @dev This function can only be called by an account holding the `MINING_ADMIN_ROLE`
     *      (in v3.0 it was DEFAULT_ADMIN_ROLE).
     *      The pool account is the single address that will receive all mining rewards.
     *      Emits a {PoolAccountChanged} event on success.
     * @param account The new pool account address. Cannot be the zero address.
     */
    function setPoolAccount(address account) external onlyRole(MINING_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        address old = poolAccount;
        poolAccount = account;
        emit PoolAccountChanged(old, account);
    }

    /**
    * @dev Retrieve the mining reward for a given year.
    *      The reward is returned in wei. For invalid years
    *      (before {MINING_START_YEAR}), the call reverts.
    * @param year The year for which to retrieve the reward (e.g., 2024).
    * @return reward The reward amount in wei (0 for years outside the plan).
    */
    function getMiningReward(uint256 year) public view returns (uint256) {
        // Undefined year
        if (year < MINING_START_YEAR || year > 9999) revert InvalidNumber();

        // Return the mining reward in wei
        return _miningRewardPlan[year];
    }

    /**
    * @notice Set the mining reward for a specific year.
    * @dev This function can only be executed by an account with the `MINING_ADMIN_ROLE`
    *      (in v3.0 it was DEFAULT_ADMIN_ROLE).
    *      Notes:
    *      - `year`: The target year (must be greater than or equal to `MINING_START_YEAR`).
    *      - `reward`: The mining reward for that year (in wei, zero is allowed).
    *      - Existing reward settings will be overwritten.
    *      - Example: (2025, 100 SISC) -> Sets the reward for 2025 to 100 SISC.
    *      - Emits a {MiningRewardChanged} event on success.
    * @param year The year to set (>= MINING_START_YEAR).
    * @param reward The reward amount in wei.
    */
    function setMiningReward(uint256 year, uint256 reward) external onlyRole(MINING_ADMIN_ROLE) {
        // Validate year
        if (year < MINING_START_YEAR || year > 9999) revert InvalidNumber();

        // Set new reward
        uint256 old = _miningRewardPlan[year];
        _miningRewardPlan[year] = reward;

        emit MiningRewardChanged(year, old, reward);
    }

    /**
    * @notice Mining event
    * @param miner   The account that executed the mining (msg.sender)
    * @param pool    The pool account that received the reward
    * @param amount  The amount of coins mined
    */
    event MineEvent(address indexed miner, address indexed pool, uint256 amount);

    /**
    * @notice Executes mining and grants rewards to the pool account
    * @dev This function can only be executed by an account with the MINER_ROLE.
    *      Notes:
    *      - Execution must pass 23 hours since the last execution
    *      - The mining reward for the target year will be applied
    *      - Total supply does not exceed {MAX_SUPPLY} (enforced by {ERC20Capped})
    *      - The pool account must not be the zero address
    *      - Mining rewards are minted directly to the pool account
    *      - After execution, lastMinedAt and lastMiningReward are updated
    *      - Emits the event: MineEvent(msg.sender, poolAccount, miningReward)
    *      - State variables are updated early to prevent reentrancy attacks
    *      - Interval check is performed first to prevent front-running
    * @param year The year whose reward is minted.
    */
    function mine(uint256 year) external onlyRole(MINER_ROLE) nonReentrant {
        // Input Validation (Prioritize interval checks)
        uint256 timestamp = block.timestamp;
        if (timestamp - lastMinedAt < _MINING_MIN_INTERVAL) revert CooldownPeriod();

        // Reward-related validation
        uint256 miningReward = getMiningReward(year);
        if (miningReward == 0) revert InvalidNumber();

        // Pool Account Validation
        address pool = poolAccount;
        if (pool == address(0)) revert ZeroAddress();

        // Early State Variable Updates (Checks-Effects-Interactions Pattern)
        lastMinedAt = timestamp;
        lastMiningReward = miningReward;

        // Add mining reward to the total mining supply
        totalMiningSupply = totalMiningSupply + miningReward;

        // Execute mining. {ERC20Capped} reverts if MAX_SUPPLY would be exceeded.
        _mint(pool, miningReward);

        // Event trigger
        emit MineEvent(msg.sender, pool, miningReward);
    }

    // ------------------------------------------------------------------
    // Web3 Maker AI data
    // ------------------------------------------------------------------

    /// @notice Web3 Maker AI Data recording event
    /// @dev Persists the recorder's account and the data hash on the blockchain
    /// @param sender The account that executed the recording (indexed)
    /// @param web3MakerAIData The recorded data hash (bytes32)
    event Web3MakerAIDataStored(
        address indexed sender,
        bytes32 indexed web3MakerAIData
    );

    /// @notice Records the hash of Web3 Maker AI data
    /// @dev Can only be executed by accounts with the recorder role.
    ///      Stores the timestamp and the Web3 Maker AI data hash in storage and emits an event.
    /// @param web3MakerAIData The hash of the data to be recorded (bytes32)
    function storeWeb3MakerAIData(bytes32 web3MakerAIData) external onlyRole(RECORDER_ROLE) {
        // Zero hash validation
        if (web3MakerAIData == bytes32(0)) revert InvalidNumber();

        // Emit event (executed before updating storage)
        emit Web3MakerAIDataStored(msg.sender, web3MakerAIData);

        // Update storage
        lastRecordedAt = block.timestamp;
        lastWeb3MakerAIData = web3MakerAIData;
    }

    // ------------------------------------------------------------------
    // Batch transfer
    // ------------------------------------------------------------------

    /// @notice Bulk transfer event
    /// @dev Records the sender, number of recipients, and total amount transferred
    /// @param sender The account executing the transfer (indexed)
    /// @param totalCount Number of recipient accounts
    /// @param totalAmount Total amount transferred (in the smallest unit of the token)
    event MultiTransferEvent(
        address indexed sender,
        uint256 totalCount,
        uint256 totalAmount
    );

    /**
    * @notice Executes a batch transfer to multiple recipients.
    * @dev
    * - Supports 1 to {MAX_BATCH_SIZE} recipients.
    * - Moves only the caller's own balance, so no role is required (POOLER_ROLE was removed in v3.1).
    * - The function reverts if the caller or any recipient is frozen (checked in `_update`).
    * - Prevents reentrancy attacks via {ReentrancyGuardTransient}.
    * @param recipients Array of recipient addresses (1..{MAX_BATCH_SIZE}).
    * @param amounts Array of amounts to send, same length as `recipients`.
    * @custom:gas-cost Approximately 50,000 gas per recipient (estimated).
    */
    function multiTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    )
        external
        nonReentrant
    {
        // Array length checks to prevent DoS attacks
        uint256 count = recipients.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert InvalidBatchSize();
        if (count != amounts.length) revert LengthMismatch();

        uint256 totalAmount = 0;
        address sender = _msgSender();

        // Execute transfers. `_transfer` checks the balance, the zero address
        // and the restriction state of both sides.
        for (uint256 i = 0; i < count; i++) {
            totalAmount += amounts[i];
            _transfer(sender, recipients[i], amounts[i]);
        }

        // Emit event with actual number of recipients and total amount
        emit MultiTransferEvent(sender, count, totalAmount);
    }

    // ------------------------------------------------------------------
    // Role management: DEFAULT_ADMIN_ROLE is fixed at deployment
    // ------------------------------------------------------------------

    /**
     * @dev DEFAULT_ADMIN_ROLE can never be granted to any address other than
     *      {fixedAdminAccount}. Every other role behaves as in {AccessControl}.
     */
    function _grantRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerable)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE && account != fixedAdminAccount) revert AdminIsFixed();
        return super._grantRole(role, account);
    }

    /**
     * @dev DEFAULT_ADMIN_ROLE can never be revoked or renounced (`renounceRole` calls this).
     *      Every other role behaves as in {AccessControl}.
     */
    function _revokeRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerable)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE) revert AdminIsFixed();
        return super._revokeRole(role, account);
    }

    // ------------------------------------------------------------------
    // Overrides required by Solidity
    // ------------------------------------------------------------------

    /// @notice Returns the maximum supply (in wei). Alias of {ERC20Capped-cap}.
    /// @dev Kept for compatibility with the v3.0 `maxSupply` getter.
    function maxSupply() external view returns (uint256) {
        return cap();
    }

    // This function is an override required by Solidity.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped, ERC20Restricted)
    {
        super._update(from, to, value);
    }

    // This function is an override required by Solidity.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerable, ERC1363)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
