// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";

/**
 * @notice Round 1 finding 1: addStakingReward was permissionless and anyone could reschedule the stream
 */
contract AddRewardAccessTest is StakingFixture {
    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice Stretch PoC: a non-owner tries to spread the remaining rewards over the maximum duration
     */
    function test_RevertWhen_NonOwnerStretchesStream() public {
        _stake(alice, 1000 ether, 0);
        _fund(10_000 ether, 30 days);
        vm.warp(block.timestamp + 15 days + 1);
        uint256 rateBefore = staking.rewardRate();
        uint256 maxDuration = uint256(type(uint40).max) - block.timestamp;

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.addStakingReward(0, maxDuration);

        assertEq(staking.rewardRate(), rateBefore);
    }

    /**
     * @notice Compress PoC: a non-owner stakes and tries to release all remaining rewards in one second
     */
    function test_RevertWhen_NonOwnerCompressesStream() public {
        _stake(alice, 1000 ether, 0);
        vm.warp(block.timestamp + 15 days);
        _fund(10_000 ether, 30 days);
        vm.warp(block.timestamp + 1 days);
        _stake(attacker, 9000 ether, 0);
        uint256 endBefore = staking.rewardEndTime();

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.addStakingReward(0, 1);

        assertEq(staking.rewardEndTime(), endBefore);
    }

    function test_RevertWhen_NonOwnerAddsFundedRewards() public {
        reward.mint(attacker, 1000 ether);
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.addStakingReward(1000 ether, 30 days);
    }
}
