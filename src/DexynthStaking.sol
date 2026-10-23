// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";

/**
 * @title Dexynth Staking V2.3
 * @notice Multi-level DEXY staking with a reward token streamed per second, epoch by epoch
 * @dev Anyone can deposit rewards. A deposit streams at a constant rate over the next epoch to start, so the
 *      rewards deposited during epoch N stream during epoch N + 1, and those deposited before epoch 0 starts
 *      stream during epoch 0. A deposit never changes the rate of an epoch already running.
 *
 *      Rewards are distributed through one accumulator per boosted unit. A stake's boosted amount is
 *      amount * boostP / 1e10, it is stored with the stake and unstake subtracts exactly that value, so
 *      totalBoostedStake is always the sum of the boosted amounts of the open stakes. Reward accounting is kept
 *      per user, so stake, unstake and harvest do not loop over stakes or levels.
 *
 *      Precision and bounds (PRECISION = 1e36):
 *      - rewardRate, queuedRewards, unallocatedRewards and accRewardPerBoostedShare are reward token units scaled
 *        by 1e36.
 *      - The rewards funded over the life of the contract are capped at MAX_TOTAL_FUNDING = type(uint128).max
 *        units (about 3.4e20 tokens with 18 decimals). Every reward amount the contract holds, streams or owes is
 *        therefore below 2^128, which is what the uint128 per-user fields need.
 *      - The smallest boosted stake is 1 unit (stake reverts below it), so one pool update can raise the
 *        accumulator by at most the scaled reward, and over the whole life of the contract by at most
 *        MAX_TOTAL_FUNDING * 1e36, about 3.4e74, below type(uint256).max (about 1.16e77). The sum
 *        (queuedRewards + unallocatedRewards + amount * 1e36) and the product (elapsed * rewardRate) are bounded by
 *        the same value.
 *      - Each pool update truncates the accumulator by less than totalBoostedStake / 1e36 reward units.
 *      - A stake's amount and its boosted amount (amount * boostP / 1e10) must fit in uint128, otherwise stake
 *        reverts.
 */
