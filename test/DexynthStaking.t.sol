// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {DexynthStakingV2_2} from "../src/DexynthStaking.sol";
import {DEXYToken} from "../src/DEXY.sol";
import {RewardToken} from "../src/RewardToken.sol";

/**
 * @notice Unit and fuzz tests of DexynthStakingV2_2 with the example level configuration
 * @dev Reward expectations are exact rational values rounded down. The contract can only lose value against them,
 *      never pay more, so every reward check is `actual <= exact` plus a lower bound of a few wei. The loss sources
 *      are: the floor of rewardRate (below duration / 1e36 wei), the floor of each accumulator update (below
 *      totalBoostedStake / 1e36 wei, with totalBoostedStake at most about 1e23 here) and the floor of each
 *      settlement of a user (below 1 wei each). Each test states how many settlements it has
 */
contract DexynthStakingTest is Test {
    uint256 internal constant EPOCH = 1296000;
    uint256 internal constant L0_LOCK = 2592000;
    uint256 internal constant L1_LOCK = 7776000;
    uint256 internal constant L4_LOCK = 62208000;

    DexynthStakingV2_2 public staking;
    DEXYToken public dexy;
    RewardToken public rewardToken;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        vm.warp(2000000000);

        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        dexy = new DEXYToken();
        rewardToken = new RewardToken();

        DexynthStakingV2_2.Level[] memory levels = new DexynthStakingV2_2.Level[](5);
        levels[0] = DexynthStakingV2_2.Level(2592000, 6500000000, 0);
        levels[1] = DexynthStakingV2_2.Level(7776000, 8500000000, 0);
        levels[2] = DexynthStakingV2_2.Level(15552000, 10000000000, 0);
        levels[3] = DexynthStakingV2_2.Level(31536000, 11500000000, 0);
        levels[4] = DexynthStakingV2_2.Level(62208000, 13500000000, 0);
        staking = new DexynthStakingV2_2(address(dexy), address(rewardToken), levels, EPOCH);

        require(dexy.transfer(user1, 100_000 ether), "Transfer failed");
        require(dexy.transfer(user2, 100_000 ether), "Transfer failed");
        require(dexy.transfer(user3, 100_000 ether), "Transfer failed");

        vm.prank(user1);
        dexy.approve(address(staking), 100_000 ether);
        vm.prank(user2);
        dexy.approve(address(staking), 100_000 ether);
        vm.prank(user3);
        dexy.approve(address(staking), 100_000 ether);

        rewardToken.approve(address(staking), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev actual must not exceed the exact value and may be below it by at most _maxLoss wei
     */
    function _assertReward(uint256 _actual, uint256 _exact, uint256 _maxLoss) internal pure {
        assertLe(_actual, _exact, "paid more than the exact share");
        assertGe(_actual + _maxLoss, _exact, "lost more than the rounding bound");
    }

    function _stake(address _user, uint256 _amount, uint8 _level) internal {
        vm.prank(_user);
        staking.stake(_amount, _level);
    }

    function _nextEpochStart() internal view returns (uint256) {
        return staking.I_GENESIS_EPOCH_TIMESTAMP() + (uint256(staking.getCurrentEpochIndex()) + 1) * EPOCH;
    }

    /*//////////////////////////////////////////////////////////////
                             DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function testDeploy() public view {
        assertEq(staking.owner(), owner);
        assertEq(staking.DEXY(), address(dexy));
        assertEq(staking.REWARD_TOKEN(), address(rewardToken));
        assertEq(staking.epochDuration(), EPOCH);
        assertEq(staking.I_GENESIS_EPOCH_TIMESTAMP(), 2000000000);
        assertEq(staking.lastRewardTime(), 2000000000);
    }

    function testGetLevels() public view {
        DexynthStakingV2_2.Level[] memory levels = staking.getLevels();
        assertEq(staking.getNumberOfLevels(), 5);
        uint32[5] memory locks = [uint32(2592000), 7776000, 15552000, 31536000, 62208000];
        uint64[5] memory boosts = [uint64(6500000000), 8500000000, 10000000000, 11500000000, 13500000000];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(levels[i].lockingPeriod, locks[i]);
            assertEq(levels[i].boostP, boosts[i]);
            assertEq(levels[i].totalStaked, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               MIGRATION
    //////////////////////////////////////////////////////////////*/

    function testMigrationWithTimelock() public {
        // 1000 reward tokens streamed over 60 days, the migration happens halfway
        staking.addStakingReward(1000 ether, 60 days);
        _stake(user1, 500 ether, 0);

        address newContract = address(0x999);
        staking.requestMigration(newContract);
        assertEq(staking.pendingMigrationAddress(), newContract);
        assertEq(staking.migrationRequestTime(), block.timestamp);

        vm.expectRevert(DexynthStakingV2_2.TimelockStillActive.selector);
        staking.executeMigration();

        vm.warp(block.timestamp + 30 days + 1);
        uint256 expectedMoved = (uint256(staking.rewardEndTime()) - block.timestamp) * staking.rewardRate() / 1e36;

        staking.executeMigration();

        // Only the unstreamed rewards move, DEXY principal stays
        assertEq(rewardToken.balanceOf(newContract), expectedMoved);
        assertEq(dexy.balanceOf(newContract), 0);
        assertEq(dexy.balanceOf(address(staking)), 500 ether);
        assertTrue(staking.migrated());
        assertEq(staking.rewardRate(), 0);
    }

    function testMigrationCancel() public {
        address newContract = address(0x999);
        staking.requestMigration(newContract);
        assertEq(staking.pendingMigrationAddress(), newContract);

        staking.cancelMigration();
        assertEq(staking.pendingMigrationAddress(), address(0));
        assertEq(staking.migrationRequestTime(), 0);
    }

    function testMigrationFailNotGov() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.requestMigration(address(0x999));
    }

    function testMigrationFailAlreadyPending() public {
        staking.requestMigration(address(0x999));
        vm.expectRevert(DexynthStakingV2_2.MigrationAlreadyPending.selector);
        staking.requestMigration(address(0x888));
    }

    function testMigrationFailNoRequest() public {
        vm.expectRevert(DexynthStakingV2_2.NoMigrationRequested.selector);
        staking.executeMigration();

        vm.expectRevert(DexynthStakingV2_2.NoMigrationRequested.selector);
        staking.cancelMigration();
    }

    /*//////////////////////////////////////////////////////////////
                                REWARDS
    //////////////////////////////////////////////////////////////*/

    function testRewardRateAccumulation() public {
        staking.addStakingReward(10000 ether, 30 days);
        uint256 rate1 = staking.rewardRate();
        assertEq(rate1, uint256(10000 ether) * 1e36 / 30 days);

        // 10 days later nobody has staked, so those 10 days are unallocated and 20 days are unstreamed. Both are
        // spread with the new 5000 over the new 30 days
        vm.warp(block.timestamp + 10 days);
        staking.addStakingReward(5000 ether, 30 days);
        assertEq(staking.rewardRate(), (10 days * rate1 + 20 days * rate1 + uint256(5000 ether) * 1e36) / 30 days);
        assertEq(staking.rewardEndTime(), block.timestamp + 30 days);
    }

    /**
     * @dev Single staker, one settlement (the view): exact 30,000 * 20 / 30 = 20,000 tokens, at most 1 wei less
     */
    function testPendingRewards() public {
        _stake(user1, 1000 ether, 0);
        staking.addStakingReward(30000 ether, 30 days);
        assertEq(staking.pendingRewards(user1), 0);

        vm.warp(block.timestamp + EPOCH + 5 days);
        _assertReward(staking.pendingRewards(user1), 20000 ether, 1);
    }

    /**
     * @dev 1000 DEXY at 0.65x against 1000 DEXY at 1.35x: 650 and 1350 boosted units out of 2000. After 25 of 30
     *      days, 20,000 * 25 / 30 tokens are streamed. Each user has one settlement (the view)
     */
    function testRewardsDistributionByBoostLevel() public {
        _stake(user1, 1000 ether, 0);
        _stake(user2, 1000 ether, 4);
        staking.addStakingReward(20000 ether, 30 days);

        vm.warp(block.timestamp + EPOCH + 10 days);
        uint256 streamedNum = uint256(20000 ether) * 25;
        _assertReward(staking.pendingRewards(user1), Math.mulDiv(streamedNum, 650, 30 * 2000), 1);
        _assertReward(staking.pendingRewards(user2), Math.mulDiv(streamedNum, 1350, 30 * 2000), 1);
    }

    /**
     * @dev v2.2 change: rewards accrue and are claimable from the stake's block, not from the next epoch start.
     *      Expected: 10,000 tokens * 5 / 30 = 1666.666... tokens, floored to 1666666666666666666666 wei. The
     *      accumulator truncation is below boosted / 1e36 wei, far from moving the floor
     */
    function testRewardsAccrueFromStakeTime() public {
        staking.addStakingReward(10000 ether, 30 days);
        _stake(user1, 1000 ether, 0);
        assertEq(staking.pendingRewards(user1), 0);

        // Five days later, still before the next epoch starts
        vm.warp(block.timestamp + 5 days);
        assertEq(staking.pendingRewards(user1), uint256(10000 ether) * 5 / 30);
    }

    /*//////////////////////////////////////////////////////////////
                                EPOCHS
    //////////////////////////////////////////////////////////////*/

    function testGetCurrentEpochIndex() public {
        assertEq(staking.getCurrentEpochIndex(), 0);
        vm.warp(block.timestamp + EPOCH - 1);
        assertEq(staking.getCurrentEpochIndex(), 0);
        vm.warp(block.timestamp + 1);
        assertEq(staking.getCurrentEpochIndex(), 1);
        vm.warp(block.timestamp + EPOCH);
        assertEq(staking.getCurrentEpochIndex(), 2);
    }

    function testUnlockTimeCalculatedFromEpochStart() public {
        // Stake in the middle of epoch 3: the lock counts from the start of epoch 4
        vm.warp(block.timestamp + 3 * EPOCH + 7 days);
        uint256 nextEpochStart = _nextEpochStart();
        assertEq(nextEpochStart, 2000000000 + 4 * EPOCH);

        _stake(user1, 1000 ether, 0);
        (,, uint40 timestamp, uint40 unlockTime,,) = staking.stakeInfo(user1, 0);
        assertEq(timestamp, block.timestamp);
        assertEq(unlockTime, nextEpochStart + L0_LOCK);
    }

    /*//////////////////////////////////////////////////////////////
                                 STAKE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Boosted units: 600 * 0.65 = 390, 400 * 1.35 = 540, 1800 * 0.85 = 1530, total 2460
     */
    function testStakeDifferentLevels() public {
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        DexynthStakingV2_2.Level[] memory levels = staking.getLevels();
        assertEq(levels[0].totalStaked, 600 ether);
        assertEq(levels[1].totalStaked, 1800 ether);
        assertEq(levels[4].totalStaked, 400 ether);
        assertEq(staking.totalBoostedStake(), 2460 ether);
        (,,, uint128 boosted1,,) = staking.users(user1);
        (,,, uint128 boosted2,,) = staking.users(user2);
        assertEq(boosted1, 930 ether);
        assertEq(boosted2, 1530 ether);
        assertEq(dexy.balanceOf(address(staking)), 2800 ether);
    }

    function testUsersBalancesAfterStaking() public {
        uint256 balanceUser1Before = dexy.balanceOf(user1);
        uint256 balanceUser2Before = dexy.balanceOf(user2);

        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        assertEq(balanceUser1Before - dexy.balanceOf(user1), 1000 ether);
        assertEq(balanceUser2Before - dexy.balanceOf(user2), 1800 ether);
        assertEq(dexy.balanceOf(address(staking)), 2800 ether);
    }

    function testUsersDataAfterStaking() public {
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        (uint64 index1, uint128 stored1, uint128 totalStaked1,, uint128 totalHarvested1,) = staking.users(user1);
        (uint64 index2, uint128 stored2, uint128 totalStaked2,, uint128 totalHarvested2,) = staking.users(user2);

        assertEq(index1, 2);
        assertEq(index2, 1);
        assertEq(totalStaked1, 1000 ether);
        assertEq(totalStaked2, 1800 ether);
        assertEq(stored1, 0);
        assertEq(stored2, 0);
        assertEq(totalHarvested1, 0);
        assertEq(totalHarvested2, 0);
    }

    function testStakeDataAfterStaking() public {
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        (bool u1a, uint8 level1a,, uint40 unlock1a, uint128 staked1a, uint128 boosted1a) = staking.stakeInfo(user1, 0);
        (bool u1b, uint8 level1b,, uint40 unlock1b, uint128 staked1b, uint128 boosted1b) = staking.stakeInfo(user1, 1);
        (bool u2, uint8 level2,, uint40 unlock2, uint128 staked2, uint128 boosted2) = staking.stakeInfo(user2, 0);

        assertFalse(u1a || u1b || u2);
        assertEq(staked1a, 600 ether);
        assertEq(staked1b, 400 ether);
        assertEq(staked2, 1800 ether);
        assertEq(level1a, 0);
        assertEq(level1b, 4);
        assertEq(level2, 1);
        assertEq(boosted1a, 390 ether);
        assertEq(boosted1b, 540 ether);
        assertEq(boosted2, 1530 ether);

        // unlockTime is the start of the next epoch plus the level's lockingPeriod
        uint256 nextEpochStart = _nextEpochStart();
        assertEq(unlock1a, nextEpochStart + L0_LOCK);
        assertEq(unlock1b, nextEpochStart + L4_LOCK);
        assertEq(unlock2, nextEpochStart + L1_LOCK);
    }

    function testStakeFailZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV2_2.WrongParams.selector);
        staking.stake(0, 0);
    }

    function testStakeFailInvalidLevel() public {
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV2_2.WrongParams.selector);
        staking.stake(100 ether, 5);
    }

    /*//////////////////////////////////////////////////////////////
                                UNSTAKE
    //////////////////////////////////////////////////////////////*/

    function testUnstake() public {
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(user1);
        staking.unstake(0);
        vm.prank(user2);
        staking.unstake(0);

        // Only user1's level 4 stake is left: 400 DEXY, 540 boosted units
        DexynthStakingV2_2.Level[] memory levels = staking.getLevels();
        assertEq(levels[0].totalStaked, 0);
        assertEq(levels[1].totalStaked, 0);
        assertEq(levels[4].totalStaked, 400 ether);
        assertEq(staking.totalBoostedStake(), 540 ether);
        assertEq(dexy.balanceOf(address(staking)), 400 ether);
    }

    function testUsersBalancesAfterUnstaking() public {
        uint256 balanceUser1Before = dexy.balanceOf(user1);
        uint256 balanceUser2Before = dexy.balanceOf(user2);

        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(user1);
        staking.unstake(0);
        vm.prank(user2);
        staking.unstake(0);

        // user1 staked 1000 and withdrew 600, user2 withdrew everything
        assertEq(balanceUser1Before - dexy.balanceOf(user1), 400 ether);
        assertEq(balanceUser2Before, dexy.balanceOf(user2));
    }

    function testUsersDataAfterUnstaking() public {
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(user1);
        staking.unstake(0);
        vm.prank(user2);
        staking.unstake(0);

        (,, uint128 totalStaked1, uint128 boosted1,,) = staking.users(user1);
        (,, uint128 totalStaked2, uint128 boosted2,,) = staking.users(user2);
        assertEq(totalStaked1, 400 ether);
        assertEq(boosted1, 540 ether);
        assertEq(totalStaked2, 0);
        assertEq(boosted2, 0);
    }

    function testStakeDataAfterUnstaking() public {
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(user1);
        staking.unstake(0);
        vm.prank(user2);
        staking.unstake(0);

        (bool unstaked1a,,,,,) = staking.stakeInfo(user1, 0);
        (bool unstaked1b,,,,,) = staking.stakeInfo(user1, 1);
        (bool unstaked2,,,,,) = staking.stakeInfo(user2, 0);
        assertTrue(unstaked1a);
        assertFalse(unstaked1b);
        assertTrue(unstaked2);
    }

    function testUnstakeLocked() public {
        _stake(user1, 600 ether, 0);
        (,,, uint40 unlockTime,,) = staking.stakeInfo(user1, 0);

        vm.warp(unlockTime - 1);
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV2_2.StakeStillLocked.selector);
        staking.unstake(0);

        vm.warp(unlockTime);
        vm.prank(user1);
        staking.unstake(0);
        assertEq(dexy.balanceOf(user1), 100_000 ether);
    }

    function testUnstakeTwice() public {
        _stake(user1, 600 ether, 0);
        vm.warp(block.timestamp + 365 days);

        vm.startPrank(user1);
        staking.unstake(0);
        vm.expectRevert(DexynthStakingV2_2.AlreadyUnstaked.selector);
        staking.unstake(0);
        vm.stopPrank();
    }

    /**
     * @dev v2.2 change: unstake pays all the caller's accrued rewards, including those of stakes still open.
     *      user1 alone with 390 + 540 boosted units: the whole 20,000 token stream, one settlement
     */
    function testUnstakePaysAllAccruedRewards() public {
        staking.addStakingReward(20000 ether, 30 days);
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);

        vm.warp(block.timestamp + 60 days);
        vm.prank(user1);
        staking.unstake(0);
        _assertReward(rewardToken.balanceOf(user1), 20000 ether, 1);
        assertEq(staking.pendingRewards(user1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev All stakes are made in the funding block and the whole stream elapses. Boosted units: user1
     *      600 * 0.65 + 400 * 1.35 = 930, user2 1800 * 0.85 = 1530, out of 2460. Exact shares: user1
     *      20,000 * 930 / 2460 = 7560.97... tokens and user2 20,000 * 1530 / 2460 = 12439.02... tokens.
     *      One settlement each
     */
    function testHarvest() public {
        staking.addStakingReward(20000 ether, 30 days);
        _stake(user1, 600 ether, 0);
        _stake(user1, 400 ether, 4);
        _stake(user2, 1800 ether, 1);

        vm.warp(block.timestamp + 30 days + 100);
        vm.prank(user1);
        staking.harvest();
        vm.prank(user2);
        staking.harvest();

        uint256 paid1 = rewardToken.balanceOf(user1);
        uint256 paid2 = rewardToken.balanceOf(user2);
        _assertReward(paid1, Math.mulDiv(20000 ether, 930, 2460), 1);
        _assertReward(paid2, Math.mulDiv(20000 ether, 1530, 2460), 1);

        (, uint128 stored1,,, uint128 harvested1,) = staking.users(user1);
        (, uint128 stored2,,, uint128 harvested2,) = staking.users(user2);
        assertEq(harvested1, paid1);
        assertEq(harvested2, paid2);
        assertEq(stored1, 0);
        assertEq(stored2, 0);
        assertEq(rewardToken.balanceOf(address(staking)), 20000 ether - paid1 - paid2);
    }

    function testHarvestTwice() public {
        staking.addStakingReward(20000 ether, 30 days);
        _stake(user1, 600 ether, 0);

        vm.warp(block.timestamp + 30 days + 100);
        vm.startPrank(user1);
        staking.harvest();
        vm.expectRevert(DexynthStakingV2_2.NoRewardsToHarvest.selector);
        staking.harvest();
        vm.stopPrank();
    }

    function testHarvestNoRewards() public {
        _stake(user1, 600 ether, 0);
        vm.warp(block.timestamp + 30 days + 100);

        vm.prank(user1);
        vm.expectRevert(DexynthStakingV2_2.NoRewardsToHarvest.selector);
        staking.harvest();
    }

    function testHarvestNoStake() public {
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV2_2.NoStakedTokens.selector);
        staking.harvest();
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Stake(uint256 amount, uint8 level) public {
        // 2 wei is the smallest amount with a non-zero boosted stake at the lowest multiplier (2 * 0.65 floors
        // to 1), smaller stakes revert. 100,000 DEXY is the user balance
        amount = bound(amount, 2, 100_000 ether);
        level = uint8(bound(level, 0, 4));
        uint256 balanceBefore = dexy.balanceOf(user1);

        _stake(user1, amount, level);

        assertEq(balanceBefore - dexy.balanceOf(user1), amount);
        (, uint8 stakedLevel,,, uint128 staked, uint128 boosted) = staking.stakeInfo(user1, 0);
        assertEq(staked, amount);
        assertEq(stakedLevel, level);
        assertEq(boosted, amount * staking.getLevels()[level].boostP / 1e10);
        (,, uint128 totalStaked, uint128 userBoosted,,) = staking.users(user1);
        assertEq(totalStaked, amount);
        assertEq(userBoosted, boosted);
    }

    function testFuzz_Unstake(uint256 _amount, uint8 _levelIndex) public {
        _amount = bound(_amount, 1 ether, 100_000 ether);
        _levelIndex = uint8(bound(_levelIndex, 0, 4));
        uint256 initialBalance = dexy.balanceOf(user1);

        _stake(user1, _amount, _levelIndex);

        // unlockTime is the next epoch start plus the lock, so it is reverted one second before and allowed at it
        (,,, uint40 unlockTime,,) = staking.stakeInfo(user1, 0);
        assertEq(unlockTime, _nextEpochStart() + staking.getLevels()[_levelIndex].lockingPeriod);
        vm.warp(unlockTime - 1);
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV2_2.StakeStillLocked.selector);
        staking.unstake(0);

        vm.warp(unlockTime);
        vm.prank(user1);
        staking.unstake(0);
        assertEq(dexy.balanceOf(user1), initialBalance);
        assertEq(staking.totalBoostedStake(), 0);
    }

    /**
     * @dev Single staker and a 30 day stream fully elapsed (at least two 15 day epochs): the staker receives
     *      the whole 10,000 tokens, at most 1 wei less from its one settlement
     */
    function testFuzz_Harvest(uint256 _amount, uint8 _levelIndex, uint32 _epochsToWait) public {
        _amount = bound(_amount, 1 ether, 100_000 ether);
        _levelIndex = uint8(bound(_levelIndex, 0, 4));
        _epochsToWait = uint32(bound(_epochsToWait, 2, 50));

        _stake(user1, _amount, _levelIndex);
        staking.addStakingReward(10_000 ether, 30 days);
        vm.warp(block.timestamp + uint256(_epochsToWait) * EPOCH);

        vm.prank(user1);
        staking.harvest();
        _assertReward(rewardToken.balanceOf(user1), 10_000 ether, 1);
    }

    function testFuzz_MultipleStakes(uint256 amount1, uint8 level1, uint256 amount2, uint8 level2) public {
        amount1 = bound(amount1, 1 ether, 50_000 ether);
        amount2 = bound(amount2, 1 ether, 50_000 ether);
        level1 = uint8(bound(level1, 0, 4));
        level2 = uint8(bound(level2, 0, 4));

        _stake(user1, amount1, level1);
        _stake(user1, amount2, level2);

        (uint64 stakeIndex,, uint128 totalStaked, uint128 boosted,,) = staking.users(user1);
        assertEq(totalStaked, amount1 + amount2);
        assertEq(stakeIndex, 2);

        (, uint8 l1,,, uint128 staked1, uint128 b1) = staking.stakeInfo(user1, 0);
        (, uint8 l2,,, uint128 staked2, uint128 b2) = staking.stakeInfo(user1, 1);
        assertEq(staked1, amount1);
        assertEq(l1, level1);
        assertEq(staked2, amount2);
        assertEq(l2, level2);
        assertEq(boosted, uint256(b1) + b2);
        assertEq(staking.totalBoostedStake(), boosted);
    }

    /**
     * @dev Single staker and any reward amount: the whole amount is paid, at most 1 wei less
     */
    function testFuzz_DynamicRewards(uint256 stakeAmount, uint8 levelIndex, uint256 rewardAmount, uint32 epochsToWait)
        public
    {
        stakeAmount = bound(stakeAmount, 1 ether, 100_000 ether);
        levelIndex = uint8(bound(levelIndex, 0, 4));
        rewardAmount = bound(rewardAmount, 1 ether, 1_000_000 ether);
        epochsToWait = uint32(bound(epochsToWait, 2, 50));

        _stake(user1, stakeAmount, levelIndex);
        staking.addStakingReward(rewardAmount, 30 days);
        vm.warp(block.timestamp + uint256(epochsToWait) * EPOCH);

        vm.prank(user1);
        staking.harvest();
        _assertReward(rewardToken.balanceOf(user1), rewardAmount, 1);
    }
}
