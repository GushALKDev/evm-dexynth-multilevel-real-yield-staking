// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_3} from "../src/DexynthStaking.sol";

/**
 * @notice Full payload of every event, checked with vm.expectEmit (all topics and data)
 */
contract EventsTest is StakingFixture {
    function setUp() public {
        _deploy(18);
    }

    function test_DEXYStakedCarriesIndexAndLevel() public {
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.DEXYStaked(alice, 0, 3, 1000 ether);
        _stake(alice, 1000 ether, 3);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.DEXYStaked(alice, 1, 0, 5 ether);
        _stake(alice, 5 ether, 0);
    }

    function test_DEXYUnstakedCarriesIndexAndLevel() public {
        _stake(alice, 1000 ether, 0);
        _stake(alice, 2000 ether, 1);
        (,,, uint40 unlockTime,,) = staking.stakeInfo(alice, 1);
        vm.warp(unlockTime);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.DEXYUnstaked(alice, 1, 1, 2000 ether);
        vm.prank(alice);
        staking.unstake(1);
    }

    /**
     * @dev Single staker and a fully elapsed epoch: one settlement, so the payout is 100 tokens minus at most 1 wei.
     *      The event must carry exactly the amount transferred
     */
    function test_RewardsHarvestedOnHarvest() public {
        _stake(alice, 1000 ether, 0);
        _fund(100 ether);
        vm.warp(START + EPOCH);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, 100 ether);
        assertGe(pending, 100 ether - 1);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardsHarvested(alice, pending);
        vm.prank(alice);
        staking.harvest();
        assertEq(reward.balanceOf(alice), pending);
    }

    /**
     * @dev Same epoch, paid through unstake after it ends: RewardsHarvested comes before DEXYUnstaked, with the exact
     *      amounts
     */
    function test_RewardsHarvestedAndDEXYUnstakedOnUnstake() public {
        _stake(alice, 1000 ether, 0);
        _fund(100 ether);
        (,,, uint40 unlockTime,,) = staking.stakeInfo(alice, 0);
        assertGe(unlockTime, START + EPOCH);
        vm.warp(unlockTime);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, 100 ether);
        assertGe(pending, 100 ether - 1);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardsHarvested(alice, pending);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.DEXYUnstaked(alice, 0, 0, 1000 ether);
        vm.prank(alice);
        staking.unstake(0);
    }

    /**
     * @dev Before epoch 0 starts a deposit streams over epoch 0, during epoch 3 over epoch 4. Any account can deposit
     */
    function test_RewardAdded() public {
        reward.mint(alice, 2000 ether);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardAdded(alice, 0, 1000 ether);
        vm.prank(alice);
        staking.addStakingReward(1000 ether);

        vm.warp(START + 3 * EPOCH + 1 days);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardAdded(alice, 4, 1000 ether);
        vm.prank(alice);
        staking.addStakingReward(1000 ether);
    }

    function test_MigrationEvents() public {
        _fund(1000 ether);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.MigrationRequested(address(0xDEAD), uint40(block.timestamp + 30 days));
        staking.requestMigration(address(0xDEAD));

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.MigrationCancelled();
        staking.cancelMigration();

        staking.requestMigration(address(0xDEAD));
        vm.warp(block.timestamp + 30 days);
        // No stakers: epoch 0 ended unallocated and nothing is queued after it, all of it moves
        uint256 expected = EPOCH * (uint256(1000 ether) * 1e36 / EPOCH) / 1e36;
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardTokenMigrationSuccess(expected, address(0xDEAD));
        staking.executeMigration();
        assertEq(reward.balanceOf(address(0xDEAD)), expected);
        // Independent bound: the whole 1000 token epoch moves, floored once, so at most 1 wei less
        assertLe(expected, 1000 ether);
        assertGe(expected, 1000 ether - 1);
    }
}
