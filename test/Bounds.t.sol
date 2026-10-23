// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {StakingFixture} from "./utils/StakingFixture.sol";

/**
 * @notice Behaviour at the documented precision and overflow bounds of DexynthStakingV2_3
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
     * @dev Epoch 0 releases MAX_FUNDING minus less than EPOCH / 1e36 units, then the final floor removes at most
     *      1 unit. The upper bound is exact
     */
    function test_MaxFundingIsStreamedInFull() public {
        _stake(alice, 1000 ether, 2);
        _fund(MAX_FUNDING);
        vm.warp(START + EPOCH);
        vm.prank(alice);
        staking.harvest();
        assertLe(reward.balanceOf(alice), MAX_FUNDING);
        assertGe(reward.balanceOf(alice), MAX_FUNDING - 1);
    }

    function test_RevertWhen_FundingAboveMax() public {
        reward.mint(owner, MAX_FUNDING + 1);
        vm.expectRevert(FUNDING_CAP_EXCEEDED);
        staking.addStakingReward(MAX_FUNDING + 1);
    }

    function test_RevertWhen_CumulativeFundingAboveMax() public {
        _fund(MAX_FUNDING);
        reward.mint(owner, 1);
        vm.expectRevert(FUNDING_CAP_EXCEEDED);
        staking.addStakingReward(1);
    }

    /**
     * @notice Smallest boosted stake (1 unit) alone for half of a maximum epoch, then a large staker joins
     * @dev During the first half the accumulator grows by half the scaled reward divided by 1, about 1.7e74, the
     *      largest increase the funding cap allows. Conservation is checked exactly
     */
    function test_MinBoostedStakeWithMaxFunding() public {
        _stake(alice, 2, 0); // 2 * 0.65 floors to 1 boosted unit
        _fund(MAX_FUNDING);
        vm.warp(START + EPOCH / 2);
        _stake(bob, 1_000_000 ether, 2);
        vm.warp(START + EPOCH);

        vm.prank(alice);
        staking.harvest();
        vm.prank(bob);
        staking.harvest();

        // First half: alice alone receives half. Second half: alice holds 1 of 1 + 1e24 boosted units. Exact shares:
        // alice MAX * (B + 2) / (2 * (B + 1)) and bob MAX * B / (2 * (B + 1)), rounded down here. A payout can only be
        // below its exact share: by less than 1 unit from its one settlement plus less than 1e-12 units from the rate
        // and accumulator truncations, so at most 1 unit below the rounded-down share and never above it
        uint256 bobBoosted = 1_000_000 ether;
        uint256 exactAlice = Math.mulDiv(MAX_FUNDING, bobBoosted + 2, 2 * (bobBoosted + 1));
        uint256 exactBob = Math.mulDiv(MAX_FUNDING, bobBoosted, 2 * (bobBoosted + 1));
        uint256 a = reward.balanceOf(alice);
        uint256 b = reward.balanceOf(bob);
        assertLe(a, exactAlice);
        assertGe(a, exactAlice - 1);
        assertLe(b, exactBob);
        assertGe(b, exactBob - 1);
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

        _fund(1000 ether);
        vm.warp(START + EPOCH);
        vm.prank(alice);
        staking.harvest();
        // Accumulator truncation per update is below totalBoostedStake / 1e36, about 2.2e2 wei here, plus 1 wei
        // from the final floor, so alice receives at least 1000 tokens minus 222 wei and never more than funded
        assertLe(reward.balanceOf(alice), 1000 ether);
        assertGe(reward.balanceOf(alice), 1000 ether - 222);
    }

    /**
     * @notice At 1.35x the largest accepted amount is the one whose boosted amount is type(uint128).max, one more
     *         DEXY unit crosses the limit
     * @dev limit = ceil(2^128 * 1e10 / 1.35e10) is the smallest amount with a boosted amount of at least 2^128
     */
    function test_RevertWhen_BoostedAmountExceedsUint128() public {
        uint256 limit = Math.ceilDiv((uint256(type(uint128).max) + 1) * 1e10, 13500000000);
        dexy.mint(alice, limit);
        dexy.mint(bob, limit);

        // limit - 1 at 1.35x has a boosted amount of at most type(uint128).max and is accepted
        _stake(alice, limit - 1, 4);
        assertEq(staking.totalBoostedStake(), (limit - 1) * 13500000000 / 1e10);
        assertLe(staking.totalBoostedStake(), type(uint128).max);

        // limit has a boosted amount of at least 2^128 and reverts
        vm.prank(bob);
        vm.expectRevert("SafeCast: value doesn't fit in 128 bits");
        staking.stake(limit, 4);
    }

    function test_RevertWhen_StakeAmountExceedsUint128() public {
        uint256 amount = uint256(type(uint128).max) + 1;
        dexy.mint(alice, amount);
        vm.prank(alice);
        vm.expectRevert("SafeCast: value doesn't fit in 128 bits");
        staking.stake(amount, 0);
    }
}
