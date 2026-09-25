// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";

/**
 * @notice Round 1 finding 2: with a 6-decimal reward token, rewardRate truncation and the per-update
 *         accumulator truncation lost rewards, down to zero when the pool was updated every block
 */
contract RewardPrecisionTest is StakingFixture {
    uint256 internal constant FUNDING = 1000e6; // 1000 tokens with 6 decimals

    function setUp() public {
        _deploy(6);
        _stake(alice, 10_000_000 ether, 0);
        vm.warp(block.timestamp + EPOCH); // alice is past rewardStartTime
    }

    /**
     * @notice Pool updated every 12 seconds for one day by 1 wei stakes at a 1.0x level
     * @dev Exact expectation: FUNDING * 1 days / 30 days = 33,333,333.33 units. Bob's boosted stake reaches
     *      7200 wei against alice's 6.5e24, which moves alice's share by less than 1e-13 units. Each pool update
     *      truncates the accumulator by less than aliceBoosted / 1e36 units, 6.5e-12, so 7200 updates lose less
     *      than 1e-7 units. The floor of 33,333,333.33 is therefore exactly 33,333,333, with no tolerance.
     */
    function test_FrequentUpdatesDoNotRoundRewardsToZero() public {
        _fund(FUNDING, 30 days);
        uint256 start = block.timestamp;
        for (uint256 t = 12; t <= 1 days; t += 12) {
            vm.warp(start + t);
            _stake(bob, 1, 2);
        }
        assertEq(staking.pendingRewards(alice), FUNDING * 1 days / 30 days);
    }

    /**
     * @notice Full 30 day stream with a single staker
     * @dev rewardRate keeps 36 extra decimals, so the stream releases FUNDING minus less than 30 days / 1e36
     *      units. The final floor turns that into FUNDING - 1. The upper bound is exact: the staker can never
     *      receive more than was funded.
     */
    function test_RateTruncationLosesAtMostOneUnit() public {
        _fund(FUNDING, 30 days);
        vm.warp(block.timestamp + 30 days);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, FUNDING);
        assertGe(pending, FUNDING - 1);
    }
}
