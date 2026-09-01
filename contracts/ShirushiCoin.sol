// Shirushi Coin ver 3.0

// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.6.1
pragma solidity 0.8.36;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC1363 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol"; // ERC-1363 Transfer And Call
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Pausable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol"; // EIP-2612 ERC20 Permit
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ShirushiCoin
 * @notice ShirushiCoin is the ERC20-compliant token.
 *         It supports mining, freezing, pausing, transfer callbacks (ERC1363),
 *         and gasless approvals (ERC20Permit).
 * @dev This contract inherits from ReentrancyGuard to protect against reentrancy attacks,
 *      and role-based access control (AccessControl) with the following roles:
 *      - PAUSER_ROLE: Permission to pause
 *      - FREEZER_ROLE: Permission to freeze
 *      - RECORDER_ROLE: Permission to record
 *      - MINER_ROLE: Permission to mine
 *      - POOLER_ROLE: Permission to pool
 */
contract ShirushiCoin is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ERC1363, ERC20Permit, ReentrancyGuard {
    // --- Constants ---
    /// @dev String of system version.
    string public constant VERSION = "3.00";

    /// @dev Number of decimal places for the coin. Complies with the ERC20 standard of 18 decimals.
    uint256 public constant DECIMAL_FACTOR = 1e18;

    /// @dev Annual reduction rate of mining rewards (9 = 90%). 
    ///      Example: if last year’s reward was 10,000, this year’s reward is 9,000.
    uint256 public constant MINING_REWARD_REDUCTION_PERCENT = 9;

    /// @dev The starting year of mining.
    uint256 public constant MINING_START_YEAR = 2022;

    /// @dev Initial mining reward (in whole coins, not wei). 
    ///      The actual reward is `INITIAL_MINING_REWARD * DECIMAL_FACTOR`.
    uint256 public constant INITIAL_MINING_REWARD = 10_000;

    /// @dev Minimum interval between mining operations (23 hours).
    uint256 private constant _MINING_MIN_INTERVAL = 23 hours;

    // --- Roles ---
    /// @dev Role that allows pausing/unpausing operations. Required for `pause()`/`unpause()`.
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Role that allows freezing/unfreezing accounts. Required for `freeze()`/`unfreeze()`.
    bytes32 private constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    /// @dev Role that allows recording Web3 Maker AI Data (e.g., AI-generated data). 
    ///      Required for `storeWeb3MakerAIData()`.
    bytes32 private constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    /// @dev Role that allows claiming mining rewards. Required for `mine()`.
    bytes32 private constant MINER_ROLE = keccak256("MINER_ROLE");

    /// @dev Role that allows managing the pool account. 
    ///      Mining rewards are granted only to the single account holding this role. 
    ///      Required for `multiTransfer()`.
    bytes32 private constant POOLER_ROLE = keccak256("POOLER_ROLE");

    // --- State Variables ---
    /// @dev Initial supply (in wei). An immutable value set in the constructor.
    uint256 public immutable initialSupply;

    /// @dev Maximum supply (in wei). Checked in `mint()` to ensure it is not exceeded.
    uint256 public immutable maxSupply;

    /// @dev Total minig supply (in wei).
    uint256 public totalMiningSupply;

    /// @dev The pool account. Mining rewards are granted to this single account.
    address private poolAccount;

    /// @dev Mapping of frozen accounts. `[account] => [isFrozen]`.
    mapping(address => bool) private _frozenAccounts;

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

    // エラー定数の定義
    string constant ERROR_ZERO_ADDRESS = "ZERO_ADDRESS";
    string constant ERROR_AMOUNT_ZERO = "AMOUNT_ZERO";
    string constant ERROR_EXCEEDING_MAX_SUPPLY = "EXCEEDING_MAX_SUPPLY";
    string constant ERROR_INSUFFICIENT_BALANCE = "INSUFFICIENT_BALANCE";
    string constant ERROR_INVALID_NUMBER = "INVALID_NUMBER";
    string constant ERROR_INTERVAL = "COOLDOWN_PERIOD";
    string constant ERROR_EXCEEDING_100_RECIPIENTS = "EXCEEDING_100_RECIPIENTS";
    string constant ERROR_EXCEEDING_100_AMOUNTS = "EXCEEDING_100_AMOUNTS";
    string constant ERROR_LENGTH_MISMATCH = "LENGTH_MISMATCH";
    string constant ERROR_FROZEN_SENDER_ACCOUNT = "FROZEN_SENDER_ACCOUNT";
    string constant ERROR_FROZEN_RECIPIENT_ACCOUNT = "FROZEN_RECIPIENT_ACCOUNT";

    /**
    * @notice Initialization process for ShirushiCoin.
    * @dev This constructor performs the following operations:
    *      Sets the token name ("Shirushi Coin") and symbol ("SISC").
    *      Sets the initial supply (200 million coins) and the maximum supply (300 million coins).
    *      Mints the initial supply to `newAdminAccount`.
    *      Mine the total mining supply whicht was mined already by SISC ver1 to `newAdminAccount`.
    *      Grants all administrative roles to `newAdminAccount`.
    *      Sets the pool account to `newAdminAccount`.
    *      Initializes the mining reward plan (reward schedule for 100 years).
    * @param newAdminAccount The administrator account. 
    *                        Receives the initial supply and is granted all roles 
    *                        (DEFAULT_ADMIN_ROLE, PAUSER_ROLE, etc.).
    */
    constructor(address newAdminAccount)
        ERC20("Shirushi Coin", "SISC")
        ERC20Permit("Shirushi Coin")
    {
        // --- Supply Settings ---
        /// @dev Initial supply: 200,000,000 coins (200,000,000 * 10^18 wei).
        initialSupply = 200_000_000 * DECIMAL_FACTOR;

        /// @dev Maximum supply: 300,000,000 coins (300,000,000 * 10^18 wei).
        maxSupply = 300_000_000 * DECIMAL_FACTOR;

        /// @dev Total mining supply: 9,690,500 which was mined by SISC ver1 (9,690,500 * 10^18 wei).
        totalMiningSupply = 9_690_500 * DECIMAL_FACTOR;

        // --- Initial Mint ---
        /// @dev Mint the initial supply to the administrator account.
        _mint(newAdminAccount, initialSupply);

        /// @dev Mine the total minig supply by SISC ver 1
        _mint(newAdminAccount, totalMiningSupply);

        // --- Role Assignment ---
        /// @dev Grant all roles to the administrator account:
        ///      - DEFAULT_ADMIN_ROLE: Role management authority (can grant/revoke/check roles).
        ///      - PAUSER_ROLE: Authority to pause/unpause.
        ///      - FREEZER_ROLE: Authority to freeze/unfreeze accounts.
        ///      - RECORDER_ROLE: Authority to record Web3 Maker AI data.
        ///      - MINER_ROLE: Authority to mine.
        ///      - POOLER_ROLE: Authority to manage the pool account.
        _grantRole(DEFAULT_ADMIN_ROLE, newAdminAccount);
        _grantRole(PAUSER_ROLE, newAdminAccount);
        _grantRole(FREEZER_ROLE, newAdminAccount);
        _grantRole(RECORDER_ROLE, newAdminAccount);
        _grantRole(MINER_ROLE, newAdminAccount);
        _grantRole(POOLER_ROLE, newAdminAccount);

        // --- Pool Account Setup ---
        /// @dev Set the pool account to the administrator account.
        poolAccount = newAdminAccount;

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

    /// @notice Emitted when the pool account is changed
    /// @param oldAccount The previous pool account address
    /// @param newAccount The new pool account address
    event PoolAccountChanged(address indexed oldAccount, address indexed newAccount);

    /**
     * @notice Update the pool account that receives mining rewards.
     * @dev This function can only be called by an account holding the `DEFAULT_ADMIN_ROLE`.
     *      The pool account is the single address that will receive all mining rewards.
     *      Emits a {PoolAccountChanged} event on success.
     * @param account The new pool account address. Cannot be the zero address.
     */
    function setPoolAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), ERROR_ZERO_ADDRESS);
        address old = poolAccount;
        poolAccount = account;
        emit PoolAccountChanged(old, account);
    }

    /// @notice Enable token pause.
    /// @dev Can only be executed by an account holding the `PAUSER_ROLE`.
    ///      While paused, functions such as transfer and mint are disabled.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the token.
    /// @dev Can only be executed by an account holding the `PAUSER_ROLE`.
    ///      After unpausing, all token functions are resumed.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Emitted when an account is frozen or unfrozen
    /// @param account The account being frozen/unfrozen
    /// @param isFrozen True if the account is now frozen, false if unfrozen
    event AccountFrozen(address indexed account, bool isFrozen);

    /**
    * @notice Freeze the specified account, restricting its token transfers.
    * @dev This function can only be called by an account holding the `FREEZER_ROLE`.
    *      A frozen account is restricted from the following operations:
    *      - `transfer()` / `transferFrom()` (if the sender or recipient is a frozen account)
    *      - `approve()` (if the frozen account attempts to approve)
    *      Notes:
    *      - A frozen account can still check its balance via `balanceOf()`, but cannot transfer coins.
    *      - Freezing is applied per account.
    *      - Execution fails if the account is the zero address.
    * @param account The account to freeze.
    */
    function freeze(address account) external onlyRole(FREEZER_ROLE) {
        require(account != address(0), ERROR_ZERO_ADDRESS);
        _frozenAccounts[account] = true;

        emit AccountFrozen(account, true);
    }

    /**
    * @notice Unfreeze the specified account, lifting transfer restrictions.
    * @dev This function can only be called by an account holding the `FREEZER_ROLE`.
    *      Execution fails if the account is the zero address.
    * @param account The account to unfreeze.
    */
    function unfreeze(address account) external onlyRole(FREEZER_ROLE) {
        require(account != address(0), ERROR_ZERO_ADDRESS);
        _frozenAccounts[account] = false;

        emit AccountFrozen(account, false);
    }


    /**
    * @notice Mint new coins to the specified account by the administrator.
    * @dev This function can only be called by an account holding the `DEFAULT_ADMIN_ROLE`.
    *      New coins are issued to `account`, increasing the total supply.
    *      Notes:
    *      - `amount` must be greater than 0.
    *      - The total supply after minting must not exceed the maximum supply `maxSupply`.
    *        Execution reverts if exceeded.
    *      - Execution reverts if the recipient account is the zero address.
    * @param account The account to mint coins to.
    * @param amount The amount of coins to mint (> 0)(in wei).
    */
    function adminMint(address account, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, ERROR_AMOUNT_ZERO);
        require(account != address(0), ERROR_ZERO_ADDRESS);
        require(totalSupply() + amount <= maxSupply, ERROR_EXCEEDING_MAX_SUPPLY);
        
        // Executing minting
        _mint(account, amount);
    }
        
    /**
    * @notice Burn tokens from the specified account.
    * @dev This burn capability is strictly safeguarded and will NEVER be executed arbitrarily during normal operations.  
    *      It exists solely as an emergency safeguard. If a malicious third party acts against
    *      the common interests of coin holders, this function can be invoked to reset such harmful actions.
    *      Outside of such exceptional scenarios, it will never be used.
    *      And this function can only be called by an account holding the administrator.
    *      The specified `amount` of tokens will be destroyed from the given `account`,
    *      reducing the total supply.
    *      Notes:
    *      - `amount` must be greater than 0.
    *      - The account to burn from must have at least the specified token balance.
    *      - Execution reverts if the account is the zero address.
    * @param account The account from which tokens will be burned.
    * @param amount The amount of tokens to burn (> 0),(in wei).
    */
    function adminBurn(address account, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, ERROR_AMOUNT_ZERO);
        require(account != address(0), ERROR_ZERO_ADDRESS);
        require(balanceOf(account) >= amount, ERROR_INSUFFICIENT_BALANCE);

        // Executing burning
        _burn(account, amount);
    }

    /**
    * @dev Retrieve the mining reward for a given year.
    *      The reward is returned in wei. For invalid years 
    *      (before {MINING_START_YEAR}), 0 is returned.
    * @param year The year for which to retrieve the reward (e.g., 2024).
    * @return reward The reward amount in wei (0 for invalid years).
    */
    function getMiningReward(uint256 year) public view returns (uint256) {
        // Undefined year
        require(year >= MINING_START_YEAR, ERROR_INVALID_NUMBER);
        require(year <= 9999, ERROR_INVALID_NUMBER);

        // Return the mining reward in wei
        return _miningRewardPlan[year];
    }

    /**
    * @notice Set the mining reward for a specific year.
    * @dev This function can only be executed by an account with the `DEFAULT_ADMIN_ROLE`.
    *      Notes:
    *      - `year`: The target year (must be greater than or equal to `MINING_START_YEAR`).
    *      - `reward`: The mining reward for that year (in wei, zero is allowed).
    *      - Existing reward settings will be overwritten.
    *      - Example: (2025, 100 SISC) → Sets the reward for 2025 to 100 SISC.
    * @param year The year to set (≥ MINING_START_YEAR).
    * @param reward The reward amount in wei.
    */
    function setMiningReward(uint256 year, uint256 reward) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Validate year
        require(year >= MINING_START_YEAR, ERROR_INVALID_NUMBER);
        require(year <= 9999, ERROR_INVALID_NUMBER);

        // Set new reward
        _miningRewardPlan[year] = reward;
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
    *      - Total supply does not exceed maxSupply
    *      - The pool account must not be the zero address
    *      - Mining rewards are minted directly to the pool account
    *      - After execution, lastMinedAt and lastMiningReward are updated
    *      - Emits the event: MineEvent(msg.sender, poolAccount, miningReward)
    *      - State variables are updated early to prevent reentrancy attacks
    *      - Interval check is performed first to prevent front-running
    */
    function mine(uint256 year) external onlyRole(MINER_ROLE) nonReentrant {
        // Input Validation (Prioritize interval checks)
        uint256 timestamp = block.timestamp;
        require(
            timestamp - lastMinedAt >= _MINING_MIN_INTERVAL,
            ERROR_INTERVAL
        );

        // Reward-related validation
        uint256 miningReward = getMiningReward(year);
        require(miningReward > 0, ERROR_INVALID_NUMBER);
        require(totalSupply() + miningReward <= maxSupply, ERROR_EXCEEDING_MAX_SUPPLY);

        // Pool Account Validation
        require(poolAccount != address(0), ERROR_ZERO_ADDRESS);

        // Early State Variable Updates (Checks-Effects-Interactions Pattern)
        lastMinedAt = timestamp;
        lastMiningReward = miningReward;

        // Execute mining
        _mint(poolAccount, miningReward);

        // Add mining reward to the total mainig supply
        totalMiningSupply = totalMiningSupply + miningReward;

        // Event trigger
        emit MineEvent(msg.sender, poolAccount, miningReward);
    }

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
        require(web3MakerAIData != bytes32(0), ERROR_INVALID_NUMBER);

        // Emit event (executed before updating storage)
        emit Web3MakerAIDataStored(msg.sender, web3MakerAIData);

        // Update storage
        lastRecordedAt = block.timestamp;
        lastWeb3MakerAIData = web3MakerAIData;
    }

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
    * - Supports up to 100 recipients. 
    * - The function reverts if any recipient is frozen.
    * - Validates that the sender has sufficient balance to cover the total transfer amount.
    * - Prevents reentrancy attacks via ReentrancyGuard.
    * - Only accounts with `POOLER_ROLE` can call this function.
    * @param recipients Array of recipient addresses (max 100).
    * @param amounts Array of amounts to send, same length as `recipients`.
    * @custom:gas-cost Approximately 50,000 gas per recipient (estimated).
    */
    function multiTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    )
        external
        nonReentrant
        onlyRole(POOLER_ROLE)
    {
        // Array length checks to prevent DoS attacks
        require(recipients.length <= 100, ERROR_EXCEEDING_100_RECIPIENTS);
        require(amounts.length <= 100, ERROR_EXCEEDING_100_AMOUNTS);
        require(recipients.length == amounts.length, ERROR_LENGTH_MISMATCH);

        uint256 totalAmount = 0;

        // First pass: validate recipients and calculate total amount
        for (uint256 i = 0; i < recipients.length; i++) {
            require(!_frozenAccounts[recipients[i]], ERROR_FROZEN_RECIPIENT_ACCOUNT);
            totalAmount += amounts[i];
        }

        // Ensure sender has enough balance to cover all transfers
        require(balanceOf(msg.sender) >= totalAmount, ERROR_INSUFFICIENT_BALANCE);

        // Second pass: execute transfers
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }

        // Emit event with actual number of recipients and total amount
        emit MultiTransferEvent(msg.sender, recipients.length, totalAmount);
    }

    // This functions is overrides required by Solidity.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable) {
        if (from != address(0)) {
            require(!_frozenAccounts[from], ERROR_FROZEN_SENDER_ACCOUNT);
        }
        if (to != address(0)) {
            require(!_frozenAccounts[to], ERROR_FROZEN_RECIPIENT_ACCOUNT);
        }
        super._update(from, to, value);
    }

    // This functions is overrides required by Solidity.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC1363)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

