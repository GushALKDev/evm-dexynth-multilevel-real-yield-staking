// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_3} from "../src/DexynthStaking.sol";

/**
 * @notice Griefing and extraction vectors, measured with the example configuration
 */
contract GriefingTest is StakingFixture {
    uint256 internal constant EPOCH_FUNDING = 1_000_000e6; // 1,000,000 tokens with 6 decimals

    /**
     * @notice An attacker forces a pool update every 12 seconds for one day with 2 wei stakes
     * @dev Honest stake: 100M DEXY at 1.0x, 1e26 boosted units. Each update truncates the accumulator by less than
     *      totalBoostedStake / 1e36 = 1e-10 reward units, so 7200 updates lose less than 7.2e-7 units and a year
     *      of 2,628,000 updates less than 2.7e-4 units. The attacker's 7200 boosted units move alice's share by
     *      less than 7200 / 1e26 of the epoch. Exact expectation: 1,000,000e6 * 1 day / 15 days =
     *      66,666,666,666.67 units, floored to 66,666,666,666, the same as with no forced updates
     */
    function test_FrequentUpdatesLoseNoWholeUnit() public {
        _deploy(6);
        _stake(alice, 100_000_000 ether, 2);
        _fund(EPOCH_FUNDING);
        uint256 snap = vm.snapshotState();

        vm.warp(START + 1 days);
        uint256 withoutUpdates = staking.pendingRewards(alice);

        vm.revertToState(snap);
        for (uint256 t = 12; t <= 1 days; t += 12) {
            vm.warp(START + t);
            _stake(attacker, 2, 0);
        }
        uint256 withUpdates = staking.pendingRewards(alice);

        uint256 exact = EPOCH_FUNDING * 1 days / EPOCH;
        assertEq(withoutUpdates, exact);
        assertEq(withUpdates, exact);
    }

    /**
     * @notice A 2 wei stake at 0.65x (1 boosted unit) is alone when a funded epoch starts, and collects it until
     *         someone else stakes
     * @dev Without the dust stake these rewards would go to unallocatedRewards and be rolled into the next deposit.
     *      Day 1: the attacker alone receives 10,000 / 15 tokens. Days 2 to 15: 1 of 1 + 1e21 boosted units.
     *      Each harvest floors once (below 1 wei)
     */
    function test_DustStakeCollectsEpochWhileAlone() public {
        _deploy(18);
        _stake(attacker, 2, 0);
        _fund(10_000 ether);
        vm.warp(START + 1 days);
        _stake(bob, 1000 ether, 2);

        vm.prank(attacker);
        staking.harvest();
        uint256 dayOne = Math.mulDiv(10_000 ether, 1 days, EPOCH);
        assertLe(reward.balanceOf(attacker), dayOne);
        assertGe(reward.balanceOf(attacker), dayOne - 1);
        assertEq(staking.unallocatedRewards(), 0);

        // Rest of the epoch: the dust stake earns 14 days * rate / (1 + 1e21) per boosted unit, below 1e-17 of it
        vm.warp(START + EPOCH);
        uint256 rest = staking.pendingRewards(attacker);
        assertEq(rest, Math.mulDiv(10_000 ether, EPOCH - 1 days, EPOCH) / (1 + 1000 ether));
    }

    /**
     * @notice Just-in-time stake of 9,000 DEXY at level 0 one second before a funded epoch starts
     * @dev The deposit is public before its epoch starts (queuedRewards and RewardAdded), so anyone can time a stake.
     *      The honest staker has 1,000 DEXY at 1.0x (1000 boosted), the attacker 9,000 at 0.65x (5850 boosted), so
     *      the attacker's exact share is 10,000 * 5850 / 6850 tokens, claimable after the epoch. The lock is what the
     *      attack costs: the principal stays locked for 30 days, two 15 day epochs, sharing the next one too
     */
    function test_JustInTimeStakeBeforeEpochStart() public {
        _deploy(18);
        _stake(bob, 1000 ether, 2);
        _fund(10_000 ether);
        vm.warp(START - 1);
        _stake(attacker, 9000 ether, 0);
        vm.warp(START + EPOCH);

        vm.prank(attacker);
        staking.harvest();
        uint256 share = Math.mulDiv(10_000 ether, 5850, 6850);
        assertLe(reward.balanceOf(attacker), share);
        assertGe(reward.balanceOf(attacker), share - 1);

        (,, uint40 stakedAt, uint40 unlockTime,,) = staking.stakeInfo(attacker, 0);
        assertEq(unlockTime - stakedAt, 30 days);
        vm.warp(unlockTime - 1);
        vm.prank(attacker);
        vm.expectRevert(DexynthStakingV2_3.StakeStillLocked.selector);
        staking.unstake(0);
    }

    /**
     * @notice The lock does not depend on where the stake falls in its epoch: just before or just after a boundary,
     *         it is exactly the level's lockingPeriod
     */
    function test_LockIsIndependentOfEpochBoundary() public {
        _deploy(18);
        uint256 boundary = START + EPOCH;
        vm.warp(boundary - 1);
        _stake(attacker, 1000 ether, 0);
        vm.warp(boundary + 1);
        _stake(attacker, 1000 ether, 0);

        (,, uint40 stakedBefore, uint40 unlockBefore,,) = staking.stakeInfo(attacker, 0);
        (,, uint40 stakedAfter, uint40 unlockAfter,,) = staking.stakeInfo(attacker, 1);
        assertEq(unlockBefore - stakedBefore, 30 days);
        assertEq(unlockAfter - stakedAfter, 30 days);
    }
}
