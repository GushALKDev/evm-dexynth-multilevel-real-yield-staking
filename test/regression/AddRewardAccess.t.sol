// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";

/**
 * @notice Round 1 finding 1: addStakingReward was permissionless and anyone could reschedule the stream, stretching
 *         the remaining rewards over a very long duration or compressing them into one second
 * @dev The first fix made addStakingReward owner only. Since rewards stream epoch by epoch, a deposit only adds to
 *      the next epoch and has no duration, so anyone can deposit again. These tests check that no deposit changes the
 *      rate or the end of the epoch already running
 */
contract AddRewardAccessTest is StakingFixture {
    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice Stretch PoC: a deposit in the middle of a funded epoch leaves its rate and end unchanged, and the epoch
     *         still pays its whole amount by its end, one settlement
     */
    function test_DepositCannotStretchRunningEpoch() public {
        _stake(alice, 1000 ether, 0);
        _fund(10_000 ether);
        vm.warp(START + 7 days);

        reward.mint(attacker, 1);
        vm.prank(attacker);
        staking.addStakingReward(1);

        // The deposit's pool update moves into epoch 0, which keeps the rate and end its own deposit set
        assertEq(staking.rewardRate(), uint256(10_000 ether) * 1e36 / EPOCH);
        assertEq(staking.nextEpochStart(), START + EPOCH);
        vm.warp(START + EPOCH);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, 10_000 ether);
        assertGe(pending, 10_000 ether - 1);
    }

    /**
     * @notice Compress PoC: an attacker stakes and deposits in the middle of a funded epoch, and the rewards left in
     *         it are still released at the same rate until its end
     */
    function test_DepositCannotCompressRunningEpoch() public {
        _stake(alice, 1000 ether, 0);
        _fund(10_000 ether);
        vm.warp(START + 1 days);
        _stake(attacker, 9000 ether, 0);
        uint256 rateBefore = staking.rewardRate();

        reward.mint(attacker, 1000 ether);
        vm.prank(attacker);
        staking.addStakingReward(1000 ether);

        assertEq(staking.rewardRate(), rateBefore);
        assertEq(staking.nextEpochStart(), START + EPOCH);
        assertEq(staking.queuedRewards(), uint256(1000 ether) * 1e36);
    }

    function test_AnyoneCanDeposit() public {
        reward.mint(attacker, 1000 ether);
        vm.prank(attacker);
        staking.addStakingReward(1000 ether);

        assertEq(staking.totalRewardsFunded(), 1000 ether);
        assertEq(staking.queuedRewards(), uint256(1000 ether) * 1e36);
        assertEq(reward.balanceOf(address(staking)), 1000 ether);
        assertEq(reward.balanceOf(attacker), 0);
    }
}
