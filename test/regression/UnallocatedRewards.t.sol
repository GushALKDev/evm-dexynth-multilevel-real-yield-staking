// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegressionBase} from "./RegressionBase.sol";

/**
 * @notice Round 1 finding 4: rewards streamed while totalBoostedStake was zero stayed in the contract
 *         with no claimant, including when the only stake had a boosted amount of zero
 */
contract UnallocatedRewardsTest is RegressionBase {
    bytes4 internal constant ZERO_BOOSTED_STAKE = bytes4(keccak256("ZeroBoostedStake()"));

    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice Half of a stream elapses with no stakers, then the owner starts a new stream with no new funds
     * @dev The first 15 days are unallocated and rolled into the second stream, so alice ends up with the
     *      full 10,000 tokens. Each of the two harvests floors the accumulator product once, and the scaled
     *      rate loses less than 1e-30 wei per stream, so the total is at most 2 wei below 10,000 tokens.
     *      The upper bound is exact: alice can never receive more than was funded.
     */
    function test_RewardsStreamedWithNoStakersAreRolledIntoNextStream() public {
        _fund(10_000 ether, 30 days);
        vm.warp(block.timestamp + 15 days);
        _stake(alice, 1000 ether, 0);
        vm.warp(block.timestamp + 60 days);
        vm.prank(alice);
        staking.harvest();

        staking.addStakingReward(0, 30 days);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        staking.harvest();

        uint256 received = reward.balanceOf(alice);
        assertLe(received, 10_000 ether);
        assertGe(received, 10_000 ether - 2);
    }

    /**
     * @notice The skipped part of the stream is recorded exactly and cleared when it is rolled over
     * @dev 15 of 30 days elapse with no stakers, so unallocatedRewards is exactly 15 days times the scaled rate
     */
    function test_UnallocatedRewardsAreTrackedExactly() public {
        _fund(10_000 ether, 30 days);
        uint256 rate = staking.rewardRate();
        vm.warp(block.timestamp + 15 days);
        _stake(alice, 1000 ether, 0);
        assertEq(staking.unallocatedRewards(), 15 days * rate);

        staking.addStakingReward(0, 30 days);
        assertEq(staking.unallocatedRewards(), 0);
        assertEq(staking.rewardRate(), (15 days * rate + 15 days * rate) / 30 days);
    }

    /**
     * @notice 1 wei at a 0.65x level has a boosted amount of zero, which used to stop the stream silently
     */
    function test_RevertWhen_StakeHasZeroBoostedAmount() public {
        vm.prank(alice);
        vm.expectRevert(ZERO_BOOSTED_STAKE);
        staking.stake(1, 0);
    }

    /**
     * @notice Smallest stake with a non-zero boosted amount at the lowest multiplier
     * @dev 2 * 0.65 = 1.3, floored to 1 boosted unit
     */
    function test_SmallestNonZeroBoostedStakeIsAccepted() public {
        _stake(alice, 2, 0);
        assertEq(staking.totalBoostedStake(), 1);
    }
}
