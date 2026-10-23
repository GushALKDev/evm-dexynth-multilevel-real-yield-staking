// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";

/**
 * @notice Round 1 finding 4: rewards streamed while totalBoostedStake was zero stayed in the contract
 *         with no claimant, including when the only stake had a boosted amount of zero
 */
contract UnallocatedRewardsTest is StakingFixture {
    bytes4 internal constant ZERO_BOOSTED_STAKE = bytes4(keccak256("ZeroBoostedStake()"));

    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice Half of an epoch elapses with no stakers, then the next deposit carries that half
     * @dev The first half of epoch 0 is unallocated and joins the 1,000 tokens deposited for epoch 2, so alice ends
     *      up with the full 11,000 tokens. Each of the two harvests floors the accumulator product once, and the
     *      scaled rate loses less than 1e-30 wei per epoch, so the total is at most 2 wei below 11,000 tokens. The
     *      upper bound is exact: alice can never receive more than was funded.
     */
    function test_RewardsStreamedWithNoStakersAreRolledIntoNextDeposit() public {
        _fund(10_000 ether);
        vm.warp(START + EPOCH / 2);
        _stake(alice, 1000 ether, 0);
        vm.warp(START + EPOCH);
        vm.prank(alice);
        staking.harvest();

        _fund(1_000 ether);
        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        staking.harvest();

        uint256 received = reward.balanceOf(alice);
        assertLe(received, 11_000 ether);
        assertGe(received, 11_000 ether - 2);
    }

    /**
     * @notice The skipped part of the epoch is recorded exactly and cleared when the next deposit carries it
     * @dev Half of epoch 0 elapses with no stakers, so unallocatedRewards is exactly EPOCH / 2 times its scaled rate
     */
    function test_UnallocatedRewardsAreTrackedExactly() public {
        _fund(10_000 ether);
        uint256 rate = uint256(10_000 ether) * 1e36 / EPOCH;
        vm.warp(START + EPOCH / 2);
        _stake(alice, 1000 ether, 0);
        assertEq(staking.rewardRate(), rate);
        assertEq(staking.unallocatedRewards(), EPOCH / 2 * rate);

        _fund(1 ether);
        assertEq(staking.unallocatedRewards(), 0);
        assertEq(staking.queuedRewards(), EPOCH / 2 * rate + uint256(1 ether) * 1e36);
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
