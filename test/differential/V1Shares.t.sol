// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV1} from "../../bench/DexynthStakingV1.sol";
import {DexynthStakingV2_3} from "../../src/DexynthStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @notice Differential check of v1 (original Dexynth contract, bench/) against v2.3 on how rewards are shared
 * @dev Absolute payouts are not comparable: v1 releases rewards per closed epoch at a rate computed when the
 *      epochs are closed (accRewards divided by the seconds since the last closed epoch), while v2.3 streams each
 *      deposit over the next epoch to start. What both must agree on is the split: with a constant set of stakes,
 *      every user receives total * boosted / totalBoosted. The tests align both versions on the same stakes and
 *      compare each user's share of the total paid by each version, first with a constant set of stakes and then
 *      with a user joining halfway, split into two phases that each have a constant set of stakes in both versions.
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
    DexynthStakingV2_3 internal v2;
    MockERC20 internal reward;
    MockERC20 internal dexy;

    function setUp() public {
        vm.warp(2_000_000_000);
        dexy = new MockERC20("Dexy Token", "DEXY", 18);
        reward = new MockERC20("Reward Token", "RWD", 18);

        DexynthStakingV1.Level[5] memory levelsV1 = [
            DexynthStakingV1.Level(2592000, 6500000000),
            DexynthStakingV1.Level(7776000, 8500000000),
            DexynthStakingV1.Level(15552000, 10000000000),
            DexynthStakingV1.Level(31536000, 11500000000),
            DexynthStakingV1.Level(62208000, 13500000000)
        ];
        v1 = new DexynthStakingV1(address(dexy), address(reward), levelsV1, EPOCH);

        DexynthStakingV2_3.Level[] memory levelsV2 = new DexynthStakingV2_3.Level[](5);
        for (uint256 i = 0; i < 5; i++) {
            levelsV2[i] = DexynthStakingV2_3.Level(uint32(levelsV1[i].lockingPeriod), uint64(levelsV1[i].boostP), 0);
        }
        // v2.3 epoch 0 starts 1 hour after deployment, so the setUp deposit streams over it
        v2 = new DexynthStakingV2_3(address(dexy), address(reward), levelsV2, EPOCH, block.timestamp + 1 hours);

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
        v2.addStakingReward(10_000 ether);
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
     *      - v2.3 floors each payout once (below 1 wei) and the accumulator by less than 1e-12 wei, so the same
     *        distance is below 4 wei.
     *      Comparing the shares p1 / t1 and p2 / t2 in integers: |p1 * t2 - p2 * t1| <= 188,040 * t2 + 4 * t1.
     *      With totals above 5e21 wei this allows a share difference below 4e-17.
     */
    function test_V1AndV2_3ShareRewardsByBoostedStake() public {
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

    /**
     * @notice A fourth user joins halfway. Phase 1 pays A, B and C only, phase 2 pays A, B, C and D, in both versions
     * @dev Timeline (15 day epochs, v1 genesis one epoch before deployment, so v1 is in epoch 1 at deployment):
     *      - t0 + 4 epochs + 1 hour: D stakes in v1 (epoch 5), so v1 counts D from epoch 6.
     *      - t0 + 5 epochs + 1 hour: A, B and C harvest in both versions. v1 pays epochs 2 to 5, all without D;
     *        v2.3 pays its epoch 0, funded in setUp. Then D stakes in v2.3, which counts D from that block, and a
     *        second deposit funds v2.3 epoch 6.
     *      - t0 + 11 epochs + 1 hour: everyone harvests. v1 pays epochs 6 to 11, all with D; v2.3 pays its epoch 6,
     *        also with D.
     *      Rounding bounds, as in the test above: a v1 user's error is below 2.35 * 2000 + 1 = 4701 wei per epoch.
     *      Phase 1 has 4 epochs and 3 users: distance below 4 * 4 * 4701 = 75,216 wei. Phase 2 has 6 epochs and
     *      4 users: distance below 5 * 6 * 4701 = 141,030 wei. v2.3 floors each payout once: distance below the
     *      number of users plus 1
     */
    function test_V1AndV2_3ShareRewardsWhenAUserJoins() public {
        address d = address(0xD);
        dexy.mint(d, 3000 ether);
        vm.startPrank(d);
        dexy.approve(address(v1), type(uint256).max);
        dexy.approve(address(v2), type(uint256).max);
        vm.stopPrank();
        uint256 start = block.timestamp;

        vm.warp(start + 4 * EPOCH + 1 hours);
        vm.prank(d);
        v1.stake(1500 ether, 1);

        // Phase 1: A, B and C only
        vm.warp(start + 5 * EPOCH + 1 hours);
        address[] memory abc = new address[](3);
        uint256[] memory boostedAbc = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            abc[i] = users[i];
            boostedAbc[i] = boosted[i];
        }
        uint256[] memory p1 = _harvestAll(address(v1), abc);
        uint256[] memory p2 = _harvestAll(address(v2), abc);
        _assertShares(p1, p2, boostedAbc, 75_216, 4);

        vm.prank(d);
        v2.stake(1500 ether, 1);
        reward.mint(address(this), 10_000 ether);
        v2.addStakingReward(10_000 ether);

        // Phase 2: A, B, C and D (1500 DEXY at 0.85x, 1275 boosted units)
        vm.warp(start + 11 * EPOCH + 1 hours);
        address[] memory abcd = new address[](4);
        uint256[] memory boostedAbcd = new uint256[](4);
        for (uint256 i = 0; i < 3; i++) {
            abcd[i] = users[i];
            boostedAbcd[i] = boosted[i];
        }
        abcd[3] = d;
        boostedAbcd[3] = 1275;
        p1 = _harvestAll(address(v1), abcd);
        p2 = _harvestAll(address(v2), abcd);
        _assertShares(p1, p2, boostedAbcd, 141_030, 5);
    }

    function _harvestAll(address _staking, address[] memory _users) internal returns (uint256[] memory paid) {
        paid = new uint256[](_users.length);
        for (uint256 i = 0; i < _users.length; i++) {
            uint256 before = reward.balanceOf(_users[i]);
            vm.prank(_users[i]);
            // v1 and v2.3 share the harvest() signature, so one cast serves both
            DexynthStakingV2_3(_staking).harvest();
            paid[i] = reward.balanceOf(_users[i]) - before;
        }
    }

    /**
     * @dev Each version against its own proportional split (distances _d1 and _d2), then both against each other
     */
    function _assertShares(
        uint256[] memory _p1,
        uint256[] memory _p2,
        uint256[] memory _boosted,
        uint256 _d1,
        uint256 _d2
    ) internal pure {
        uint256 t1 = 0;
        uint256 t2 = 0;
        uint256 totalBoosted = 0;
        for (uint256 i = 0; i < _p1.length; i++) {
            t1 += _p1[i];
            t2 += _p2[i];
            totalBoosted += _boosted[i];
        }
        for (uint256 i = 0; i < _p1.length; i++) {
            assertApproxEqAbs(_p1[i], t1 * _boosted[i] / totalBoosted, _d1);
            assertApproxEqAbs(_p2[i], t2 * _boosted[i] / totalBoosted, _d2);
            assertApproxEqAbs(_p1[i] * t2, _p2[i] * t1, _d1 * t2 + _d2 * t1);
        }
    }
}
