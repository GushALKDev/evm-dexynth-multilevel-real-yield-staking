// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DexynthStakingV1 is Ownable {
    using SafeERC20 for IERC20;

    // Inmutable addresses
    uint40 public immutable GENESIS_EPOCH_TIMESTAMP;
    address public immutable DEXY;          // $DEXY
    address public immutable USDT;          // $USDT

    // Constants addresses
    uint8 public constant NUMBER_OF_LEVELS = 5;

    // SLOT 0
    uint32 public epochDuration;            // 4bytes (Seconds)
    uint32 public lastClosedEpochIndex;     // 4bytes
    address public govAddress;              // 20 bytes (Governance address)

    // SLOT 1
    uint256 public accRewards;              // 32bytes (Accumulated Rewards in USDT)

    // Mappings
    mapping(address => User) public user;
    mapping(uint => Epoch) public epoch;
    mapping(uint => Level) public level;
    mapping(address => mapping(uint => Stake)) public stakeInfo;                                                        // wallet => stakeIndex = Stake
    mapping(address => mapping(uint => mapping(uint => Batch))) public stakedTokensPerWalletAndEpochAndLevel;           // wallet => epoch => level = Batch
    mapping(uint => mapping(uint => Accumulated)) public accStakedTokensPerEpochAndLevel;                               // epoch  => level = Accumulated
    mapping(address => mapping(uint => Accumulated)) public accStakedTokensPerWalletAndLevel;                           // wallet => level = Accumulated


    // Structs
    struct User {
        uint256 totalStakedDEXYs;           // 32 bytes (1e18)
        uint256 totalHarvestedRewards;      // 32 bytes (1e18)
        uint64 stakeIndex;                  // 8 bytes
        uint32 lastEpochHarvested;          // 4 bytes
    }

    struct Stake {
        uint256 stakedDEXYs;                // 32 bytes (1e18)
        uint40 timestamp;                   // 5 bytes
        uint32 startingEpoch;               // 4 bytes
        uint32 unlockingEpoch;              // 4 bytes
        uint8 level;                        // 1 byte
        bool unstacked;                     // 1 byte
    }

    struct Accumulated {
        uint256 accStakedTokens;            // 32 bytes (Accumulated staked tokens for the next epoch)
    }

    struct Batch {
        uint256 stakedDEXYs;                // 32 bytes (1e18)
    }

    struct Level {
        uint64 boostP;                      // 8 bytes
        uint32 lockingPeriod;               // 4 bytes (Locking period in seconds)
    }

    struct Epoch {
        uint256 totalRewards;               // 32 bytes (1e18)
        uint256 totalTokensBoosted;         // 32 bytes (1e18)
        uint40 startTimestamp;              // 5 bytes
        uint40 endTimestamp;                // 5 bytes
    }
    
    // Errors
    error WrongParams();
    error MinimumOneDay();
    error BoostSumNotRight();
    error WrongValues();
    error GovOnly();
    error AlreadyUnstaked();
    error StakeStillLocked();
    error NoEpochsToHarvest();
    error NoStakedTokens();
    error NoRewardsToHarvest();
    error TimestampLowerThanEpoch0Starts();
    error AddressZero();

    // Events
    event GovFundUpdated(address value);

    event LevelsUpdated(Level[5] levels);

    event RewardsHarvested(address indexed user, uint amount);

    event DEXYsStaked(address indexed user, uint amount);

    event DEXYsUnstaked(address indexed user, uint amount);

    event EpochClosed(uint epochIndex, uint rewards);

    event USDTMigrationSuccess(uint amount, address newContractAddress);

    event DEXYMigrationSuccess(uint amount, address newContractAddress);

    constructor(
        address _DEXY,
        address _USDT,
        Level[5] memory _levels,            // [[lockingPeriod0, boostP0], [lockingPeriod1, boostP1], [lockingPeriod2, boostP2], [lockingPeriod3, boostP3], [lockingPeriod4, boostP4]]
                                            // [[2592000, 6500000000], [7776000, 8500000000], [15552000, 10000000000], [31536000, 11500000000], [62208000, 13500000000]]
        uint _epochDuration                 // Seconds
    ) {
        // Checking addresses
        if (address(_DEXY) == address(0) || address(_USDT) == address(0)) revert WrongParams();
        // Checking minimum epoch duration
        if (_epochDuration < 86400) revert MinimumOneDay();
        // Setting epochDuration
        epochDuration = uint32(_epochDuration);
        // Creating genesis epoch
        epoch[0].totalRewards = 0;
        epoch[0].startTimestamp = uint40(block.timestamp - epochDuration);
        epoch[0].endTimestamp = uint40(block.timestamp);
        GENESIS_EPOCH_TIMESTAMP = uint40(block.timestamp - epochDuration);
        // Setting levels data
        checkboostP(_levels);
        for (uint i = 0; i < NUMBER_OF_LEVELS; i++) {
            level[i].lockingPeriod = _levels[i].lockingPeriod;
            level[i].boostP = _levels[i].boostP;
        }
        // Setting addresses
        govAddress = owner();
        DEXY = _DEXY;
        USDT = _USDT;
    }

    // Modifiers
    modifier onlyGov() {
        if (msg.sender != govAddress) revert GovOnly();
        _;
    }

    function stake(uint _amount, uint _level /* starting from 0 */) public {
        // Check for closing epochs first
        checkForClosingEpochs();
        // Deposit DEXYs to the pool
        IERC20(DEXY).safeTransferFrom(msg.sender, address(this), _amount);
        // Create stakeInfo
        stakeInfo[msg.sender][user[msg.sender].stakeIndex].timestamp = uint40(block.timestamp);
        stakeInfo[msg.sender][user[msg.sender].stakeIndex].stakedDEXYs = _amount;
        stakeInfo[msg.sender][user[msg.sender].stakeIndex].level = uint8(_level);
        stakeInfo[msg.sender][user[msg.sender].stakeIndex].startingEpoch = uint32(getCurrentEpochIndex() + 1);
        stakeInfo[msg.sender][user[msg.sender].stakeIndex].unlockingEpoch = uint32(getCurrentEpochIndex() + 1 + (level[_level].lockingPeriod / epochDuration));
        // Accumulate tokens for next epoch
        accStakedTokensPerEpochAndLevel[getCurrentEpochIndex() + 1][_level].accStakedTokens += _amount;
        // Update User values
        user[msg.sender].totalStakedDEXYs += _amount; // Total staked tokens
        stakedTokensPerWalletAndEpochAndLevel[msg.sender][getCurrentEpochIndex() + 1][_level].stakedDEXYs += _amount; // Staked tokens by level
        // accStakedTokensPerWalletAndLevel[msg.sender][_level].accStakedTokens += _amount;
        user[msg.sender].stakeIndex++;
        // Event
        emit DEXYsStaked(msg.sender, _amount);
    }

    function unstake(uint _stakeIndex) public {
        // One unstake per stake
        if (stakeInfo[msg.sender][_stakeIndex].unstacked) revert AlreadyUnstaked();
        // Stake status
        if (getCurrentEpochIndex() < stakeInfo[msg.sender][_stakeIndex].unlockingEpoch) revert StakeStillLocked();
        // Checking for closing epochs
        checkForClosingEpochs();
        // stakeInfo data
        uint _amount = stakeInfo[msg.sender][_stakeIndex].stakedDEXYs;
        uint _level = stakeInfo[msg.sender][_stakeIndex].level;
        uint _epoch = stakeInfo[msg.sender][_stakeIndex].startingEpoch;
        // Try to harvesting tokens first
        if (isHarvestable()) {
            // Harvest rewards
            harvest();
            // Remove unstaked tokens from just consolidated accumulation.
            accStakedTokensPerWalletAndLevel[msg.sender][_level].accStakedTokens -= _amount;
        }
        user[msg.sender].totalStakedDEXYs -= _amount;
        // Remove unstaked tokens from mappings
        stakedTokensPerWalletAndEpochAndLevel[msg.sender][_epoch][_level].stakedDEXYs -= _amount;
        accStakedTokensPerEpochAndLevel[getCurrentEpochIndex()][_level].accStakedTokens -= _amount;       
        // Mark stake as unstaked
        stakeInfo[msg.sender][_stakeIndex].unstacked = true;
        // Transfer DEXYs back to the user
        IERC20(DEXY).safeTransfer(msg.sender, _amount);
        // Event
        emit DEXYsUnstaked(msg.sender, _amount);
    }

    function harvest() public {
        // Check for closing epochs first
        checkForClosingEpochs();
        if (((getCurrentEpochIndex()) - (user[msg.sender].lastEpochHarvested + 1)) == 0) revert NoEpochsToHarvest();
        if (user[msg.sender].totalStakedDEXYs == 0) revert NoStakedTokens();
        uint totalUserRewards;
        // Harvesting from last epoch harvested to the last closed one
        for (uint j = 0; j < NUMBER_OF_LEVELS; j++) {
            // Get the accumulated tokens from last epoch
            for (uint i = user[msg.sender].lastEpochHarvested + 1; i <= getCurrentEpochIndex() - 1; i++) {
                uint epochTotalRewards = epoch[i].totalRewards;
                uint epochTotalBoostedStakedTokens = epoch[i].totalTokensBoosted;
                uint payoutPerTokenAtThisLevel;
                if (epochTotalBoostedStakedTokens * level[j].boostP > 0) {
                    payoutPerTokenAtThisLevel = (((epochTotalRewards * 1e18) / epochTotalBoostedStakedTokens) * level[j].boostP) /  1e10;
                }
                else payoutPerTokenAtThisLevel = 0;
                // Add the staked tokens after last harvest to the accumulated value
                accStakedTokensPerWalletAndLevel[msg.sender][j].accStakedTokens += stakedTokensPerWalletAndEpochAndLevel[msg.sender][i][j].stakedDEXYs;
                totalUserRewards += (payoutPerTokenAtThisLevel * accStakedTokensPerWalletAndLevel[msg.sender][j].accStakedTokens) / 1e18;
            }
            // Store the accumulated tokens after harvest.
        }
        user[msg.sender].lastEpochHarvested = uint32(getCurrentEpochIndex() - 1);
        user[msg.sender].totalHarvestedRewards += totalUserRewards;
        if (totalUserRewards == 0) revert NoRewardsToHarvest();
        // Transfer USDT rewards to the user
        IERC20(USDT).safeTransfer(msg.sender, totalUserRewards);
        // Event
        emit RewardsHarvested(msg.sender, totalUserRewards);
    }

    function addStakingReward(uint _amount) public {
        IERC20(USDT).safeTransferFrom(msg.sender, address(this), _amount);
        accRewards += _amount;
    }

    function checkForClosingEpochs() public {
        uint targetEpochIndex = getCurrentEpochIndex();
        // If there are epochs ready for closing
        if (targetEpochIndex > lastClosedEpochIndex+1) {
            uint epochsReadyForClosing = targetEpochIndex - (lastClosedEpochIndex+1);
            // Calculating rewards for every second
            (uint fromTimestamp,) = getEpochTimestamps(lastClosedEpochIndex+1);
            uint secondsFromLastClosedEpoch = (block.timestamp - fromTimestamp);
            uint rewardsPerSecond = accRewards / secondsFromLastClosedEpoch;
            uint rewardsPerEpoch = rewardsPerSecond * epochDuration;
            for (uint i=0; i<epochsReadyForClosing; i++) {
                closeCurrentEpoch(rewardsPerEpoch);
            }
        }
    }

    function getCurrentEpochIndex() public view returns(uint) {
        return getEpochIndexByTimestamp(block.timestamp);
    }

    function getLevels() public view returns(uint[2][5] memory) {
        uint[2][5] memory levels;
        for (uint i=0; i<NUMBER_OF_LEVELS; i++) {
            levels[i] = [level[i].lockingPeriod,level[i].boostP];
        }
        return levels;
    }

    function closeCurrentEpoch(uint _epochRewards) internal {
        // Closing current epoch...
        // Store rewards
        epoch[lastClosedEpochIndex+1].totalRewards = _epochRewards;
        uint tempTotalTokensBoosted;
        for (uint i = 0; i < NUMBER_OF_LEVELS; i++) {
            tempTotalTokensBoosted += (accStakedTokensPerEpochAndLevel[lastClosedEpochIndex+1][i].accStakedTokens * level[i].boostP) / 1e10;
            // Add the accumulated epoch values to the next one
            accStakedTokensPerEpochAndLevel[lastClosedEpochIndex + 2][i].accStakedTokens += accStakedTokensPerEpochAndLevel[lastClosedEpochIndex+1][i].accStakedTokens;
        }
        // Set totalTokensBoosted
        epoch[lastClosedEpochIndex+1].totalTokensBoosted = tempTotalTokensBoosted;
        // Epoch timestamping
        epoch[lastClosedEpochIndex+1].startTimestamp = uint40(epoch[lastClosedEpochIndex].endTimestamp + 1);
        epoch[lastClosedEpochIndex+1].endTimestamp = uint40(epoch[lastClosedEpochIndex+1].startTimestamp + epochDuration);
        // Event
        emit EpochClosed(lastClosedEpochIndex+1, _epochRewards);
        // Substrate reward from accRewards
        accRewards -= _epochRewards;
        // Increment epoch number
        lastClosedEpochIndex++;
    }

    function getEpochTimestamps(uint _epochIndex) internal view returns(uint, uint) {
        uint startTimestamp = GENESIS_EPOCH_TIMESTAMP + ((epochDuration + 1) * _epochIndex);
        uint endTimeStamp = startTimestamp + epochDuration;
        return (startTimestamp, endTimeStamp);
    }

    function getEpochIndexByTimestamp(uint _timestamp) internal view returns(uint _epochIndex) {
        if (_timestamp < GENESIS_EPOCH_TIMESTAMP) revert TimestampLowerThanEpoch0Starts();
        _epochIndex = (_timestamp - GENESIS_EPOCH_TIMESTAMP) / epochDuration;
        return _epochIndex;
    }

    function isHarvestable() internal view returns (bool) {
        if ((((getCurrentEpochIndex()) - (user[msg.sender].lastEpochHarvested + 1)) > 0) && (user[msg.sender].totalStakedDEXYs > 0) && (accRewards > 0)) {
            return true;
        }
        return false;
    }

    // Manage parameters
    function checkboostP(Level[5] memory _levels) internal view {
        // Level format [lockingPeriod, boostP]
        bool failed;
        uint totalBoost;
        for (uint i = 0; i < NUMBER_OF_LEVELS; i++) {
            if ((i < NUMBER_OF_LEVELS - 1) && (!((_levels[i].lockingPeriod < _levels[i + 1].lockingPeriod) && (_levels[i].boostP < _levels[i + 1].boostP)))) failed = true;
            totalBoost += _levels[i].boostP;
        }
        if (totalBoost != NUMBER_OF_LEVELS * 1e10) revert BoostSumNotRight();
        if (failed) revert WrongValues();
    }

    function migrateContract(address _newContractAddress) public onlyGov {
        uint USDTBalance = IERC20(USDT).balanceOf(address(this));
        uint DEXYBalance = IERC20(DEXY).balanceOf(address(this));
        IERC20(USDT).safeTransfer(_newContractAddress, USDTBalance);
        IERC20(DEXY).safeTransfer(_newContractAddress, DEXYBalance);
        emit USDTMigrationSuccess(USDTBalance, _newContractAddress);
        emit DEXYMigrationSuccess(DEXYBalance, _newContractAddress);
    }

    // Manage addresses
    function setGov(address _value) public onlyGov {
        if (_value == address(0)) revert AddressZero();
        govAddress = _value;
        // Event
        emit GovFundUpdated(_value);
    }

    function setLevels(Level[5] memory _levels) public onlyGov {
        // Level format [lockingPeriod, boostP]
        checkboostP(_levels);
        for (uint i = 0; i < NUMBER_OF_LEVELS; i++) {
            level[i].lockingPeriod = _levels[i].lockingPeriod;
            level[i].boostP = _levels[i].boostP;
        }
        // Event
        emit LevelsUpdated(_levels);
    }    
}