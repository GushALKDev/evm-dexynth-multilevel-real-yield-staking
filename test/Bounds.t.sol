// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {StakingFixture} from "./utils/StakingFixture.sol";

/**
 * @notice Behaviour at the documented precision and overflow bounds of DexynthStakingV2_2
 * @dev Rewards funded over the life of the contract are capped at type(uint128).max units
 */
contract BoundsTest is StakingFixture {
    uint256 internal constant MAX_FUNDING = type(uint128).max;
    bytes4 internal constant FUNDING_CAP_EXCEEDED = bytes4(keccak256("FundingCapExceeded()"));

    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice The largest funding is accepted and paid in full to a single staker
     * @dev The stream releases MAX_FUNDING minus less than 1 day / 1e36 units, then the final floor removes at most
     *      1 unit. The upper bound is exact
     */
    function test_MaxFundingIsStreamedInFull() public {
        _stake(alice, 1000 ether, 2);
        _fund(MAX_FUNDING, 1 days);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.harvest();
        assertLe(reward.balanceOf(alice), MAX_FUNDING);
        assertGe(reward.balanceOf(alice), MAX_FUNDING - 1);
    }

    function test_RevertWhen_FundingAboveMax() public {
        reward.mint(owner, MAX_FUNDING + 1);
        vm.expectRevert(FUNDING_CAP_EXCEEDED);
        staking.addStakingReward(MAX_FUNDING + 1, 1 days);
    }

    function test_RevertWhen_CumulativeFundingAboveMax() public {
        _fund(MAX_FUNDING, 1 days);
        reward.mint(owner, 1);
        vm.expectRevert(FUNDING_CAP_EXCEEDED);
        staking.addStakingReward(1, 1 days);
    }

    /**
     * @notice Smallest boosted stake (1 unit) alone for half of a maximum stream, then a large staker joins
     * @dev During the first day the accumulator grows by the whole scaled reward divided by 1, about 1.7e74, the
     *      largest increase the funding cap allows. Conservation is checked exactly
     */
    function test_MinBoostedStakeWithMaxFunding() public {
        _stake(alice, 2, 0); // 2 * 0.65 floors to 1 boosted unit
        _fund(MAX_FUNDING, 2 days);
        vm.warp(block.timestamp + 1 days);
        _stake(bob, 1_000_000 ether, 2);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.harvest();
        vm.prank(bob);
        staking.harvest();

        // Day 1: alice alone receives half. Day 2: alice holds 1 of 1 + 1e24 boosted units
        uint256 half = MAX_FUNDING / 2;
        uint256 bobBoosted = 1_000_000 ether;
        uint256 expectedAlice = half + half / (1 + bobBoosted);
        uint256 expectedBob = half * bobBoosted / (1 + bobBoosted);
        uint256 a = reward.balanceOf(alice);
        uint256 b = reward.balanceOf(bob);
        // 3 units: the rate truncation (below 1 unit per day), the accumulator truncation (below 1e24 / 1e36 units
        // per update) and the final floor of each payout (below 1 unit), plus the rounding of the expected values
        assertApproxEqAbs(a, expectedAlice, 3);
        assertApproxEqAbs(b, expectedBob, 3);
        assertLe(a + b, MAX_FUNDING);
        assertEq(a + b + reward.balanceOf(address(staking)), MAX_FUNDING);
    }

    /**
     * @notice The largest stake amount, type(uint128).max, is accepted where its boosted amount fits in uint128
     */
    function test_MaxStakeAmountAtSubUnitMultiplier() public {
        uint256 amount = type(uint128).max;
        dexy.mint(alice, amount);
        _stake(alice, amount, 0);
        assertEq(staking.totalBoostedStake(), amount * 6500000000 / 1e10);

        _fund(1000 ether, 1 days);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.harvest();
        // Accumulator truncation per update is below totalBoostedStake / 1e36, about 2.2e2 wei here, plus 1 wei
        // from the final floor, so alice receives at least 1000 tokens minus 222 wei and never more than funded
        assertLe(reward.balanceOf(alice), 1000 ether);
        assertGe(reward.balanceOf(alice), 1000 ether - 222);
    }

    function test_RevertWhen_BoostedAmountExceedsUint128() public {
        uint256 amount = type(uint128).max;
        dexy.mint(alice, amount);
        vm.prank(alice);
        vm.expectRevert("SafeCast: value doesn't fit in 128 bits");
        staking.stake(amount, 4);
    }

    function test_RevertWhen_StakeAmountExceedsUint128() public {
        uint256 amount = uint256(type(uint128).max) + 1;
        dexy.mint(alice, amount);
        vm.prank(alice);
        vm.expectRevert("SafeCast: value doesn't fit in 128 bits");
        staking.stake(amount, 0);
    }
}
