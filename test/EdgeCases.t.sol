// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_2} from "../src/DexynthStaking.sol";

/**
 * @notice Timing edge cases around rewardEndTime, stream restarts and the unlock second
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
     * @dev alice alone for the whole stream, harvest exactly at rewardEndTime: the full amount, one settlement.
     *      One second later nothing more has been streamed
     */
    function test_HarvestExactlyAtRewardEndTime() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING, 10 days);
        vm.warp(staking.rewardEndTime());

        vm.prank(alice);
        staking.harvest();
        _assertReward(reward.balanceOf(alice), FUNDING, 1);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(DexynthStakingV2_2.NoRewardsToHarvest.selector);
        staking.harvest();
    }

    /**
     * @dev A stake made exactly at rewardEndTime earns nothing from the finished stream, the earlier staker keeps it
     */
    function test_StakeExactlyAtRewardEndTime() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING, 10 days);
        vm.warp(staking.rewardEndTime());
        _stake(bob, 1000 ether, 0);

        vm.warp(block.timestamp + 5 days);
        assertEq(staking.pendingRewards(bob), 0);
        _assertReward(staking.pendingRewards(alice), FUNDING, 1);
    }

    /**
     * @dev Second funding 4 of 10 days into a stream: the 6 unstreamed days are spread with the new amount over the
     *      new 10 days. alice alone receives both fundings in full after the second stream ends, with one
     *      settlement (funding updates the pool but does not settle users)
     */
    function test_AddStakingRewardWhileStreamRuns() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING, 10 days);
        uint256 rate1 = staking.rewardRate();
        vm.warp(block.timestamp + 4 days);

        _fund(FUNDING, 10 days);
        assertEq(staking.rewardRate(), (6 days * rate1 + FUNDING * 1e36) / 10 days);
        assertEq(staking.rewardEndTime(), block.timestamp + 10 days);

        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        staking.harvest();
        _assertReward(reward.balanceOf(alice), 2 * FUNDING, 1);
    }

    /**
     * @dev Funding exactly at rewardEndTime: nothing is left of the first stream, the new rate only carries the new amount
     */
    function test_AddStakingRewardExactlyWhenStreamEnds() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING, 10 days);
        vm.warp(staking.rewardEndTime());

        _fund(FUNDING, 10 days);
        assertEq(staking.rewardRate(), FUNDING * 1e36 / 10 days);
    }

    /**
     * @dev Funding 100 days after the first stream ended: the gap streams nothing, the new stream starts at the funding
     *      block, and alice alone ends with both fundings, one settlement per harvest
     */
    function test_AddStakingRewardLongAfterStreamEnds() public {
        _stake(alice, 1000 ether, 0);
        _fund(FUNDING, 10 days);
        vm.warp(block.timestamp + 110 days);

        vm.prank(alice);
        staking.harvest();
        _assertReward(reward.balanceOf(alice), FUNDING, 1);

        _fund(FUNDING, 10 days);
        assertEq(staking.rewardRate(), FUNDING * 1e36 / 10 days);
        assertEq(staking.rewardEndTime(), block.timestamp + 10 days);
        vm.warp(block.timestamp + 5 days);
        _assertReward(staking.pendingRewards(alice), Math.mulDiv(FUNDING, 5, 10), 1);
    }

    /**
     * @dev With no stakers when the stream ends, the whole stream is unallocated and the next funding carries it
     */
    function test_AddStakingRewardAfterUnstakedStreamCarriesItOver() public {
        _fund(FUNDING, 10 days);
        vm.warp(block.timestamp + 20 days);

        _fund(FUNDING, 10 days);
        uint256 rate = staking.rewardRate();
        // unallocated: 10 days * (FUNDING * 1e36 / 10 days), then (unallocated + FUNDING * 1e36) / 10 days
        assertEq(rate, (10 days * (FUNDING * 1e36 / 10 days) + FUNDING * 1e36) / 10 days);
        assertEq(staking.unallocatedRewards(), 0);
    }
}