contract DexynthStakingV2_3 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reward and principal accounting of one user
     * @param stakeCount Number of stakes the user has created, also the index of the next stake
     * @param storedRewards Rewards settled to the user and not yet paid
     * @param totalStakedDexy DEXY principal of the user's open stakes
     * @param boostedBalance Sum of the boosted amounts of the user's open stakes
     * @param totalHarvestedRewards Rewards paid to the user so far
     * @param accRewardSnapshot Value of accRewardPerBoostedShare when the user was last settled. It plays the role
     *        of a reward debt: pending rewards are boostedBalance * (accumulator - snapshot) / 1e36, rounded down
     */
    struct User {
        uint64 stakeCount; //              8 bytes -┐  Slot 0 (24/32)
        uint128 storedRewards; //         16 bytes -┘
        uint128 totalStakedDexy; //       16 bytes -┐  Slot 1 (full)
        uint128 boostedBalance; //        16 bytes -┘
        uint128 totalHarvestedRewards; // 16 bytes -── Slot 2 (16/32)
        uint256 accRewardSnapshot; //     32 bytes -── Slot 3 (full)
    }

    /**
     * @notice One stake of a user
     * @param unstaked True once the principal has been withdrawn
     * @param level Index of the level chosen for this stake
     * @param timestamp Time the stake was created
     * @param unlockTime Earliest time the stake can be withdrawn: the stake's timestamp plus the level's
     *        lockingPeriod. The lock does not apply after a migration
     * @param stakedDexy DEXY principal of the stake
     * @param boostedAmount stakedDexy * boostP / 1e10, rounded down, added to the boosted totals on stake and
     *        subtracted from them on unstake
     */
    struct Stake {
        bool unstaked; //          1 byte  -┐
        uint8 level; //            1 byte   │
        uint40 timestamp; //       5 bytes  │  Slot 0 (28/32)
        uint40 unlockTime; //      5 bytes  │
        uint128 stakedDexy; //    16 bytes -┘
        uint128 boostedAmount; // 16 bytes -── Slot 1 (16/32)
    }

    /**
     * @notice Configuration and totals of one staking level
     * @param lockingPeriod Lock in seconds, counted from the stake's timestamp
     * @param boostP Reward multiplier with 1e10 precision, 1e10 is 1.0x
     * @param totalStaked DEXY principal of the open stakes in this level. The constructor ignores the value passed
     */
    struct Level {
        uint32 lockingPeriod; // 4 bytes -┐
        uint64 boostP; //        8 bytes  │  Slot 0 (28/32)
        uint128 totalStaked; // 16 bytes -┘
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Cap on the rewards funded over the life of the contract, in reward token units
     */
    uint256 public constant MAX_TOTAL_FUNDING = type(uint128).max;

    /**
     * @notice Maximum number of levels accepted by the constructor
     */
    uint256 public constant MAX_LEVELS = 10;

    /**
     * @notice Delay between requestMigration and the first moment executeMigration is allowed
     */
    uint32 public constant MIGRATION_DELAY = 30 days;

    /**
     * @notice Period after MIGRATION_DELAY during which a request can be executed, after it the request expires
     */
    uint32 public constant MIGRATION_WINDOW = 7 days;

    /**
     * @dev Scale of rewardRate, unallocatedRewards and accRewardPerBoostedShare
     */
    uint256 private constant PRECISION = 1e36;

    /**
     * @dev Precision of boostP, 1e10 is a 1.0x multiplier
     */
    uint256 private constant BOOST_PRECISION = 1e10;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Start of epoch 0, after the deployment
     */
    uint40 public immutable I_GENESIS_EPOCH_TIMESTAMP;

    /**
     * @notice Epoch length in seconds. The rewards deposited during an epoch stream over the next one
     */
    uint32 public immutable epochDuration;

    /**
     * @notice Staked token
     */
    address public immutable DEXY;

    /**
     * @notice Reward token
     */
    address public immutable REWARD_TOKEN;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Slot 0 is Ownable._owner, slot 1 is Ownable2Step._pendingOwner and slot 2 is ReentrancyGuard._status
    /**
     * @notice Timestamp of the pending migration request, 0 when there is none
     */
    uint40 public migrationRequestTime; //       5 bytes -┐
    /**
     * @notice Last time the pool was updated
     */
    uint40 public lastRewardTime; //             5 bytes  │
    /**
     * @notice Start of the epoch after the one lastRewardTime falls in, or of epoch 0 until it starts.
     *         queuedRewards stream from it
     */
    uint40 public nextEpochStart; //             5 bytes  │  Slot 3 (full)
    /**
     * @notice True once executeMigration has run
     */
    bool public migrated; //                     1 byte   │
    /**
     * @notice Rewards funded through addStakingReward since deployment, capped at MAX_TOTAL_FUNDING
     */
    uint128 public totalRewardsFunded; //       16 bytes -┘
    /**
     * @notice Destination of the pending migration request
     */
    address public pendingMigrationAddress; //  20 bytes -── Slot 4 (20/32)
    /**
     * @notice Reward token units streamed per second until nextEpochStart, scaled by 1e36
     */
    uint256 public rewardRate; //               32 bytes -── Slot 5 (full)
    /**
     * @notice Sum of the boosted amounts of all open stakes
     */
    uint256 public totalBoostedStake; //        32 bytes -── Slot 6 (full)
    /**
     * @notice Rewards streamed while totalBoostedStake was zero, scaled by 1e36, rolled into the next deposit
     */
    uint256 public unallocatedRewards; //       32 bytes -── Slot 7 (full)
    /**
     * @notice Rewards per boosted unit accumulated since deployment, scaled by 1e36
     */
    uint256 public accRewardPerBoostedShare; // 32 bytes -── Slot 8 (full)
    /**
     * @notice Rewards deposited for the epoch that starts at nextEpochStart, scaled by 1e36
     */
    uint256 public queuedRewards; //            32 bytes -── Slot 9 (full)

    /**
     * @notice Level configuration and totals, fixed length set in the constructor
     */
    Level[] public levels;

    /**
     * @notice Accounting of each user
     */
    mapping(address => User) public users;

    /**
     * @notice Stakes of each user by index, from 0 to stakeCount - 1
     */
    mapping(address => mapping(uint64 => Stake)) public stakeInfo;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when rewards are paid to a user
     * @param user Receiver of the rewards
     * @param amount Amount of REWARD_TOKEN paid
     */
    event RewardsHarvested(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user stakes DEXY
     * @param user Owner of the new stake
     * @param stakeIndex Index of the new stake among the user's stakes
     * @param level Level of the new stake
     * @param amount Amount of DEXY staked
     */
    event DEXYStaked(address indexed user, uint64 indexed stakeIndex, uint8 indexed level, uint256 amount);

    /**
     * @notice Emitted when a user withdraws the principal of a stake
     * @param user Owner of the stake
     * @param stakeIndex Index of the withdrawn stake
     * @param level Level of the withdrawn stake
     * @param amount Amount of DEXY returned
     */
    event DEXYUnstaked(address indexed user, uint64 indexed stakeIndex, uint8 indexed level, uint256 amount);

    /**
     * @notice Emitted when rewards are deposited
     * @param funder Account the reward token was transferred from
     * @param epoch Index of the epoch the deposit streams over
     * @param amount Amount of REWARD_TOKEN transferred in
     */
    event RewardAdded(address indexed funder, uint32 indexed epoch, uint256 amount);

    /**
     * @notice Emitted when the unstreamed rewards are migrated
     * @param amount Amount of REWARD_TOKEN transferred
     * @param newContractAddress Destination address
     */
    event RewardTokenMigrationSuccess(uint256 amount, address indexed newContractAddress);

    /**
     * @notice Emitted when a migration is requested
     * @param newContractAddress Proposed destination address
     * @param executeAfter First timestamp at which the migration can be executed
     */
    event MigrationRequested(address indexed newContractAddress, uint40 executeAfter);

    /**
     * @notice Emitted when a pending migration request is cancelled
     */
    event MigrationCancelled();

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A zero address in the constructor, a zero stake or deposit amount or a level index out of range
     */
    error WrongParams();

    /**
     * @notice The epoch duration passed to the constructor is shorter than one day
     */
    error MinimumOneDay();

    /**
     * @notice The level multipliers do not average 1.0x
     */
    error BoostSumNotRight();

    /**
     * @notice Level lock periods or multipliers are not strictly increasing
     */
    error WrongValues();

    /**
     * @notice The stake has already been withdrawn
     */
    error AlreadyUnstaked();

    /**
     * @notice The stake is still locked and no migration has happened
     */
    error StakeStillLocked();

    /**
     * @notice harvest found no rewards to pay
     */
    error NoRewardsToHarvest();

    /**
     * @notice harvest was called by a user with no open stake
     */
    error NoStakedTokens();

    /**
     * @notice The migration destination is the zero address
     */
    error AddressZero();

    /**
     * @notice There is no migration request to execute or cancel
     */
    error NoMigrationRequested();

    /**
     * @notice The migration delay has not passed yet
     */
    error TimelockStillActive();

    /**
     * @notice A migration request is pending and has not expired
     */
    error MigrationAlreadyPending();

    /**
     * @notice The constructor received no levels
     */
    error NoLevels();

    /**
     * @notice The constructor received a start of epoch 0 that is not after the deployment
     */
    error StartNotInFuture(uint256 firstEpochStart);

    /**
     * @notice Epoch 0 has not started yet
     */
    error EpochsNotStarted(uint256 firstEpochStart);

    /**
     * @notice The stake's boosted amount rounds down to zero
     */
    error ZeroBoostedStake();

    /**
     * @notice The migration window has passed and the request can no longer be executed
     */
    error MigrationExpired();

    /**
     * @notice The contract has been migrated, new stakes, rewards and migrations are disabled
     */
    error AlreadyMigrated();

    /**
     * @notice The caller has no stake with this index
     */
    error StakeNotFound();

    /**
     * @notice DEXY and REWARD_TOKEN are the same address
     */
    error SameToken();

    /**
     * @notice The constructor received more than MAX_LEVELS levels
     */
    error TooManyLevels();

    /**
     * @notice The funding would take totalRewardsFunded above MAX_TOTAL_FUNDING
     */
    error FundingCapExceeded();

    /**
     * @notice renounceOwnership is disabled, ownership can only move to another address through Ownable2Step
     */
    error RenounceOwnershipDisabled();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the tokens, the levels and the epochs, all fixed afterwards
     * @param _dexy Staked token
     * @param _rewardToken Reward token, must differ from _dexy
     * @param _levels Between 1 and MAX_LEVELS levels, lockingPeriod and boostP strictly increasing and boostP
     *        averaging 1e10. The totalStaked field is ignored
     * @param _epochDuration Epoch length in seconds, at least one day
     * @param _firstEpochStart Start of epoch 0, after the deployment. The rewards deposited before it stream during
     *        epoch 0
     */
    constructor(
        address _dexy,
        address _rewardToken,
        Level[] memory _levels,
        uint256 _epochDuration,
        uint256 _firstEpochStart
    ) {
        if (_dexy == address(0) || _rewardToken == address(0)) revert WrongParams();
        if (_dexy == _rewardToken) revert SameToken();
        if (_epochDuration < 1 days) revert MinimumOneDay();
        if (_firstEpochStart <= block.timestamp) revert StartNotInFuture(_firstEpochStart);
        if (_levels.length == 0) revert NoLevels();
        if (_levels.length > MAX_LEVELS) revert TooManyLevels();
        _checkLevels(_levels);

        DEXY = _dexy;
        REWARD_TOKEN = _rewardToken;
        epochDuration = _epochDuration.toUint32();
        I_GENESIS_EPOCH_TIMESTAMP = _firstEpochStart.toUint40();
        lastRewardTime = block.timestamp.toUint40();
        nextEpochStart = _firstEpochStart.toUint40();

        for (uint256 i = 0; i < _levels.length;) {
            levels.push(Level({lockingPeriod: _levels[i].lockingPeriod, boostP: _levels[i].boostP, totalStaked: 0}));
            unchecked {
                i++;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stakes DEXY in a level. The new stake earns rewards from this block on
     * @dev Settles the caller's pending rewards into storedRewards before the boosted balance changes
     * @param _amount Amount of DEXY to stake
     * @param _level Level index, from 0 to getNumberOfLevels() - 1
     */
    function stake(uint256 _amount, uint8 _level) external nonReentrant {
        if (migrated) revert AlreadyMigrated();
        if (_amount == 0 || _level >= levels.length) revert WrongParams();
        Level storage level = levels[_level];
        uint128 amount = _amount.toUint128();
        uint128 boosted = (_amount * level.boostP / BOOST_PRECISION).toUint128();
        if (boosted == 0) revert ZeroBoostedStake();

        _updatePool();
        User storage user = users[msg.sender];
        _settle(user);

        uint40 unlockTime = (block.timestamp + level.lockingPeriod).toUint40();
        uint64 stakeIndex = user.stakeCount;
        stakeInfo[msg.sender][stakeIndex] = Stake({
            unstaked: false,
            level: _level,
            timestamp: block.timestamp.toUint40(),
            unlockTime: unlockTime,
            stakedDexy: amount,
            boostedAmount: boosted
        });
        user.stakeCount = stakeIndex + 1;
        user.totalStakedDexy += amount;
        user.boostedBalance += boosted;
        level.totalStaked += amount;
        totalBoostedStake += boosted;

        IERC20(DEXY).safeTransferFrom(msg.sender, address(this), _amount);

        emit DEXYStaked(msg.sender, stakeIndex, _level, _amount);
    }

    /**
     * @notice Withdraws the principal of one stake and pays all the caller's accrued rewards
     * @dev The lock is ignored after a migration
     * @param _stakeIndex Index of one of the caller's stakes
     */
    function unstake(uint64 _stakeIndex) external nonReentrant {
        User storage user = users[msg.sender];
        if (_stakeIndex >= user.stakeCount) revert StakeNotFound();
        Stake storage s = stakeInfo[msg.sender][_stakeIndex];
        if (s.unstaked) revert AlreadyUnstaked();
        if (!migrated && block.timestamp < s.unlockTime) revert StakeStillLocked();

        _updatePool();
        _settle(user);

        uint128 amount = s.stakedDexy;
        uint128 boosted = s.boostedAmount;
        uint8 level = s.level;
        s.unstaked = true;
        user.totalStakedDexy -= amount;
        user.boostedBalance -= boosted;
        levels[level].totalStaked -= amount;
        totalBoostedStake -= boosted;
        uint256 rewards = _takeStoredRewards(user);

        if (rewards > 0) {
            IERC20(REWARD_TOKEN).safeTransfer(msg.sender, rewards);
            emit RewardsHarvested(msg.sender, rewards);
        }
        IERC20(DEXY).safeTransfer(msg.sender, amount);

        emit DEXYUnstaked(msg.sender, _stakeIndex, level, amount);
    }

    /**
     * @notice Pays all the caller's accrued rewards
     */
    function harvest() external nonReentrant {
        User storage user = users[msg.sender];
        if (user.totalStakedDexy == 0) revert NoStakedTokens();

        _updatePool();
        _settle(user);
        uint256 rewards = _takeStoredRewards(user);
        if (rewards == 0) revert NoRewardsToHarvest();

        IERC20(REWARD_TOKEN).safeTransfer(msg.sender, rewards);

        emit RewardsHarvested(msg.sender, rewards);
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits rewards for the next epoch to start. Anyone can deposit
     * @dev unallocatedRewards join the deposit. The epoch's rate is set when it starts, from everything queued for it
     * @param _amount Amount of REWARD_TOKEN to transfer in
     */
    function addStakingReward(uint256 _amount) external nonReentrant {
        if (migrated) revert AlreadyMigrated();
        if (_amount == 0) revert WrongParams();
        uint256 funded = totalRewardsFunded + _amount;
        if (funded > MAX_TOTAL_FUNDING) revert FundingCapExceeded();

        _updatePool();

        // funded fits in uint128, checked above
        totalRewardsFunded = uint128(funded);
        queuedRewards += unallocatedRewards + _amount * PRECISION;
        unallocatedRewards = 0;
        uint32 epoch = _epochIndexAt(nextEpochStart);

        IERC20(REWARD_TOKEN).safeTransferFrom(msg.sender, address(this), _amount);

        emit RewardAdded(msg.sender, epoch, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Disabled: without an owner no migration could run
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /**
     * @notice Starts the delay before the unstreamed rewards can be migrated to _newContract
     * @dev Only one request can be pending. An expired request does not block a new one
     * @param _newContract Destination of the unstreamed rewards
     */
    function requestMigration(address _newContract) external onlyOwner {
        if (migrated) revert AlreadyMigrated();
        if (_newContract == address(0)) revert AddressZero();
        uint256 requestTime = migrationRequestTime;
        if (requestTime != 0 && block.timestamp <= requestTime + MIGRATION_DELAY + MIGRATION_WINDOW) {
            revert MigrationAlreadyPending();
        }

        uint40 now40 = block.timestamp.toUint40();
        pendingMigrationAddress = _newContract;
        migrationRequestTime = now40;

        emit MigrationRequested(_newContract, now40 + MIGRATION_DELAY);
    }

    /**
     * @notice Cancels the pending migration request
     */
    function cancelMigration() external onlyOwner {
        if (migrationRequestTime == 0) revert NoMigrationRequested();

        pendingMigrationAddress = address(0);
        migrationRequestTime = 0;

        emit MigrationCancelled();
    }

    /**
     * @notice Stops the stream and moves the rewards that are not streamed yet: the rest of the current epoch, the
     *         queued rewards and unallocatedRewards
     * @dev Allowed from MIGRATION_DELAY to MIGRATION_DELAY + MIGRATION_WINDOW after the request. Staked DEXY and
     *      rewards already accrued to stakers stay in the contract. Afterwards stake, addStakingReward and
     *      requestMigration revert, and unstake ignores the lock
     */
    function executeMigration() external nonReentrant onlyOwner {
        uint256 requestTime = migrationRequestTime;
        if (requestTime == 0) revert NoMigrationRequested();
        if (block.timestamp < requestTime + MIGRATION_DELAY) revert TimelockStillActive();
        if (block.timestamp > requestTime + MIGRATION_DELAY + MIGRATION_WINDOW) revert MigrationExpired();

        // Rewards streamed up to now stay with the stakers
        _updatePool();

        uint256 remainingScaled = unallocatedRewards + queuedRewards;
        if (nextEpochStart > block.timestamp) remainingScaled += (nextEpochStart - block.timestamp) * rewardRate;
        uint256 amount = remainingScaled / PRECISION;
        address migrationAddress = pendingMigrationAddress;

        rewardRate = 0;
        queuedRewards = 0;
        unallocatedRewards = 0;
        migrated = true;
        pendingMigrationAddress = address(0);
        migrationRequestTime = 0;

        IERC20(REWARD_TOKEN).safeTransfer(migrationAddress, amount);

        emit RewardTokenMigrationSuccess(amount, migrationAddress);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rewards the user could harvest now
     * @param _user Address of the user
     * @return Stored rewards plus the rewards accrued since the user was last settled
     */
    function pendingRewards(address _user) external view returns (uint256) {
        User storage user = users[_user];
        uint256 acc = accRewardPerBoostedShare;
        (uint256 reward,,) = _streamedSinceUpdate();
        uint256 total = totalBoostedStake;
        if (total > 0) acc += reward / total;
        return user.storedRewards + Math.mulDiv(user.boostedBalance, acc - user.accRewardSnapshot, PRECISION);
    }

    /**
     * @notice Index of the current epoch
     * @dev Reverts before epoch 0 starts
     * @return Number of whole epochs since epoch 0 started
     */
    function getCurrentEpochIndex() external view returns (uint32) {
        if (block.timestamp < I_GENESIS_EPOCH_TIMESTAMP) revert EpochsNotStarted(I_GENESIS_EPOCH_TIMESTAMP);
        return _epochIndexAt(block.timestamp);
    }

    /**
     * @notice All levels with their configuration and totals
     * @return Array of Level structs
     */
    function getLevels() external view returns (Level[] memory) {
        return levels;
    }

    /**
     * @notice Number of levels
     * @dev At most MAX_LEVELS, so it fits in uint8
     * @return Number of levels
     */
    function getNumberOfLevels() external view returns (uint8) {
        return uint8(levels.length);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Streams the rewards since lastRewardTime and moves to the next epoch when one has started. With no boosted
     *      stake the streamed amount goes to unallocatedRewards, otherwise it is added to the accumulator per boosted
     *      unit
     */
    function _updatePool() private {
        if (block.timestamp <= lastRewardTime) return;

        uint256 epochStart = nextEpochStart;
        (uint256 reward, uint256 rate, uint256 nextStart) = _streamedSinceUpdate();
        if (nextStart != epochStart) {
            rewardRate = rate;
            nextEpochStart = nextStart.toUint40();
            queuedRewards = 0;
        }
        if (reward > 0) {
            uint256 total = totalBoostedStake;
            if (total == 0) unallocatedRewards += reward;
            else accRewardPerBoostedShare += reward / total;
        }
        lastRewardTime = block.timestamp.toUint40();
    }

    /**
     * @dev Rewards streamed from lastRewardTime to now, scaled by 1e36, and the rate and next epoch start that apply
     *      from now. Every deposit updates the pool first, so whatever is queued streams over the epoch starting at
     *      nextEpochStart and nothing is queued for the epochs after it: at most two epochs need to be streamed
     * @return reward Rewards streamed since lastRewardTime, scaled by 1e36
     * @return rate Rate from now until nextStart, scaled by 1e36
     * @return nextStart Start of the next epoch after now, or of epoch 0 until it starts
     */
    function _streamedSinceUpdate() private view returns (uint256 reward, uint256 rate, uint256 nextStart) {
        uint256 last = lastRewardTime;
        rate = rewardRate;
        nextStart = nextEpochStart;
        if (block.timestamp <= last) return (0, rate, nextStart);
        if (block.timestamp < nextStart) return ((block.timestamp - last) * rate, rate, nextStart);

        uint256 duration = epochDuration;
        reward = (nextStart - last) * rate;
        // The queued rate keeps 36 extra decimals, so its floor loses less than epochDuration / 1e36 units
        // slither-disable-next-line divide-before-multiply
        rate = queuedRewards / duration;
        uint256 end = nextStart + duration;
        if (block.timestamp < end) {
            reward += (block.timestamp - nextStart) * rate;
            nextStart = end;
        } else {
            // The queued epoch has ended too and nothing was queued after it
            reward += duration * rate;
            rate = 0;
            nextStart = end + ((block.timestamp - end) / duration + 1) * duration;
        }
    }

    /**
     * @dev Moves the rewards accrued since the last settlement into storedRewards, rounded down
     * @param _user Storage pointer to the user
     */
    function _settle(User storage _user) private {
        uint256 acc = accRewardPerBoostedShare;
        uint256 snapshot = _user.accRewardSnapshot;
        // Nothing accrued since the last settlement
        // slither-disable-next-line incorrect-equality
        if (acc == snapshot) return;
        uint256 boosted = _user.boostedBalance;
        if (boosted > 0) _user.storedRewards += Math.mulDiv(boosted, acc - snapshot, PRECISION).toUint128();
        _user.accRewardSnapshot = acc;
    }

    /**
     * @dev Clears storedRewards and adds them to totalHarvestedRewards
     * @param _user Storage pointer to the user
     * @return rewards Amount to transfer to the user
     */
    function _takeStoredRewards(User storage _user) private returns (uint256 rewards) {
        rewards = _user.storedRewards;
        if (rewards > 0) {
            _user.storedRewards = 0;
            // rewards was read from the uint128 storedRewards, so the cast is lossless
            _user.totalHarvestedRewards += uint128(rewards);
        }
    }

    /**
     * @dev Index of the epoch _timestamp falls in. _timestamp fits in uint40 and epochDuration is at least one day,
     *      so the index fits in uint32
     * @param _timestamp Timestamp at or after I_GENESIS_EPOCH_TIMESTAMP
     * @return Number of whole epochs from the start of epoch 0 to _timestamp
     */
    function _epochIndexAt(uint256 _timestamp) private view returns (uint32) {
        return ((_timestamp - I_GENESIS_EPOCH_TIMESTAMP) / epochDuration).toUint32();
    }

    /**
     * @dev Checks that lockingPeriod and boostP are strictly increasing and that boostP averages 1e10
     * @param _levels Levels passed to the constructor
     */
    function _checkLevels(Level[] memory _levels) private pure {
        uint256 numLevels = _levels.length;
        uint256 totalBoost = 0;
        for (uint256 i = 0; i < numLevels;) {
            if (i + 1 < numLevels) {
                if (_levels[i].lockingPeriod >= _levels[i + 1].lockingPeriod) revert WrongValues();
                if (_levels[i].boostP >= _levels[i + 1].boostP) revert WrongValues();
            }
            totalBoost += _levels[i].boostP;
            unchecked {
                i++;
            }
        }
        if (totalBoost != numLevels * BOOST_PRECISION) revert BoostSumNotRight();
    }
}
