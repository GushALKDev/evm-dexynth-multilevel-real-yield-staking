// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";

/**
 * @title Dexynth Staking V1
 * @notice MasterChef-style staking contract for DEXY tokens.
 * @dev Supports multiple lock periods with boosted rewards.
 *      Uses O(1) reward distribution via accumulators.
 */
contract DexynthStakingV2_1 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // Inmutable addresses
    uint40 public immutable I_GENESIS_EPOCH_TIMESTAMP;
    address public immutable DEXY; // $DEXY
    address public immutable REWARD_TOKEN; // $REWARD_TOKEN
    uint32 public immutable epochDuration;

    // Constants addresses
    uint32 public constant MIGRATION_DELAY = 30 days;
    // After the delay a request can be executed for this long, then it expires
    uint32 public constant MIGRATION_WINDOW = 7 days;
    // Scale of rewardRate and accRewardPerShare, high enough that 6-decimal reward tokens do not truncate to zero
    uint256 private constant PRECISION = 1e36;
    uint256 private constant BOOST_PRECISION = 1e10;

    // Slot 0 is Ownable._owner and slot 1 is ReentrancyGuard._status
    uint32 public migrationRequestTime; //      4 bytes -┐
    uint40 public lastRewardTime; //            5 bytes  │  Slot 2 (15/32)
    uint40 public rewardEndTime; //             5 bytes  │
    bool public migrated; //                    1 byte  -┘
    address public pendingMigrationAddress; // 20 bytes -── Slot 3 (20/32)
    uint256 public rewardRate; //              32 bytes -── Slot 4 (full)
    uint256 public totalBoostedStake; //       32 bytes -── Slot 5 (full)
    uint256 public unallocatedRewards; //      32 bytes -── Slot 6 (full)

    // Levels
    Level[] public levels;

    // Mappings
    mapping(address => User) public users;
    mapping(address => mapping(uint64 => Stake)) public stakeInfo; // wallet => stakeIndex = Stake

    // Per-level reward accumulator (MasterChef pattern)
    mapping(uint8 => uint256) public accRewardPerShare;

    // Structs
    /**
     * @notice User account information
     * @param stakeIndex Total number of stakes created by the user
     * @param totalStakedDexy Total DEXY staked by the user across all levels
     * @param totalHarvestedRewards Total rewards claimed by the user
     */
    struct User {
        uint64 stakeIndex; //              8 bytes -┐  Slot 0 (24/32)
        uint128 totalStakedDexy; //       16 bytes -┘
        uint128 totalHarvestedRewards; // 16 bytes -── Slot 1 (16/32)
    }

    /**
     * @notice Information about a specific stake
     * @param unstaked True if the stake has been withdrawn
     * @param level The boost level index chosen for this stake
     * @param timestamp Timestamp when the stake was created
     * @param rewardStartTime Timestamp when rewards begin accruing (next epoch start)
     * @param unlockTime Timestamp when tokens can be unstaked
     * @param stakedDexy Amount of DEXY tokens staked
     * @param rewardDebt Reward debt snapshot for MasterChef calculation
     */
    struct Stake {
        bool unstaked; //          1 byte  -┐
        uint8 level; //            1 byte   │
        uint40 timestamp; //       5 bytes  │  Slot 0 (17/32)
        uint40 rewardStartTime; // 5 bytes  │
        uint40 unlockTime; //      5 bytes -┘
        uint128 stakedDexy; //    16 bytes -── Slot 1 (16/32)
        uint256 rewardDebt; //    32 bytes -── Slot 2 (full)
    }

    /**
     * @notice Staking level configuration
     * @param lockingPeriod Duration in seconds tokens must be locked
     * @param boostP Reward multiplier (basis points, BOOST_PRECISION precision)
     * @param totalStaked Total DEXY staked in this level globally
     */
    struct Level {
        uint32 lockingPeriod; // 4 bytes -┐
        uint64 boostP; //        8 bytes  │  Slot 0 (28/32)
        uint128 totalStaked; // 16 bytes -┘
    }

    // Errors
    error WrongParams();
    error MinimumOneDay();
    error BoostSumNotRight();
    error WrongValues();
    error AlreadyUnstaked();
    error StakeStillLocked();
    error NoRewardsToHarvest();
    error NoStakedTokens();
    error AddressZero();
    error NoMigrationRequested();
    error TimelockStillActive();
    error MigrationAlreadyPending();
    error NoLevels();
    error ZeroDuration();
    error ZeroBoostedStake();
    error MigrationExpired();
    error AlreadyMigrated();
    error StakeNotFound();
    error SameToken();

    // Events

    /**
     * @notice Emitted when a user harvests rewards
     * @param user The address of the user
     * @param amount The amount of REWARD_TOKEN harvested
     */
    event RewardsHarvested(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user stakes DEXY
     * @param user The address of the user
     * @param amount The amount of DEXY staked
     */
    event DEXYStaked(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user unstakes DEXY
     * @param user The address of the user
     * @param amount The amount of DEXY unstaked
     */
    event DEXYUnstaked(address indexed user, uint256 amount);

    /**
     * @notice Emitted when REWARD_TOKEN liquidity is migrated
     * @param amount Amount of tokens transferred
     * @param newContractAddress Destination address
     */
    event RewardTokenMigrationSuccess(uint256 amount, address indexed newContractAddress);

    /**
     * @notice Emitted when migration is requested
     * @param newContractAddress Proposed destination address
     * @param executeAfter Timestamp when migration can be executed
     */
    event MigrationRequested(address indexed newContractAddress, uint40 executeAfter);

    /// @notice Emitted when migration is cancelled
    event MigrationCancelled();

    /**
     * @notice Constructor
     * @param _dexy Address of the DEXY token
     * @param _rewardToken Address of the Reward Token
     * @param _levels Array of Level configurations
     * @param _epochDuration Duration of each epoch in seconds
     */
    constructor(
        address _dexy,
        address _rewardToken,
        Level[] memory _levels, // [[lockingPeriod0, boostP0], [lockingPeriod1, boostP1], [lockingPeriod2, boostP2], [lockingPeriod3, boostP3], [lockingPeriod4, boostP4]]
        // [[2592000, 6500000000], [7776000, 8500000000], [15552000, 10000000000], [31536000, 11500000000], [62208000, 13500000000]]
        uint256 _epochDuration // Seconds
    ) {
        // Checking addresses
        if (address(_dexy) == address(0) || address(_rewardToken) == address(0)) revert WrongParams();
        if (_dexy == _rewardToken) revert SameToken();
        // Checking minimum epoch duration
        if (_epochDuration < 86400) revert MinimumOneDay();
        if (_levels.length == 0) revert NoLevels();

        // Setting epochDuration and genesis timestamp
        epochDuration = _epochDuration.toUint32();
        I_GENESIS_EPOCH_TIMESTAMP = uint40(block.timestamp);
        lastRewardTime = uint40(block.timestamp);

        // Setting levels data
        _checkboostP(_levels);
        for (uint8 i = 0; i < _levels.length;) {
            levels.push(_levels[i]);
            unchecked {
                i++;
            }
        }

        // Setting addresses
        DEXY = _dexy;
        REWARD_TOKEN = _rewardToken;
    }

    /**
     * @notice Stake DEXY tokens at a specified level
     * @param _amount Amount of DEXY to stake
     * @param _level Level index (0 to numLevels-1)
     */
    function stake(uint256 _amount, uint8 _level) external nonReentrant {
        if (migrated) revert AlreadyMigrated();
        if (_amount == 0) revert WrongParams();
        if (_level >= levels.length) revert WrongParams();
        if ((_amount * levels[_level].boostP) / BOOST_PRECISION == 0) revert ZeroBoostedStake();

        _updatePool();

        uint64 userStakeIndex = users[msg.sender].stakeIndex;
        uint40 nextEpochStart = _getNextEpochStart();
        uint40 unlockTime = uint40(nextEpochStart + levels[_level].lockingPeriod);

        // Create stakeInfo with MasterChef rewardDebt
        stakeInfo[msg.sender][userStakeIndex] = Stake({
            stakedDexy: _amount.toUint128(),
            timestamp: uint40(block.timestamp),
            rewardStartTime: nextEpochStart,
            unlockTime: unlockTime,
            level: _level,
            unstaked: false,
            rewardDebt: Math.mulDiv(_amount, accRewardPerShare[_level], PRECISION)
        });

        // Update level totals (MasterChef pattern)
        levels[_level].totalStaked += _amount.toUint128();
        _recalculateTotalBoostedStake();

        // Update user
        users[msg.sender].totalStakedDexy += _amount.toUint128();
        users[msg.sender].stakeIndex++;

        // Interactions
        IERC20(DEXY).safeTransferFrom(msg.sender, address(this), _amount);

        emit DEXYStaked(msg.sender, _amount);
    }

    /**
     * @notice Unstake DEXY tokens and harvest rewards
     * @param _stakeIndex Index of the stake to unstake
     */
    function unstake(uint64 _stakeIndex) external nonReentrant {
        if (_stakeIndex >= users[msg.sender].stakeIndex) revert StakeNotFound();
        Stake storage s = stakeInfo[msg.sender][_stakeIndex];

        if (s.unstaked) revert AlreadyUnstaked();
        // After a migration principal can always be withdrawn
        if (!migrated && block.timestamp < s.unlockTime) revert StakeStillLocked();

        _updatePool();

        // Calculate rewards
        uint256 pending = 0;
        if (block.timestamp >= s.rewardStartTime) {
            uint256 accReward = accRewardPerShare[s.level];
            pending = Math.mulDiv(s.stakedDexy, accReward, PRECISION) - s.rewardDebt;
        }

        uint256 amount = s.stakedDexy;
        uint8 level = s.level;

        // Effects
        if (pending > 0) {
            users[msg.sender].totalHarvestedRewards += pending.toUint128();
        }

        // Update level totals (MasterChef pattern)
        levels[level].totalStaked -= amount.toUint128();
        _recalculateTotalBoostedStake();

        // Update user
        users[msg.sender].totalStakedDexy -= amount.toUint128();

        // Mark stake as unstaked
        s.unstaked = true;

        // Interactions
        if (pending > 0) {
            IERC20(REWARD_TOKEN).safeTransfer(msg.sender, pending);
            emit RewardsHarvested(msg.sender, pending);
        }

        // Transfer DEXYs back to the user
        IERC20(DEXY).safeTransfer(msg.sender, amount);

        emit DEXYUnstaked(msg.sender, amount);
    }

    /**
     * @notice Harvest all pending rewards for the caller
     */
    function harvest() external nonReentrant {
        if (users[msg.sender].totalStakedDexy == 0) revert NoStakedTokens();

        _updatePool();

        uint256 totalUserRewards = _harvestAll(msg.sender);

        if (totalUserRewards == 0) revert NoRewardsToHarvest();
    }

    /**
     * @dev MasterChef O(1) harvest - loops through user's stakes, not epochs
     * @param _user Address of the user to harvest for
     * @return Total rewards harvested
     */
    function _harvestAll(address _user) internal returns (uint256) {
        uint256 totalPending = 0;
        uint64 stakeCount = users[_user].stakeIndex;

        for (uint64 i = 0; i < stakeCount;) {
            Stake storage s = stakeInfo[_user][i];

            if (!s.unstaked && block.timestamp >= s.rewardStartTime) {
                uint256 accReward = accRewardPerShare[s.level];
                uint256 pending = Math.mulDiv(s.stakedDexy, accReward, PRECISION) - s.rewardDebt;

                if (pending > 0) {
                    totalPending += pending;
                    s.rewardDebt = Math.mulDiv(s.stakedDexy, accReward, PRECISION);
                }
            }
            unchecked {
                i++;
            }
        }

        if (totalPending > 0) {
            users[_user].totalHarvestedRewards += totalPending.toUint128();
            IERC20(REWARD_TOKEN).safeTransfer(_user, totalPending);
            emit RewardsHarvested(_user, totalPending);
        }

        return totalPending;
    }

    /**
     * @notice Add staking rewards with specified duration
     * @param _amount Amount of REWARD_TOKEN to add
     * @param _duration Duration over which to distribute rewards
     */
    function addStakingReward(uint256 _amount, uint256 _duration) external onlyOwner nonReentrant {
        if (migrated) revert AlreadyMigrated();
        if (_duration == 0) revert ZeroDuration();

        _updatePool();

        // Calculate remaining rewards from current rate
        uint256 remainingRewards = 0;
        if (rewardEndTime > block.timestamp) {
            // slither-disable-next-line divide-before-multiply
            remainingRewards = (rewardEndTime - block.timestamp) * rewardRate;
        }

        // New rate = (remaining + unallocated + new) / new duration
        rewardRate = (remainingRewards + unallocatedRewards + _amount * PRECISION) / _duration;
        unallocatedRewards = 0;
        rewardEndTime = (block.timestamp + _duration).toUint40();

        // Interactions
        IERC20(REWARD_TOKEN).safeTransferFrom(msg.sender, address(this), _amount);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get the current epoch index
     * @return Current epoch index based on genesis timestamp and epoch duration
     */
    function getCurrentEpochIndex() public view returns (uint32) {
        if (block.timestamp < I_GENESIS_EPOCH_TIMESTAMP) return 0;
        return uint32((block.timestamp - I_GENESIS_EPOCH_TIMESTAMP) / epochDuration);
    }

    /**
     * @notice Get all staking levels configuration
     * @return Array of Level structs
     */
    function getLevels() external view returns (Level[] memory) {
        return levels;
    }

    /**
     * @notice Get pending rewards for a user across all stakes
     * @dev Simulates _updatePool inline for accurate current pending calculation
     * @param _user Address of the user
     * @return Total pending rewards
     */
    function pendingRewards(address _user) external view returns (uint256) {
        // Simulate _updatePool to get current accRewardPerShare
        // Simulate _updatePool to get current accRewardPerShare
        uint256 numLevels = levels.length;
        uint256[] memory simAccRewardPerShare = new uint256[](numLevels);
        for (uint8 i = 0; i < numLevels; i++) {
            simAccRewardPerShare[i] = accRewardPerShare[i];
        }

        if (totalBoostedStake > 0 && block.timestamp > lastRewardTime) {
            uint256 endTime = rewardEndTime > 0
                ? (block.timestamp < rewardEndTime ? block.timestamp : rewardEndTime)
                : block.timestamp;

            if (endTime > lastRewardTime) {
                uint256 timeElapsed = endTime - lastRewardTime;
                uint256 reward = timeElapsed * rewardRate;

                for (uint8 i = 0; i < numLevels; i++) {
                    if (levels[i].totalStaked > 0) {
                        uint256 levelBoostedStake =
                            (uint256(levels[i].totalStaked) * levels[i].boostP) / BOOST_PRECISION;
                        // slither-disable-next-line divide-before-multiply
                        uint256 levelReward = Math.mulDiv(reward, levelBoostedStake, totalBoostedStake);
                        // slither-disable-next-line divide-before-multiply
                        simAccRewardPerShare[i] += levelReward / levels[i].totalStaked;
                    }
                }
            }
        }

        // Calculate pending with simulated accRewardPerShare
        uint256 total = 0;
        uint64 stakeCount = users[_user].stakeIndex;

        for (uint64 i = 0; i < stakeCount;) {
            Stake storage s = stakeInfo[_user][i];
            if (!s.unstaked && block.timestamp >= s.rewardStartTime && s.stakedDexy > 0) {
                uint256 accReward = simAccRewardPerShare[s.level];
                total += Math.mulDiv(s.stakedDexy, accReward, PRECISION) - s.rewardDebt;
            }
            unchecked {
                i++;
            }
        }

        return total;
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev MasterChef: Updates global reward accumulators - O(levels)
     */
    function _updatePool() private {
        if (block.timestamp <= lastRewardTime) return;

        // Rewards stream only until rewardEndTime
        uint256 endTime = block.timestamp < rewardEndTime ? block.timestamp : rewardEndTime;
        if (endTime <= lastRewardTime) {
            lastRewardTime = uint40(block.timestamp);
            return;
        }

        uint256 reward = (endTime - lastRewardTime) * rewardRate;

        // With no boosted stake nobody can receive the stream, so it is kept for the next addStakingReward
        if (totalBoostedStake == 0) {
            unallocatedRewards += reward;
            lastRewardTime = uint40(block.timestamp);
            return;
        }

        // Distribute to each level proportionally
        uint256 numLevels = levels.length;
        for (uint8 i = 0; i < numLevels;) {
            if (levels[i].totalStaked > 0) {
                uint256 levelBoostedStake = (uint256(levels[i].totalStaked) * levels[i].boostP) / BOOST_PRECISION;
                // slither-disable-next-line divide-before-multiply
                uint256 levelReward = Math.mulDiv(reward, levelBoostedStake, totalBoostedStake);
                // slither-disable-next-line divide-before-multiply
                accRewardPerShare[i] += levelReward / levels[i].totalStaked;
            }
            unchecked {
                i++;
            }
        }

        lastRewardTime = uint40(block.timestamp);
    }

    /**
     * @dev Returns the start timestamp of the next epoch
     * @return Timestamp of the next epoch start
     */
    function _getNextEpochStart() private view returns (uint40) {
        uint32 currentEpoch = getCurrentEpochIndex();
        return uint40(I_GENESIS_EPOCH_TIMESTAMP + uint256(currentEpoch + 1) * epochDuration);
    }

    /**
     * @dev Recalculates totalBoostedStake from level totals to avoid rounding error accumulation
     * @notice This is O(numLevels) where numLevels is set at deployment and immutable thereafter
     */
    function _recalculateTotalBoostedStake() private {
        uint256 total = 0;
        uint256 numLevels = levels.length;
        for (uint256 i = 0; i < numLevels;) {
            total += (uint256(levels[i].totalStaked) * levels[i].boostP) / BOOST_PRECISION;
            unchecked {
                i++;
            }
        }
        totalBoostedStake = total;
    }

    // Manage parameters
    /**
     * @dev Validates level boost configuration
     * levels must be ordered by locking period and boostP
     */
    function _checkboostP(Level[] memory _levels) private pure {
        // Level format [lockingPeriod, boostP]
        uint256 totalBoost = 0;
        uint256 numLevels = _levels.length;

        for (uint256 i = 0; i < numLevels;) {
            // Check ordering with next level (if not the last one)
            if (i < numLevels - 1) {
                Level memory current = _levels[i];
                Level memory next = _levels[i + 1];

                // Must be strictly increasing
                if (current.lockingPeriod >= next.lockingPeriod) revert WrongValues();
                if (current.boostP >= next.boostP) revert WrongValues();
            }

            totalBoost += _levels[i].boostP;
            unchecked {
                i++;
            }
        }

        if (totalBoost != numLevels * BOOST_PRECISION) revert BoostSumNotRight();
    }

    /**
     * @notice Request migration of liquidity to a new contract
     * @param _newContract Address of the new contract
     */
    function requestMigration(address _newContract) external onlyOwner {
        if (migrated) revert AlreadyMigrated();
        if (_newContract == address(0)) revert AddressZero();
        // An expired request does not block a new one
        if (migrationRequestTime != 0 && block.timestamp <= migrationRequestTime + MIGRATION_DELAY + MIGRATION_WINDOW) {
            revert MigrationAlreadyPending();
        }
        pendingMigrationAddress = _newContract;
        migrationRequestTime = uint32(block.timestamp);
        emit MigrationRequested(_newContract, migrationRequestTime + MIGRATION_DELAY);
    }

    /**
     * @notice Cancel a pending migration request
     */
    function cancelMigration() external onlyOwner {
        if (migrationRequestTime == 0) revert NoMigrationRequested();
        pendingMigrationAddress = address(0);
        migrationRequestTime = 0;
        emit MigrationCancelled();
    }

    /**
     * @notice Execute migration after timelock expires
     */
    function executeMigration() external nonReentrant onlyOwner {
        if (migrationRequestTime == 0) revert NoMigrationRequested();
        if (block.timestamp < migrationRequestTime + MIGRATION_DELAY) revert TimelockStillActive();
        if (block.timestamp > migrationRequestTime + MIGRATION_DELAY + MIGRATION_WINDOW) revert MigrationExpired();

        // Rewards streamed up to now stay with the stakers
        _updatePool();

        uint256 remainingScaled = unallocatedRewards;
        if (rewardEndTime > block.timestamp) remainingScaled += (rewardEndTime - block.timestamp) * rewardRate;
        uint256 amount = remainingScaled / PRECISION;
        address migrationAddress = pendingMigrationAddress;

        // Effects: stop the stream, staked principal and accrued rewards are not touched
        rewardRate = 0;
        rewardEndTime = uint40(block.timestamp);
        unallocatedRewards = 0;
        migrated = true;
        pendingMigrationAddress = address(0);
        migrationRequestTime = 0;

        // Interactions
        IERC20(REWARD_TOKEN).safeTransfer(migrationAddress, amount);

        emit RewardTokenMigrationSuccess(amount, migrationAddress);
    }

    /**
     * @notice Get total number of levels
     * @return Number of levels
     */
    function getNumberOfLevels() external view returns (uint8) {
        return uint8(levels.length);
    }
}
