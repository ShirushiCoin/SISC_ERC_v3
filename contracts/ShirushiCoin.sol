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
import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";

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
 *        There is no burn path of any kind, so nothing can reduce `totalSupply`, and no role
 *        can seize another account's balance: every transfer needs either the holder's own
 *        call or an allowance the holder granted. (Ordinary transfers and approved
 *        `transferFrom` do of course reduce the sender's balance - that is not what this says.)
 *      - Issuance goes through `mine()` only, plus the one-time migration supply minted in the
 *        constructor. Note that `mine()` is NOT a schedule enforced on-chain:
 *        MINING_ADMIN_ROLE can raise any year's reward with {setMiningReward} (no upper bound)
 *        and repoint the recipient with {setPoolAccount}, while MINER_ROLE chooses the `year`
 *        passed to {mine} and may replay any past year every 23 hours. Those two roles together
 *        can therefore mint the entire remaining cap headroom to an address of their choosing,
 *        and DEFAULT_ADMIN_ROLE can grant itself both. **The only hard limit on issuance is
 *        {MAX_SUPPLY}**, enforced by {ERC20Capped}. See docs/v3.1-security-notes.md S-1 / S-2.
 *      - Freezing is implemented with {ERC20Restricted} (BLOCKED) instead of a private mapping.
 *      - The exchange whitelist is {ERC20Restricted} (ALLOWED) plus the SISC transition guard
 *        in {_setRestriction}. The whitelist is append-only: registration is permanent, so a
 *        registered address can never be frozen, unregistered or otherwise changed. Every
 *        registered address is enumerable on-chain through {getRegisteredExchanges}.
 *      - `maxSupply` is enforced by {ERC20Capped}; role holders are enumerable via
 *        {AccessControlEnumerable}.
 *      - Re-entrancy: {mine} and {multiTransfer} carry `nonReentrant` as defence in depth, but
 *        neither makes an external call, so the guard cannot currently trip. The functions that
 *        do call out are the inherited ERC-1363 ones (`transferAndCall`, `transferFromAndCall`,
 *        `approveAndCall`); they are deliberately unguarded because their callbacks fire only
 *        after `_update` and `_spendAllowance` have fully settled, leaving no partial state to
 *        re-enter. Do not read the two guards as covering the ERC-1363 paths.
 *      - Supply accounting: `totalSupply()` is the only figure that reflects existing tokens.
 *        `totalMiningSupply` starts at `legacyMinedSupply`, which this contract never minted, so
 *        remaining issuance is `cap() - totalSupply()` and NOT `cap() - totalMiningSupply()`.
 *        {minedByThisContract} returns the part actually minted by this contract.
 *      - Roles: DEFAULT_ADMIN_ROLE is fixed at deployment. PAUSER_ROLE is gone (pause removed)
 *        and POOLER_ROLE is gone (`multiTransfer` moves only the caller's own balance).
 *        MINING_ADMIN_ROLE is new and separates the mining settings from the top-level admin.
 *        - FREEZER_ROLE: Permission to freeze / unfreeze
 *        - WHITELIST_ROLE: Permission to register exchange addresses (registration is permanent)
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

    /// @dev Role that allows registering exchange addresses. Required for `registerExchange()`.
    ///      There is no counterpart: registration is permanent and cannot be undone by any role.
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

    /// @dev The amount already mined by the previous versions (in wei), as given to the
    ///      constructor. These coins were NOT minted by this contract - they arrive as part of
    ///      {genesisSupply}. Exposed so that {totalMiningSupply} can be split into its historical
    ///      and its on-chain parts. See {minedByThisContract}.
    uint256 public immutable legacyMinedSupply;

    /// @dev Total mining supply (in wei). Starts at {legacyMinedSupply} and grows with every
    ///      `mine()`. This is NOT a supply figure: it counts coins this contract never minted,
    ///      so `cap() - totalMiningSupply` is NOT the remaining issuance. Use
    ///      `cap() - totalSupply()` for that.
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

    /// @dev Append-only registry of every registered exchange address, in registration order.
    ///      Entries are never removed, reordered or overwritten, so an address keeps its index
    ///      for the life of the contract. {registerExchange} returns early for an address that is
    ///      already registered, so the array never contains duplicates, the zero address, or this
    ///      contract.
    address[] private _registeredExchanges;

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

    /// @dev The already-mined supply given to the constructor exceeds {MAX_SUPPLY}.
    ///      It is a cumulative historical figure and is deliberately NOT bounded by the genesis
    ///      supply: the previous versions had burn functions, so more coins may have been mined
    ///      over time than survive in the migration snapshot.
    error InvalidMiningSupply();

    /// @dev The same address appears more than once in `genesisHolders`.
    error DuplicateGenesisHolder(address account);

    /// @dev {setPoolAccount} was given a frozen address, which would brick {mine}.
    error PoolAccountIsFrozen(address account);

    /// @dev {registerExchange} was given an address that must never be registered.
    error InvalidExchangeAddress(address account);

    /// @dev {mine} was called for a year whose reward is zero - either outside the 100-year plan
    ///      (2122 onwards) or explicitly zeroed by {setMiningReward}.
    error NoRewardForYear(uint256 year);

    /// @dev DEFAULT_ADMIN_ROLE is fixed at deployment: it cannot be granted, revoked or renounced.
    error AdminIsFixed();

    /// @dev A registered exchange address cannot be frozen (ALLOWED -> BLOCKED is forbidden).
    error ExchangeAddressProtected(address account);

    /// @dev A registered exchange address can never leave the ALLOWED state
    ///      (ALLOWED -> DEFAULT is forbidden): registration is permanent.
    error ExchangeRegistrationIsPermanent(address account);

    /// @dev A frozen address cannot be registered as an exchange (BLOCKED -> ALLOWED is forbidden).
    error FrozenAddressCannotBeRegistered(address account);

    /// @dev An index argument is outside the bounds of the exchange registry.
    error IndexOutOfBounds(uint256 index, uint256 length);

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

    /// @notice Emitted when an exchange address is registered.
    /// @dev Registration is permanent, so there is no matching "unregistered" event and this
    ///      event is emitted at most once per address.
    /// @param account The exchange address
    /// @param index The index of the address in the append-only registry
    event ExchangeRegistered(address indexed account, uint256 index);

    /// @notice Emitted when the mining reward of a year is changed
    /// @param year The target year
    /// @param oldReward The previous reward for that year (in wei)
    /// @param newReward The new reward for that year (in wei)
    event MiningRewardChanged(uint256 indexed year, uint256 oldReward, uint256 newReward);

    /**
     * @notice Initial role holders of ShirushiCoin.
     * @dev Grouped into a struct for readability. **This does NOT prevent positional mistakes:**
     *      a struct of six `address` fields ABI-encodes as six consecutive address words, exactly
     *      like six positional arguments. The field names survive only in tooling that builds the
     *      call from a named object (an ethers script); in Remix the tuple is a single text field
     *      and on Etherscan it is raw hex, so there the order is all there is.
     *      Getting the `admin` slot wrong is UNRECOVERABLE: {fixedAdminAccount} is taken from it
     *      and can never be granted elsewhere, revoked or renounced, so a hot key landing there
     *      becomes the permanent root of role management. Deploy with `scripts/deploy-sisc.ts`
     *      (named object + pre-flight assertions) and verify the `RoleGranted` logs with
     *      `scripts/verify-deployment.ts` before doing anything else.
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
    * @param legacyMinedSupply_ The amount already mined by the previous versions (in wei).
    *                          Accounting only: it is not minted here. It is a cumulative
    *                          historical total, so it may legitimately exceed the surviving
    *                          migration supply (the previous versions could burn). It is
    *                          therefore bounded only by {MAX_SUPPLY}.
    */
    constructor(
        InitialRoleHolders memory roleHolders,
        address poolAccount_,
        address[] memory genesisHolders,
        uint256[] memory genesisAmounts,
        uint256 legacyMinedSupply_
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

        // The token itself must never hold or receive the supply: there is no burn and no rescue
        // function, so anything sent to `address(this)` is permanently lost and still counts
        // against the cap. {registerExchange} applies the same rule.
        if (poolAccount_ == address(this)) revert InvalidExchangeAddress(poolAccount_);

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
        /// @dev The pool is deliberately NOT auto-registered as an exchange address. Registration
        ///      is permanent and ALLOWED is terminal, so auto-registering would make the mint
        ///      destination permanently unfreezable - and because MINING_ADMIN_ROLE can point the
        ///      pool anywhere and raise any year's reward (S-1), that would remove the only
        ///      on-chain response to an abusive or compromised mint. Freezing the pool does stop
        ///      `mine()`, but that is reversible by unfreezing, whereas a permanent freeze
        ///      exemption is not. Registering the pool is available as an operational choice;
        ///      see docs/v3.1-security-notes.md S-5 for the trade-off.
        ///
        ///      **Scope of this protection.** It holds against a compromised MINING_ADMIN_ROLE +
        ///      MINER_ROLE pair, which cannot register anything. It does NOT hold against the
        ///      fixed admin: DEFAULT_ADMIN_ROLE can grant itself WHITELIST_ROLE, register an
        ///      address of its choosing and then point the pool at it, making the proceeds
        ///      permanently unfreezable (S-3). Nothing here constrains the admin key.
        poolAccount = poolAccount_;
        emit PoolAccountChanged(address(0), poolAccount_);

        // --- Genesis Mint (the only mint outside `mine()`) ---
        uint256 total = 0;
        for (uint256 i = 0; i < holderCount; i++) {
            address holder = genesisHolders[i];
            uint256 amount = genesisAmounts[i];
            if (holder == address(0)) revert ZeroAddress();
            if (holder == address(this)) revert InvalidExchangeAddress(holder);
            if (amount == 0) revert AmountZero();

            // Reject duplicates. The totals still add up, so a repeated address is invisible in
            // `genesisSupply` / `totalSupply` / {GenesisSupplyMinted}, and with no adminMint and
            // no burn path a misallocation here can only be fixed by redeploying.
            for (uint256 j = 0; j < i; j++) {
                if (genesisHolders[j] == holder) revert DuplicateGenesisHolder(holder);
            }

            total += amount;
            _mint(holder, amount);
        }
        genesisSupply = total;

        // --- Supply Accounting ---
        /// @dev Mining total already achieved by the previous versions. Accounting value only:
        ///      cumulative, so it is bounded by the cap rather than by the migration snapshot.
        if (legacyMinedSupply_ > MAX_SUPPLY) revert InvalidMiningSupply();
        legacyMinedSupply = legacyMinedSupply_;
        totalMiningSupply = legacyMinedSupply_;

        emit GenesisSupplyMinted(total, legacyMinedSupply_);

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
    *      - `transfer()` / `transferFrom()` (if the sender, the recipient, or the spender
    *        calling `transferFrom` is a frozen account - see {_spendAllowance})
    *      - receiving mining rewards (`mine()` reverts while the pool account is frozen)
    *      Notes:
    *      - A frozen account can still check its balance via `balanceOf()`, but cannot transfer coins.
    *      - `approve()` / `permit()` are not restricted; the resulting transfer is.
    *      - Freezing is applied per account and has no expiry.
    *      - Execution fails if the account is the zero address, or if the account is a registered
    *        exchange address ({ExchangeAddressProtected}). The latter is permanent: a registered
    *        address can never be frozen, and there is no way to unregister it.
    *      - **Idempotent.** Freezing an already-frozen account succeeds and does nothing; no
    *        {AccountFrozen} event is emitted. A revert here would abort a whole multi-address
    *        Safe batch because one address had been frozen seconds earlier - exactly the race
    *        that happens during an incident. The event still fires only on a real transition,
    *        so indexers can keep treating "event" as "state changed".
    * @param account The account to freeze.
    */
    function freeze(address account) external onlyRole(FREEZER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (getRestriction(account) == Restriction.BLOCKED) return; // already frozen: no-op

        // Reverts on ALLOWED -> BLOCKED. See `_setRestriction`.
        _blockUser(account);

        emit AccountFrozen(account, true);
    }

    /**
    * @notice Unfreeze the specified account, lifting transfer restrictions.
    * @dev This function can only be called by an account holding the `FREEZER_ROLE`.
    *      Resets the {ERC20Restricted} state of the account from BLOCKED to DEFAULT.
    *      **Idempotent**, for the same batch-safety reason as {freeze}: an account that is not
    *      frozen is left untouched and no event is emitted. In particular this means the
    *      FREEZER_ROLE cannot use this function to remove the ALLOWED state of a registered
    *      exchange address - such a call is a silent no-op, never a reset.
    * @param account The account to unfreeze.
    */
    function unfreeze(address account) external onlyRole(FREEZER_ROLE) {
        if (account == address(0)) revert ZeroAddress(); // symmetric with {freeze}
        if (getRestriction(account) != Restriction.BLOCKED) return; // not frozen (or ALLOWED): no-op

        _resetUser(account);

        emit AccountFrozen(account, false);
    }

    /**
    * @notice Register an exchange address, making it permanently immune to freezing.
    * @dev This function can only be called by an account holding the `WHITELIST_ROLE`.
    *      Sets the {ERC20Restricted} state of the account to ALLOWED and appends it to the
    *      append-only registry read by {registeredExchangeCount} / {registeredExchangeAt} /
    *      {getRegisteredExchanges}.
    *
    *      **Registration is permanent and cannot be undone.** There is no unregister function,
    *      and {_setRestriction} rejects every transition out of ALLOWED, so `freeze()` on a
    *      registered address reverts for the life of the contract. No role - including
    *      DEFAULT_ADMIN_ROLE - can remove an address from the whitelist or change its entry.
    *      A wrong address registered here can only be corrected by redeploying the contract.
    *
    *      Execution fails if the account is the zero address, if it is the token contract itself
    *      ({InvalidExchangeAddress}), or if the account is currently frozen
    *      ({FrozenAddressCannotBeRegistered}) - registering it would silently unfreeze it.
    *      Registering an already-registered address is an idempotent no-op: nothing is appended
    *      to the registry and no event is emitted.
    * @param account The exchange address to register.
    */
    function registerExchange(address account) external onlyRole(WHITELIST_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (account == address(this)) revert InvalidExchangeAddress(account);
        if (getRestriction(account) == Restriction.ALLOWED) return; // already registered: no-op

        // Reverts on BLOCKED -> ALLOWED. See `_setRestriction`.
        _allowUser(account);

        uint256 index = _registeredExchanges.length;
        _registeredExchanges.push(account);

        emit ExchangeRegistered(account, index);
    }

    /// @notice Returns true if the account is frozen.
    /// @param account The account to check.
    function isFrozen(address account) external view returns (bool) {
        return getRestriction(account) == Restriction.BLOCKED;
    }

    /// @notice Returns true if the account is on the exchange whitelist.
    /// @dev Once this returns true for an address it returns true forever.
    ///      Named `isWhitelisted` to match the terminology used with the exchange, even though
    ///      the writer is {registerExchange} and the event is {ExchangeRegistered}. All three
    ///      refer to the same ALLOWED state of {ERC20Restricted}.
    /// @param account The account to check.
    function isWhitelisted(address account) external view returns (bool) {
        return getRestriction(account) == Restriction.ALLOWED;
    }

    /// @notice Returns the number of registered exchange addresses.
    /// @dev The registry is append-only, so this value never decreases.
    function registeredExchangeCount() external view returns (uint256) {
        return _registeredExchanges.length;
    }

    /// @notice Returns the registered exchange address at `index`.
    /// @dev Indexes are assigned in registration order and never change.
    /// @param index The position in the registry (0 .. {registeredExchangeCount} - 1).
    function registeredExchangeAt(uint256 index) external view returns (address) {
        uint256 length = _registeredExchanges.length;
        if (index >= length) revert IndexOutOfBounds(index, length);
        return _registeredExchanges[index];
    }

    /**
     * @notice Returns every registered exchange address, in registration order.
     * @dev Intended for off-chain calls (`eth_call`), where the whole registry can be read and
     *      audited in one request. It is not `view`-cheap for on-chain callers: the cost grows
     *      with {registeredExchangeCount}, so use {registeredExchangeAt} to page through the
     *      registry if the list ever grows large.
     */
    function getRegisteredExchanges() external view returns (address[] memory) {
        return _registeredExchanges;
    }

    /**
     * @dev The single write path of the {ERC20Restricted} state, with the SISC transition guard.
     *      {ERC20Restricted} on its own allows any transition. Here **ALLOWED is terminal**:
     *      once an address is registered, no code path can move it to another state, which is
     *      what makes the whitelist append-only.
     *
     *      Forbidden transitions:
     *      - ALLOWED -> BLOCKED ({ExchangeAddressProtected}): a registered exchange address can
     *        never be frozen, by any role.
     *      - ALLOWED -> DEFAULT ({ExchangeRegistrationIsPermanent}): a registered exchange
     *        address can never be unregistered. No external function attempts this - there is
     *        no `unregisterExchange` - and this check is the structural guarantee behind that
     *        absence, including against any future caller of `_resetUser`.
     *      - BLOCKED -> ALLOWED ({FrozenAddressCannotBeRegistered}): registering a frozen
     *        address would silently unfreeze it.
     *
     *      ALLOWED -> ALLOWED never reaches here: {registerExchange} returns early for an
     *      already-registered address, so the registry cannot gain duplicate entries.
     */
    function _setRestriction(address account, Restriction next) internal override {
        Restriction current = getRestriction(account);
        if (current == Restriction.ALLOWED) {
            if (next == Restriction.BLOCKED) revert ExchangeAddressProtected(account);
            revert ExchangeRegistrationIsPermanent(account);
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
     *      The new account must not be frozen ({PoolAccountIsFrozen}): pointing the pool at a
     *      BLOCKED address would make every `mine()` revert. It deliberately does NOT have to be
     *      a registered exchange address - requiring that would force every mint destination to
     *      be permanently unfreezable, which removes the only on-chain response to an abusive
     *      mint (see the constructor and docs/v3.1-security-notes.md S-1 / S-5).
     *      Note this check is a snapshot: the pool can still be frozen afterwards, which pauses
     *      mining until it is unfrozen. That is the intended, reversible failure mode.
     *      An ALLOWED (registered) address IS accepted. Doing so makes the mint destination
     *      permanently unfreezable, which is the trade-off described on the constructor; it is
     *      not blocked here because registering the pool is a legitimate operational choice.
     *      Setting the account it already holds is an idempotent no-op with no event - but the
     *      frozen check runs first, so a successful call always means the pool is currently a
     *      usable destination. Re-applying a frozen pool reverts instead of reporting success.
     * @param account The new pool account address. Must be non-zero, not this contract, not frozen.
     */
    function setPoolAccount(address account) external onlyRole(MINING_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        // Same guard as the constructor and {registerExchange}. Tokens minted to this contract
        // can never be recovered (no burn, no rescue) yet still count against the cap.
        if (account == address(this)) revert InvalidExchangeAddress(account);
        // Checked before the unchanged short-circuit so that "success" never means
        // "nothing happened and mining is still stuck on a frozen pool".
        if (getRestriction(account) == Restriction.BLOCKED) revert PoolAccountIsFrozen(account);
        address old = poolAccount;
        if (account == old) return; // unchanged: no-op
        poolAccount = account;
        emit PoolAccountChanged(old, account);
    }

    /**
    * @dev Retrieve the mining reward for a given year, in wei.
    *      The constructor fills the plan for exactly 100 years: {MINING_START_YEAR} (2022)
    *      through 2121. Behaviour by year:
    *      - below {MINING_START_YEAR}, or above 9999: reverts {InvalidNumber}
    *      - 2022..2121: the planned reward (non-zero unless {setMiningReward} zeroed it)
    *      - 2122..9999: returns 0, meaning the plan is exhausted. {mine} then reverts
    *        {NoRewardForYear}, which is distinct from the malformed-year {InvalidNumber}.
    * @param year The year for which to retrieve the reward (e.g., 2024).
    * @return reward The reward amount in wei (0 for 2122..9999 and for zeroed years).
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

        // Setting the value the year already holds is an idempotent no-op, so that a batch that
        // re-applies a schedule does not abort, and {MiningRewardChanged} is never emitted for a
        // change that did not happen - an indexer would otherwise record a false schedule edit.
        uint256 old = _miningRewardPlan[year];
        if (old == reward) return;
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

        // Reward-related validation. A distinct error separates "the plan has run out for this
        // year" (2122 onwards, or a year zeroed by {setMiningReward}) from a malformed year.
        uint256 miningReward = getMiningReward(year);
        if (miningReward == 0) revert NoRewardForYear(year);

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
    * - **All or nothing.** If the caller or ANY recipient is frozen, `_update` reverts and the
    *   entire batch is rolled back - no subset of the transfers lands. A batch assembled ahead of
    *   time can therefore fail because one recipient was frozen in the meantime. Screen the
    *   recipients with {canTransact} or {isFrozen} before submitting a large batch.
    * - Carries `nonReentrant` as defence in depth, but `_transfer` makes no external call, so the
    *   guard cannot currently trip. See the re-entrancy note on the contract.
    * @param recipients Array of recipient addresses (1..{MAX_BATCH_SIZE}).
    * @param amounts Array of amounts to send, same length as `recipients`.
    * @custom:gas-cost Approximately 29,400 gas per recipient (measured, 100 fresh recipients).
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
        // Only reject an actual removal. Revoking or renouncing DEFAULT_ADMIN_ROLE on an address
        // that never held it is a no-op in {IAccessControl}; reverting on it would make any
        // defensive "renounce everything" batch in a Safe or a deploy script fail as a whole.
        if (role == DEFAULT_ADMIN_ROLE && hasRole(role, account)) revert AdminIsFixed();
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

    /// @notice Returns the amount actually minted by this contract's {mine} (in wei).
    /// @dev `totalMiningSupply` starts at {legacyMinedSupply}, which this contract never minted,
    ///      so this subtraction is the only on-chain figure for v3.1's own mining output.
    ///      Remaining issuance is `cap() - totalSupply()`, never `cap() - totalMiningSupply()`.
    function minedByThisContract() external view returns (uint256) {
        return totalMiningSupply - legacyMinedSupply;
    }

    /**
     * @dev Frozen accounts cannot spend someone else's allowance.
     *
     *      {ERC20Restricted} checks only the `from` and `to` of a transfer, never the spender, so
     *      without this override `freeze(attacker)` would not stop the attacker from calling
     *      `transferFrom(victim, anyCleanAddress, ...)` against allowances approved earlier: the
     *      tokens never touch the frozen address, so every upstream check passes. Freezing is the
     *      incident-response tool for exactly that kind of approval drain, so the spender is
     *      checked here.
     *
     *      This covers `transferFrom` and the inherited `transferFromAndCall`. `approve` and
     *      `permit` stay unrestricted (upstream design - see docs/v3.1-security-notes.md S-4):
     *      a frozen holder can still grant an allowance, but no frozen account can spend one.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        _checkRestriction(spender);
        super._spendAllowance(owner, spender, value);
    }

    /**
     * @dev Override required by Solidity, plus one guard of our own.
     *
     *      Tokens sent to the token contract itself are unrecoverable: there is no burn, no
     *      rescue function and no code path that moves this contract's own balance, yet they
     *      keep counting against {MAX_SUPPLY}. The constructor, {setPoolAccount} and
     *      {registerExchange} already refuse `address(this)`; this closes the remaining route,
     *      which is an ordinary `transfer` / `transferFrom` / `multiTransfer` by any holder.
     *
     *      It reverts with OpenZeppelin's {IERC20Errors-ERC20InvalidReceiver} rather than a
     *      bespoke error, so the failure looks exactly like `transfer(address(0))` to any
     *      integrator already handling the standard ERC-20 error set.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped, ERC20Restricted)
    {
        if (to == address(this)) revert ERC20InvalidReceiver(to);
        super._update(from, to, value);
    }

    // This function is an override required by Solidity.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerable, ERC1363)
        returns (bool)
    {
        // {ERC20Permit} implements {IERC5267} (`eip712Domain()`) but OpenZeppelin does not
        // register it, so an ERC-165 consumer would not discover the working implementation.
        // ERC-20 itself is deliberately not advertised: the standard predates ERC-165 and
        // defines no interface id for it.
        return interfaceId == type(IERC5267).interfaceId || super.supportsInterface(interfaceId);
    }
}
