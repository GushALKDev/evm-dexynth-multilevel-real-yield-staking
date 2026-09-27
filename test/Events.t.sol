// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_2} from "../src/DexynthStaking.sol";

/**
 * @notice Full payload of every event, checked with vm.expectEmit (all topics and data)
 */
contract EventsTest is StakingFixture {
    function setUp() public {
        _deploy(18);
    }

    function test_DEXYStakedCarriesIndexAndLevel() public {
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.DEXYStaked(alice, 0, 3, 1000 ether);
        _stake(alice, 1000 ether, 3);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.DEXYStaked(alice, 1, 0, 5 ether);
        _stake(alice, 5 ether, 0);
    }

    function test_DEXYUnstakedCarriesIndexAndLevel() public {
        _stake(alice, 1000 ether, 0);
        _stake(alice, 2000 ether, 1);
        (,,, uint40 unlockTime,,) = staking.stakeInfo(alice, 1);
        vm.warp(unlockTime);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.DEXYUnstaked(alice, 1, 1, 2000 ether);
        vm.prank(alice);
        staking.unstake(1);
    }

    /**
     * @dev Single staker and a fully elapsed stream: one settlement, so the payout is 100 tokens minus at most 1 wei.
     *      The event must carry exactly the amount transferred
     */
    function test_RewardsHarvestedOnHarvest() public {
        _stake(alice, 1000 ether, 0);
        _fund(100 ether, 10 days);
        vm.warp(block.timestamp + 10 days);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, 100 ether);
        assertGe(pending, 100 ether - 1);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.RewardsHarvested(alice, pending);
        vm.prank(alice);
        staking.harvest();
        assertEq(reward.balanceOf(alice), pending);
    }

    /**
     * @dev Same stream, paid through unstake: RewardsHarvested comes before DEXYUnstaked, with the exact amounts
     */
    function test_RewardsHarvestedAndDEXYUnstakedOnUnstake() public {
        _stake(alice, 1000 ether, 0);
        _fund(100 ether, 10 days);
        (,,, uint40 unlockTime,,) = staking.stakeInfo(alice, 0);
        vm.warp(unlockTime);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, 100 ether);
        assertGe(pending, 100 ether - 1);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.RewardsHarvested(alice, pending);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.DEXYUnstaked(alice, 0, 0, 1000 ether);
        vm.prank(alice);
        staking.unstake(0);
    }

    function test_RewardAdded() public {
        reward.mint(owner, 1000 ether);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.RewardAdded(1000 ether, 30 days, uint256(1000 ether) * 1e36 / 30 days);
        staking.addStakingReward(1000 ether, 30 days);
    }

    function test_MigrationEvents() public {
        _fund(1000 ether, 60 days);

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.MigrationRequested(address(0xDEAD), uint40(block.timestamp + 30 days));
        staking.requestMigration(address(0xDEAD));

        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.MigrationCancelled();
        staking.cancelMigration();

        staking.requestMigration(address(0xDEAD));
        vm.warp(block.timestamp + 30 days);
        // No stakers: the elapsed 30 days are unallocated and the other 30 unstreamed, all of it moves
        uint256 expected = (30 days * staking.rewardRate() + 30 days * staking.rewardRate()) / 1e36;
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_2.RewardTokenMigrationSuccess(expected, address(0xDEAD));
        staking.executeMigration();
        assertEq(reward.balanceOf(address(0xDEAD)), expected);
        // Independent bound: the whole 1000 token stream moves, floored once, so at most 1 wei less
        assertLe(expected, 1000 ether);
        assertGe(expected, 1000 ether - 1);
    }
}
