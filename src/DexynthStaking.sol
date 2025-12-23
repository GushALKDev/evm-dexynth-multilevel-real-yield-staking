// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/access/Ownable.sol";
import "@openzeppelin/security/ReentrancyGuard.sol";

contract DexynthStakingV1 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Inmutable addresses
    uint40 public immutable i_genesisEpochTimestamp;
    address public immutable DEXY;                      // $DEXY
    address public immutable USDT;                      // $USDT

    // Constants addresses
    uint8 public constant NUMBER_OF_LEVELS = 5;
    uint32 public constant MIGRATION_DELAY = 30 days;

    // SLOT 0
    uint32 public sEpochDuration;                      // 4bytes (Seconds)
    uint32 public sLastClosedEpochIndex;               // 4bytes (Seconds)
    uint32 public migrationRequestTime;                 // 4bytes (Seconds)
    address public pendingMigrationAddress;             // 20 bytes (Pending migration address)

    // SLOT 1
    uint256 public sAccRewards;                        // 32bytes (Accumulated Rewards in USDT)

    // Levels
    Level[5] public sLevels;

    // Mappings
    mapping(address => User) public sUser;
    mapping(uint32 => Epoch) public sEpoch;
    mapping(address => mapping(uint64 => Stake)) public sStakeInfo;                                                  // wallet => stakeIndex = Stake
    mapping(address => mapping(uint32 => mapping(uint8 => Batch))) public sStakedTokensPerWalletAndEpochAndLevel;    // wallet => epoch => level = Batch
    mapping(uint32 => mapping(uint8 => Accumulated)) public sAccStakedTokensPerEpochAndLevel;                        // epoch  => level = Accumulated
    mapping(address => mapping(uint8 => Accumulated)) public sAccStakedTokensPerWalletAndLevel;                      // wallet => level = Accumulated

    // Structs
    struct User {
        uint128 totalStakedDEXYs;           // 16 bytes (1e18)
        uint128 totalHarvestedRewards;      // 16 bytes (1e18)
        uint64 stakeIndex;                  // 8 bytes
        uint32 lastEpochHarvested;          // 4 bytes
    }

    struct Stake {
        uint128 stakedDEXYs;                // 16 bytes (1e18)
        uint40 timestamp;                   // 5 bytes
        uint32 startingEpoch;               // 4 bytes
        uint32 unlockingEpoch;              // 4 bytes
        uint8 level;                        // 1 byte
        bool unstacked;                     // 1 byte
    }

    struct Accumulated {
        uint128 accStakedTokens;            // 16 bytes (Accumulated staked tokens for the next epoch)
    }

    struct Batch {
        uint128 stakedDEXYs;                // 16 bytes (1e18)
    }

    struct Level {
        uint32 lockingPeriod;               // 4 bytes (Locking period in seconds)
        uint64 boostP;                      // 8 bytes
    }

    struct Epoch {
        uint128 totalRewards;               // 16 bytes (1e18)
        uint128 totalTokensBoosted;         // 16 bytes (1e18)
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
    error NoMigrationRequested();
    error TimelockStillActive();
    error MigrationAlreadyPending();

    // Events
    event GovFundUpdated(address value);

    event LevelsUpdated(Level[5] levels);
    
    event RewardsHarvested(address indexed user, uint256 amount);
    
    event DEXYsStaked(address indexed user, uint256 amount);
    
    event DEXYsUnstaked(address indexed user, uint256 amount);
    
    event EpochClosed(uint32 epochIndex, uint256 rewards);
    
    event USDTMigrationSuccess(uint256 amount, address newContractAddress);
    
    event DEXYMigrationSuccess(uint256 amount, address newContractAddress);
    
    event MigrationRequested(address newContractAddress, uint40 executeAfter);
    
    event MigrationCancelled();

    constructor(
        address _dexy,
        address _usdt,
        Level[5] memory _levels,            // [[lockingPeriod0, boostP0], [lockingPeriod1, boostP1], [lockingPeriod2, boostP2], [lockingPeriod3, boostP3], [lockingPeriod4, boostP4]]
                                            // [[2592000, 6500000000], [7776000, 8500000000], [15552000, 10000000000], [31536000, 11500000000], [62208000, 13500000000]]
        uint256 _epochDuration              // Seconds
    ) {
        // Checking addresses
        if (address(_dexy) == address(0) || address(_usdt) == address(0)) revert WrongParams();
        // Checking minimum epoch duration
        if (_epochDuration < 86400) revert MinimumOneDay();
        // Setting epochDuration
        sEpochDuration = uint32(_epochDuration);
        // Creating genesis epoch
        sEpoch[0].totalRewards = 0;
        sEpoch[0].startTimestamp = uint40(block.timestamp - sEpochDuration);
        sEpoch[0].endTimestamp = uint40(block.timestamp);
        i_genesisEpochTimestamp = uint40(block.timestamp - sEpochDuration);
        // Setting levels data
        _checkboostP(_levels);
        for (uint8 i = 0; i < NUMBER_OF_LEVELS;) {
            sLevels[i].lockingPeriod = _levels[i].lockingPeriod;
            sLevels[i].boostP = _levels[i].boostP;
            unchecked { i++; }
        }
        // Setting addresses
        DEXY = _dexy;
        USDT = _usdt;
    }

    function stake(uint256 _amount, uint8 _level /* starting from 0 */) external nonReentrant {
        if (_amount == 0) revert WrongParams();
        if (_level >= NUMBER_OF_LEVELS) revert WrongParams();
        // Check for closing epochs first
        checkForClosingEpochs();
        // Deposit DEXYs to the pool
        IERC20(DEXY).safeTransferFrom(msg.sender, address(this), _amount);
        
        uint64 userStakeIndex = sUser[msg.sender].stakeIndex;
        uint32 currentEpochIndex = getCurrentEpochIndex();
        uint32 startingEpoch = currentEpochIndex + 1;

        // Create stakeInfo
        sStakeInfo[msg.sender][userStakeIndex].timestamp = uint40(block.timestamp);
        sStakeInfo[msg.sender][userStakeIndex].stakedDEXYs = uint128(_amount);
        sStakeInfo[msg.sender][userStakeIndex].level = _level;
        sStakeInfo[msg.sender][userStakeIndex].startingEpoch = startingEpoch;
        sStakeInfo[msg.sender][userStakeIndex].unlockingEpoch = startingEpoch + (sLevels[_level].lockingPeriod / sEpochDuration);
        // Accumulate tokens for next epoch
        sAccStakedTokensPerEpochAndLevel[startingEpoch][_level].accStakedTokens += uint128(_amount);
        // Update User values
        sUser[msg.sender].totalStakedDEXYs += uint128(_amount); // Total staked tokens
        sStakedTokensPerWalletAndEpochAndLevel[msg.sender][startingEpoch][_level].stakedDEXYs += uint128(_amount); // Staked tokens by level
        sUser[msg.sender].stakeIndex++;
        // Event
        emit DEXYsStaked(msg.sender, _amount);
    }

    function unstake(uint64 _stakeIndex) external nonReentrant {
        // One unstake per stake
        if (sStakeInfo[msg.sender][_stakeIndex].unstacked) revert AlreadyUnstaked();
        // Stake status
        if (getCurrentEpochIndex() < sStakeInfo[msg.sender][_stakeIndex].unlockingEpoch) revert StakeStillLocked();
        // Checking for closing epochs
        checkForClosingEpochs();
        // stakeInfo data
        uint256 amount = sStakeInfo[msg.sender][_stakeIndex].stakedDEXYs;
        uint8 level = sStakeInfo[msg.sender][_stakeIndex].level;
        uint32 epoch = sStakeInfo[msg.sender][_stakeIndex].startingEpoch;
        
        // Try to harvesting tokens first
        _harvest();
        
        // Remove unstaked tokens from just consolidated accumulation.
        // This MUST be done outside the harvest block to ensure correctness even if harvest is skipped.
        if (epoch <= sUser[msg.sender].lastEpochHarvested) {
            sAccStakedTokensPerWalletAndLevel[msg.sender][level].accStakedTokens -= uint128(amount);
        }

        sUser[msg.sender].totalStakedDEXYs -= uint128(amount);
        // Remove unstaked tokens from mappings
        sStakedTokensPerWalletAndEpochAndLevel[msg.sender][epoch][level].stakedDEXYs -= uint128(amount);
        sAccStakedTokensPerEpochAndLevel[getCurrentEpochIndex()][level].accStakedTokens -= uint128(amount);       
        // Mark stake as unstaked
        sStakeInfo[msg.sender][_stakeIndex].unstacked = true;
        // Transfer DEXYs back to the user
        IERC20(DEXY).safeTransfer(msg.sender, amount);
        // Event
        emit DEXYsUnstaked(msg.sender, amount);
    }
    
    function harvest() external nonReentrant() {
        // Check for closing epochs first
        checkForClosingEpochs();
        uint32 currentEpochIndex = getCurrentEpochIndex();
        uint32 lastEpochHarvested = sUser[msg.sender].lastEpochHarvested;
        
        // Revert checks for public function
        if ((currentEpochIndex - (lastEpochHarvested + 1)) == 0) revert NoEpochsToHarvest();
        if (sUser[msg.sender].totalStakedDEXYs == 0) revert NoStakedTokens();
        
        uint256 totalUserRewards = _harvest();
        
        if (totalUserRewards == 0) revert NoRewardsToHarvest();
    }

    function _harvest() internal returns (uint256) {
        uint32 currentEpochIndex = getCurrentEpochIndex();
        uint32 lastEpochHarvested = sUser[msg.sender].lastEpochHarvested;
        
        // If nothing to harvest, return 0
        if ((currentEpochIndex - (lastEpochHarvested + 1)) == 0) return 0;
        if (sUser[msg.sender].totalStakedDEXYs == 0) return 0;
        // If no rewards in the pool, we can skip the calculation loop to save gas
        if (sAccRewards == 0) return 0;
        
        uint256 totalUserRewards;
        // Harvesting from last epoch harvested to the last closed one
        for (uint8 j = 0; j < NUMBER_OF_LEVELS;) {
            uint256 currentAccStakedTokens = sAccStakedTokensPerWalletAndLevel[msg.sender][j].accStakedTokens;
            uint64 boostP = sLevels[j].boostP;
            // Get the accumulated tokens from last epoch
            for (uint32 i = lastEpochHarvested + 1; i <= currentEpochIndex - 1;) {
                uint256 epochTotalRewards = sEpoch[i].totalRewards;
                uint256 epochTotalBoostedStakedTokens = sEpoch[i].totalTokensBoosted;
                uint256 payoutPerTokenAtThisLevel;
                if (epochTotalBoostedStakedTokens * boostP > 0) {
                    payoutPerTokenAtThisLevel = (((epochTotalRewards * 1e18) / epochTotalBoostedStakedTokens) * boostP) /  1e10;
                }
                else payoutPerTokenAtThisLevel = 0;
                // Add the staked tokens after last harvest to the accumulated value
                currentAccStakedTokens += sStakedTokensPerWalletAndEpochAndLevel[msg.sender][i][j].stakedDEXYs;
                totalUserRewards += (payoutPerTokenAtThisLevel * currentAccStakedTokens) / 1e18;
                unchecked { i++; }
            }
            sAccStakedTokensPerWalletAndLevel[msg.sender][j].accStakedTokens = uint128(currentAccStakedTokens);
            unchecked { j++; }
            // Store the accumulated tokens after harvest.
        }
        sUser[msg.sender].lastEpochHarvested = uint32(currentEpochIndex - 1);
        sUser[msg.sender].totalHarvestedRewards += uint128(totalUserRewards);
        
        if (totalUserRewards > 0) {
            // Transfer USDT rewards to the user
            IERC20(USDT).safeTransfer(msg.sender, totalUserRewards);
            // Event
            emit RewardsHarvested(msg.sender, totalUserRewards);
        }
        
        return totalUserRewards;
    }

    function addStakingReward(uint256 _amount) external nonReentrant() {
        IERC20(USDT).safeTransferFrom(msg.sender, address(this), _amount);
        sAccRewards += _amount;
    }

    function checkForClosingEpochs() public {
        uint32 targetEpochIndex = getCurrentEpochIndex();
        uint32 lastClosedEpochIndex = sLastClosedEpochIndex;
        uint32 nextEpochIndex;
        unchecked {
            nextEpochIndex = lastClosedEpochIndex + 1;
        }

        // If there are epochs ready for closing
        if (targetEpochIndex > nextEpochIndex) {
            uint32 epochsReadyForClosing;
            unchecked {
                epochsReadyForClosing = targetEpochIndex - nextEpochIndex;
            }
            // Calculating rewards for every second
            (uint40 fromTimestamp,) = _getEpochTimestamps(nextEpochIndex);
            uint256 secondsFromLastClosedEpoch;
            unchecked {
                secondsFromLastClosedEpoch = (block.timestamp - fromTimestamp);
            }
            uint256 rewardsPerSecond = sAccRewards / secondsFromLastClosedEpoch;
            uint256 rewardsPerEpoch = rewardsPerSecond * sEpochDuration;
            for (uint32 i=0; i<epochsReadyForClosing;) {
                _closeCurrentEpoch(rewardsPerEpoch);
                unchecked { i++; }
            }
        }
    }

    function getCurrentEpochIndex() public view returns(uint32) {
        return _getEpochIndexByTimestamp(block.timestamp);
    }

    function getLevels() external view returns(uint256[2][5] memory) {
        uint256[2][5] memory levels;
        for (uint8 i=0; i<NUMBER_OF_LEVELS;) {
            levels[i] = [uint256(sLevels[i].lockingPeriod), uint256(sLevels[i].boostP)];
            unchecked { i++; }
        }
        return levels;
    }

    function _closeCurrentEpoch(uint256 _epochRewards) private {
        // Closing current epoch...
        uint32 lastClosedEpochIndex = sLastClosedEpochIndex;
        uint32 currentEpochIndex;
        unchecked {
            currentEpochIndex = lastClosedEpochIndex + 1;
        }

        // Store rewards
        sEpoch[currentEpochIndex].totalRewards = uint128(_epochRewards);
        uint256 tempTotalTokensBoosted;
        for (uint8 i = 0; i < NUMBER_OF_LEVELS;) {
            tempTotalTokensBoosted += (uint256(sAccStakedTokensPerEpochAndLevel[currentEpochIndex][i].accStakedTokens) * sLevels[i].boostP) / 1e10;
            // Add the accumulated epoch values to the next one
            sAccStakedTokensPerEpochAndLevel[currentEpochIndex + 1][i].accStakedTokens += sAccStakedTokensPerEpochAndLevel[currentEpochIndex][i].accStakedTokens;
            unchecked { i++; }
        }
        // Set totalTokensBoosted
        sEpoch[currentEpochIndex].totalTokensBoosted = uint128(tempTotalTokensBoosted);
        // Epoch timestamping
        uint40 startTimestamp;
        uint40 endTimestamp;
        unchecked {
            startTimestamp = uint40(sEpoch[lastClosedEpochIndex].endTimestamp);
            endTimestamp = uint40(startTimestamp + sEpochDuration);
        }
        sEpoch[currentEpochIndex].startTimestamp = startTimestamp;
        sEpoch[currentEpochIndex].endTimestamp = endTimestamp;
        // Event
        emit EpochClosed(currentEpochIndex, _epochRewards);
        // Substrate reward from accRewards
        sAccRewards -= _epochRewards;
        // Increment epoch number
        sLastClosedEpochIndex = currentEpochIndex;
    }

    function _getEpochTimestamps(uint32 _epochIndex) private view returns(uint40, uint40) {
        uint40 startTimestamp = uint40(i_genesisEpochTimestamp + ((sEpochDuration) * _epochIndex));
        uint40 endTimeStamp = uint40(startTimestamp + sEpochDuration);
        return (startTimestamp, endTimeStamp);
    }

    function _getEpochIndexByTimestamp(uint256 _timestamp) private view returns(uint32 _epochIndex) {
        if (_timestamp < i_genesisEpochTimestamp) revert TimestampLowerThanEpoch0Starts();
        _epochIndex = uint32((_timestamp - i_genesisEpochTimestamp) / (sEpochDuration));
        return _epochIndex;
    }

    // Manage parameters
    function _checkboostP(Level[5] memory _levels) private pure {
        // Level format [lockingPeriod, boostP]
        bool failed;
        uint256 totalBoost;
        for (uint8 i = 0; i < NUMBER_OF_LEVELS;) {
            if ((i < NUMBER_OF_LEVELS - 1) && (!((_levels[i].lockingPeriod < _levels[i + 1].lockingPeriod) && (_levels[i].boostP < _levels[i + 1].boostP)))) failed = true;
            totalBoost += _levels[i].boostP;
            unchecked { i++; }
        }
        if (totalBoost != NUMBER_OF_LEVELS * 1e10) revert BoostSumNotRight();
        if (failed) revert WrongValues();
    }

    function requestMigration(address _newContract) external onlyOwner {
        if (migrationRequestTime != 0) revert MigrationAlreadyPending();
        pendingMigrationAddress = _newContract;
        migrationRequestTime = uint32(block.timestamp);
        emit MigrationRequested(_newContract, migrationRequestTime + MIGRATION_DELAY);
    }

    function cancelMigration() external onlyOwner {
        if (migrationRequestTime == 0) revert NoMigrationRequested();
        pendingMigrationAddress = address(0);
        migrationRequestTime = 0;
        emit MigrationCancelled();
    }

    function executeMigration() external onlyOwner {
        if (migrationRequestTime == 0) revert NoMigrationRequested();
        if (block.timestamp < migrationRequestTime + MIGRATION_DELAY) revert TimelockStillActive();
        uint256 usdtBalance = IERC20(USDT).balanceOf(address(this));
        uint256 dexyBalance = IERC20(DEXY).balanceOf(address(this));
        address migrationAddress = pendingMigrationAddress;
        IERC20(USDT).safeTransfer(migrationAddress, usdtBalance);
        IERC20(DEXY).safeTransfer(migrationAddress, dexyBalance);
        pendingMigrationAddress = address(0);
        migrationRequestTime = 0;
        emit USDTMigrationSuccess(usdtBalance, migrationAddress);
        emit DEXYMigrationSuccess(dexyBalance, migrationAddress);
    }

    function setLevels(Level[5] memory _levels) external onlyOwner {
        // Level format [lockingPeriod, boostP]
        _checkboostP(_levels);
        for (uint8 i = 0; i < NUMBER_OF_LEVELS;) {
            sLevels[i].lockingPeriod = _levels[i].lockingPeriod;
            sLevels[i].boostP = _levels[i].boostP;
            unchecked { i++; }
        }
        // Event
        emit LevelsUpdated(_levels);
    }    
}