// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV1} from "../../bench/DexynthStakingV1.sol";
import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @notice Differential check of v1 (original Dexynth contract, bench/) against v2.2 on how rewards are shared
 * @dev Absolute payouts are not comparable: v1 releases rewards per closed epoch at a rate computed when the
 *      epochs are closed (accRewards divided by the seconds since the last closed epoch), while v2.2 streams a
 *      funded amount over a chosen duration. What both must agree on is the split: with a constant set of stakes,
 *      every user receives total * boosted / totalBoosted. This test aligns both versions on the same stakes and
 *      compares each user's share of the total paid by each version.
 */
contract V1SharesTest is Test {
    uint256 internal constant EPOCH = 15 days;
    uint256 internal constant REWARDED_EPOCHS = 10;
    // Boosted units: 1000 * 0.65, 1000 * 1.0, 2000 * 1.35
    uint256[3] internal boosted = [uint256(650), 1000, 2700];
    uint256 internal constant TOTAL_BOOSTED = 4350;

    address[3] internal users = [address(0xA), address(0xB), address(0xC)];
    uint256[3] internal amounts = [uint256(1000 ether), 1000 ether, 2000 ether];
    uint8[3] internal levelIds = [0, 2, 4];

    DexynthStakingV1 internal v1;
    DexynthStakingV2_2 internal v2;
    MockERC20 internal reward;

    function setUp() public {
        vm.warp(2_000_000_000);
        MockERC20 dexy = new MockERC20("Dexy Token", "DEXY", 18);
        reward = new MockERC20("Reward Token", "RWD", 18);

        DexynthStakingV1.Level[5] memory levelsV1 = [
            DexynthStakingV1.Level(2592000, 6500000000),
            DexynthStakingV1.Level(7776000, 8500000000),
            DexynthStakingV1.Level(15552000, 10000000000),
            DexynthStakingV1.Level(31536000, 11500000000),
            DexynthStakingV1.Level(62208000, 13500000000)
        ];
        v1 = new DexynthStakingV1(address(dexy), address(reward), levelsV1, EPOCH);

        DexynthStakingV2_2.Level[] memory levelsV2 = new DexynthStakingV2_2.Level[](5);
        for (uint256 i = 0; i < 5; i++) {
            levelsV2[i] = DexynthStakingV2_2.Level(uint32(levelsV1[i].lockingPeriod), uint64(levelsV1[i].boostP), 0);
        }
        v2 = new DexynthStakingV2_2(address(dexy), address(reward), levelsV2, EPOCH);

        for (uint256 i = 0; i < 3; i++) {
            dexy.mint(users[i], 2 * amounts[i]);
            vm.startPrank(users[i]);
            dexy.approve(address(v1), type(uint256).max);
            dexy.approve(address(v2), type(uint256).max);
            v1.stake(amounts[i], levelIds[i]);
            v2.stake(amounts[i], levelIds[i]);
            vm.stopPrank();
        }
        reward.mint(address(this), 20_000 ether);
        reward.approve(address(v1), type(uint256).max);
        reward.approve(address(v2), type(uint256).max);
        v1.addStakingReward(10_000 ether);
        v2.addStakingReward(10_000 ether, 20 * EPOCH);
    }

    /**
     * @dev v1 stakes count from the next epoch, and harvest pays closed epochs only, so harvesting 11 epochs and
     *      1 hour after staking pays 10 epochs in v1. The 1 hour offset keeps v1 away from the start of an epoch,
     *      where its epoch timestamp drift makes checkForClosingEpochs underflow.
     *
     *      Rounding bounds, in wei:
     *      - v1 floors the per-token payout of each epoch and level (error below 1 + boostP / 1e10 units of 1e-18
     *        per DEXY) and then each user's product (below 1 wei). With at most 2000 DEXY per user and 1.35x, a
     *        user's error is below 2.35 * 2000 + 1 = 4701 wei per epoch, 47,010 wei over 10 epochs. The distance
     *        between a payout and total * boosted / totalBoosted is then below 4 * 47,010 = 188,040 wei (its own
     *        error plus the errors inside the total).
     *      - v2.2 floors each payout once (below 1 wei) and the accumulator by less than 1e-12 wei, so the same
     *        distance is below 4 wei.
     *      Comparing the shares p1 / t1 and p2 / t2 in integers: |p1 * t2 - p2 * t1| <= 188,040 * t2 + 4 * t1.
     *      With totals above 5e21 wei this allows a share difference below 4e-17.
     */
    function test_V1AndV2_2ShareRewardsByBoostedStake() public {
        vm.warp(block.timestamp + (REWARDED_EPOCHS + 1) * EPOCH + 1 hours);

        uint256[3] memory p1;
        uint256[3] memory p2;
        uint256 t1 = 0;
        uint256 t2 = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 before = reward.balanceOf(users[i]);
            vm.prank(users[i]);
            v1.harvest();
            p1[i] = reward.balanceOf(users[i]) - before;
            before = reward.balanceOf(users[i]);
            vm.prank(users[i]);
            v2.harvest();
            p2[i] = reward.balanceOf(users[i]) - before;
            t1 += p1[i];
            t2 += p2[i];
        }

        for (uint256 i = 0; i < 3; i++) {
            // Each version against its own proportional split
            assertApproxEqAbs(p1[i], t1 * boosted[i] / TOTAL_BOOSTED, 188_040);
            assertApproxEqAbs(p2[i], t2 * boosted[i] / TOTAL_BOOSTED, 4);
            // Both versions against each other
            assertApproxEqAbs(p1[i] * t2, p2[i] * t1, 188_040 * t2 + 4 * t1);
        }
    }
}
