// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_3} from "../src/DexynthStaking.sol";

/**
 * @notice Timing edge cases around epoch boundaries, deposits during a running epoch and the unlock second
 * @dev Reward checks allow the payout to be below the exact value by the number of settlements stated in each
 *      test (one floor each, below 1 wei), never above it. The unstake bounds at unlockTime - 1 and unlockTime are
 *      also covered by testUnstakeLocked and testFuzz_Unstake, and the value bounds by test/Bounds.t.sol
 */
contract EdgeCasesTest is StakingFixture {
    uint256 internal constant FUNDING = 1000 ether;

    function setUp() public {
        _deploy(18);
    }

    function _assertReward(uint256 _actual, uint256 _exact, uint256 _maxLoss) internal pure {
        assertLe(_actual, _exact);
        assertGe(_actual + _maxLoss, _exact);
    }

    /**
     * @dev A stake made before epoch 0 starts earns nothing until it starts, then its share of the epoch's rate
     */
    function test_StakeBeforeFirstEpochEarnsFromItsStart() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING);

        vm.warp(START - 1);
        assertEq(staking.pendingRewards(alice), 0);
        vm.warp(START + 1 days);
        _assertReward(staking.pendingRewards(alice), Math.mulDiv(FUNDING, 1 days, EPOCH), 1);
    }

    /**
     * @dev alice alone for the whole epoch, harvest exactly at its end: the full amount, one settlement. One second
     *      later nothing more has been streamed
     */
    function test_HarvestExactlyAtEpochEnd() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING);
        vm.warp(START + EPOCH);

        vm.prank(alice);
        staking.harvest();
        _assertReward(reward.balanceOf(alice), FUNDING, 1);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(DexynthStakingV2_3.NoRewardsToHarvest.selector);
        staking.harvest();
    }

    /**
     * @dev A stake made exactly when the funded epoch ends earns nothing from it, the earlier staker keeps it
     */
    function test_StakeExactlyAtEpochEnd() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING);
        vm.warp(START + EPOCH);
        _stake(bob, 1000 ether, 0);

        vm.warp(block.timestamp + 5 days);
        assertEq(staking.pendingRewards(bob), 0);
        _assertReward(staking.pendingRewards(alice), FUNDING, 1);
    }

    /**
     * @dev A deposit 4 days into epoch 0 is queued for epoch 1 and leaves epoch 0's rate unchanged. alice alone
     *      receives both deposits in full once epoch 1 ends, with one settlement (deposits update the pool but do not
     *      settle users)
     */
    function test_DepositDuringEpochDoesNotChangeItsRate() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING);
        vm.warp(START + 4 days);

        _fund(FUNDING);
        assertEq(staking.rewardRate(), FUNDING * 1e36 / EPOCH);
        assertEq(staking.nextEpochStart(), START + EPOCH);
        assertEq(staking.queuedRewards(), FUNDING * 1e36);
        _assertReward(staking.pendingRewards(alice), Math.mulDiv(FUNDING, 4 days, EPOCH), 1);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        staking.harvest();
        _assertReward(reward.balanceOf(alice), 2 * FUNDING, 1);
    }

    /**
     * @dev A deposit exactly at the start of an epoch goes to the next one: the pool moves into the starting epoch
     *      before the deposit is queued
     */
    function test_DepositExactlyAtEpochStart() public {
        _fund(FUNDING);
        vm.warp(START);

        reward.mint(owner, FUNDING);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardAdded(owner, 1, FUNDING);
        staking.addStakingReward(FUNDING);
        assertEq(staking.rewardRate(), FUNDING * 1e36 / EPOCH);
        assertEq(staking.queuedRewards(), FUNDING * 1e36);
        assertEq(staking.nextEpochStart(), START + EPOCH);
    }

    /**
     * @dev No update for 110 days after a funded epoch 0: the epochs after it stream nothing, the next deposit
     *      streams over the next epoch to start, and alice alone ends with both deposits, one settlement per harvest
     */
    function test_DepositLongAfterLastEpochEnds() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING);
        vm.warp(START + 110 days);

        vm.prank(alice);
        staking.harvest();
        _assertReward(reward.balanceOf(alice), FUNDING, 1);
        // 110 days is 7 epochs and 5 days: epoch 7 runs with nothing to stream
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.nextEpochStart(), START + 8 * EPOCH);

        _fund(FUNDING);
        vm.warp(START + 8 * EPOCH + EPOCH / 2);
        _assertReward(staking.pendingRewards(alice), FUNDING / 2, 1);
    }

    /**
     * @dev With no stakers, the whole epoch is unallocated and the next deposit carries it
     */
    function test_UnallocatedEpochRollsIntoNextDeposit() public {
        _fund(FUNDING);
        vm.warp(START + 2 * EPOCH);

        _fund(FUNDING);
        assertEq(staking.unallocatedRewards(), 0);
        assertEq(staking.queuedRewards(), EPOCH * (FUNDING * 1e36 / EPOCH) + FUNDING * 1e36);
    }
}
