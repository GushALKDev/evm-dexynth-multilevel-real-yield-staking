// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title Handler for DexynthStakingV2_2 invariant testing
 * @notice Bounded actions for stateful fuzzing. The suite runs with fail_on_revert = true: every revert the
 *         contract should raise is asserted with vm.expectRevert, so any other revert fails the run. Calls that
 *         cannot do anything in the current state are discarded with vm.assume and show up as discards in the
 *         forge call table
 */
contract Handler is Test {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public constant NUM_ACTORS = 10;
    address public constant MIGRATION_TARGET = address(0xDEAD);
    address public constant NON_OWNER = address(0xBAD);

    DexynthStakingV2_2 public staking;
    MockERC20 public dexy;
    MockERC20 public reward;
    address public owner;
    uint256 public rewardUnit;

    address[] public actors;

    /**
     * @notice Reward tokens transferred into the staking contract by the owner
     */
    uint256 public ghost_rewardsAdded;

    /**
     * @notice Number of calls per action that reached the contract, including calls asserted to revert
     */
    mapping(bytes32 => uint256) public effective;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(DexynthStakingV2_2 _staking, MockERC20 _dexy, MockERC20 _reward) {
        staking = _staking;
        dexy = _dexy;
        reward = _reward;
        owner = _staking.owner();
        rewardUnit = 10 ** _reward.decimals();
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);
            vm.prank(actor);
            dexy.approve(address(staking), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stakes a small (2 to 1e6 wei) or a regular (1 to 100,000 DEXY) amount at any level
     * @dev After a migration the call must revert with AlreadyMigrated
     */
    function stake(uint256 _actorSeed, uint256 _amount, uint256 _levelSeed, bool _small) external {
        address actor = actors[_actorSeed % NUM_ACTORS];
        uint8 level = uint8(_levelSeed % staking.getNumberOfLevels());
        // 2 wei is the smallest amount with a non-zero boosted stake at the lowest multiplier
        _amount = _small ? bound(_amount, 2, 1e6) : bound(_amount, 1 ether, 100_000 ether);
        dexy.mint(actor, _amount);

        if (staking.migrated()) {
            vm.expectRevert(DexynthStakingV2_2.AlreadyMigrated.selector);
            vm.prank(actor);
            staking.stake(_amount, level);
            effective["stakeAfterMigration"]++;
            return;
        }
        vm.prank(actor);
        staking.stake(_amount, level);
        effective["stake"]++;
    }

    /**
     * @notice Withdraws one open stake of an actor that has one, warping to its unlockTime if it is still locked
     * @dev The warp makes unstake execute instead of being skipped while the stake is locked
     */
    function unstake(uint256 _actorSeed, uint256 _indexSeed) external {
        (address actor, uint64 index, bool found) = _findOpenStake(_actorSeed, _indexSeed);
        vm.assume(found);
        (,,, uint40 unlockTime,,) = staking.stakeInfo(actor, index);
        if (!staking.migrated() && block.timestamp < unlockTime) vm.warp(unlockTime);

        vm.prank(actor);
        staking.unstake(index);
        effective["unstake"]++;
    }

    /**
     * @notice Harvests for the first actor, from the seed, with pending rewards. If stakers exist but none has
     *         anything to claim, checks that harvest reverts with NoRewardsToHarvest
     */
    function harvest(uint256 _actorSeed) external {
        address staker = address(0);
        for (uint256 a = 0; a < NUM_ACTORS; a++) {
            address actor = actors[(_actorSeed % NUM_ACTORS + a) % NUM_ACTORS];
            (,, uint128 staked,,,) = staking.users(actor);
            if (staked == 0) continue;
            if (staking.pendingRewards(actor) > 0) {
                vm.prank(actor);
                staking.harvest();
                effective["harvest"]++;
                return;
            }
            if (staker == address(0)) staker = actor;
        }
        vm.assume(staker != address(0));

        vm.expectRevert(DexynthStakingV2_2.NoRewardsToHarvest.selector);
        vm.prank(staker);
        staking.harvest();
        effective["harvestNothing"]++;
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Owner funds a small (1 wei to 1000 tokens) or a regular (1 to 500,000 tokens) stream
     * @dev After a migration the call must revert with AlreadyMigrated
     */
    function addStakingReward(uint256 _amount, uint256 _duration, bool _small) external {
        _amount = _small ? bound(_amount, 1, 1000 * rewardUnit) : bound(_amount, rewardUnit, 500_000 * rewardUnit);
        _duration = bound(_duration, 1 days, 180 days);
        reward.mint(owner, _amount);

        vm.startPrank(owner);
        reward.approve(address(staking), _amount);
        if (staking.migrated()) {
            vm.expectRevert(DexynthStakingV2_2.AlreadyMigrated.selector);
            staking.addStakingReward(_amount, _duration);
            vm.stopPrank();
            // The minted tokens stay with the owner, outside the conservation check
            effective["addRewardAfterMigration"]++;
            return;
        }
        staking.addStakingReward(_amount, _duration);
        vm.stopPrank();
        ghost_rewardsAdded += _amount;
        effective["addReward"]++;
    }

    /**
     * @notice A non-owner tries to fund or reschedule the stream, which must revert
     */
    function addStakingRewardNonOwner(uint256 _amount, uint256 _duration) external {
        _amount = bound(_amount, 0, 1000 * rewardUnit);
        _duration = bound(_duration, 1, 3650 days);
        reward.mint(NON_OWNER, _amount);

        vm.startPrank(NON_OWNER);
        reward.approve(address(staking), _amount);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.addStakingReward(_amount, _duration);
        vm.stopPrank();
        effective["addRewardNonOwner"]++;
    }

    /**
     * @notice Requests a migration. Must revert while another request is live or after a migration
     * @dev Discarded 7 times out of 8 so that most runs spend most of their calls before a migration, where
     *      stake, unstake and harvest have something to do
     */
    function requestMigration(uint256 _seed) external {
        vm.assume(_seed % 8 == 0);
        uint256 requestTime = staking.migrationRequestTime();
        bool isMigrated = staking.migrated();
        uint256 end = _migrationEnd();
        if (isMigrated) {
            vm.expectRevert(DexynthStakingV2_2.AlreadyMigrated.selector);
        } else if (requestTime != 0 && block.timestamp <= requestTime + end) {
            vm.expectRevert(DexynthStakingV2_2.MigrationAlreadyPending.selector);
        }
        vm.prank(owner);
        staking.requestMigration(MIGRATION_TARGET);
        effective["requestMigration"]++;
    }

    /**
     * @notice Cancels the pending request, or checks the revert when there is none
     */
    function cancelMigration() external {
        if (staking.migrationRequestTime() == 0) vm.expectRevert(DexynthStakingV2_2.NoMigrationRequested.selector);
        vm.prank(owner);
        staking.cancelMigration();
        effective["cancelMigration"]++;
    }

    /**
     * @notice Executes a live request at a point of its window chosen by the seed, warping forward if needed
     */
    function executeMigration(uint256 _offsetSeed) external {
        uint256 requestTime = staking.migrationRequestTime();
        vm.assume(requestTime != 0 && block.timestamp <= requestTime + _migrationEnd());
        uint256 earliest = requestTime + staking.MIGRATION_DELAY();
        uint256 window = staking.MIGRATION_WINDOW();
        if (block.timestamp < earliest) vm.warp(earliest + _offsetSeed % (window + 1));

        vm.prank(owner);
        staking.executeMigration();
        effective["executeMigration"]++;
    }

    /**
     * @notice Lets a live request expire and checks that it can no longer be executed
     */
    function expireMigration() external {
        uint256 requestTime = staking.migrationRequestTime();
        vm.assume(requestTime != 0);
        uint256 expiry = requestTime + _migrationEnd() + 1;
        if (block.timestamp < expiry) vm.warp(expiry);

        vm.prank(owner);
        vm.expectRevert(DexynthStakingV2_2.MigrationExpired.selector);
        staking.executeMigration();
        effective["expireMigration"]++;
    }

    /*//////////////////////////////////////////////////////////////
                              TIME ACTIONS
    //////////////////////////////////////////////////////////////*/

    function advanceTime(uint256 _seconds) external {
        vm.warp(block.timestamp + bound(_seconds, 1 hours, 30 days));
        effective["advanceTime"]++;
    }

    function advanceOneEpoch() external {
        vm.warp(block.timestamp + staking.epochDuration());
        effective["advanceOneEpoch"]++;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function getActor(uint256 _index) external view returns (address) {
        return actors[_index];
    }

    function _migrationEnd() internal view returns (uint256) {
        return uint256(staking.MIGRATION_DELAY()) + staking.MIGRATION_WINDOW();
    }

    /**
     * @dev First actor, starting at the seed, with an open stake, and the first open stake starting at the index seed
     */
    function _findOpenStake(uint256 _actorSeed, uint256 _indexSeed)
        internal
        view
        returns (address actor, uint64 index, bool found)
    {
        for (uint256 a = 0; a < NUM_ACTORS; a++) {
            actor = actors[(_actorSeed % NUM_ACTORS + a) % NUM_ACTORS];
            (uint64 count,,,,,) = staking.users(actor);
            for (uint64 i = 0; i < count; i++) {
                index = uint64((_indexSeed % count + i) % count);
                (bool unstaked,,,,,) = staking.stakeInfo(actor, index);
                if (!unstaked) return (actor, index, true);
            }
        }
        return (address(0), 0, false);
    }
}
