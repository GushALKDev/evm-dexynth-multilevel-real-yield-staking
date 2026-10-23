// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {DexynthStakingV2_3} from "../../src/DexynthStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";

/**
 * @title DexynthStakingV2_3 invariant tests
 * @notice Solvency, conservation and accounting invariants. Two campaigns (normal operation and migration), each
 *         run with an 18-decimal and a 6-decimal reward token
 */
abstract contract InvariantBase is StdInvariant, Test {
    DexynthStakingV2_3 internal staking;
    MockERC20 internal dexy;
    MockERC20 internal reward;
    Handler internal handler;

    string internal statsFile;

    function _setUp(uint8 _rewardDecimals, bool _withMigration) internal {
        vm.warp(2_000_000_000);
        dexy = new MockERC20("Dexy Token", "DEXY", 18);
        reward = new MockERC20("Reward Token", "RWD", _rewardDecimals);

        DexynthStakingV2_3.Level[] memory levels = new DexynthStakingV2_3.Level[](5);
        levels[0] = DexynthStakingV2_3.Level(2592000, 6500000000, 0);
        levels[1] = DexynthStakingV2_3.Level(7776000, 8500000000, 0);
        levels[2] = DexynthStakingV2_3.Level(15552000, 10000000000, 0);
        levels[3] = DexynthStakingV2_3.Level(31536000, 11500000000, 0);
        levels[4] = DexynthStakingV2_3.Level(62208000, 13500000000, 0);
        // Epoch 0 starts one day after deployment, so runs also cover deposits and stakes made before it
        staking = new DexynthStakingV2_3(address(dexy), address(reward), levels, 1296000, block.timestamp + 1 days);

        handler = new Handler(staking, dexy, reward);
        targetContract(address(handler));

        // The normal campaign never touches the migration lifecycle
        bytes4[] memory selectors = new bytes4[](_withMigration ? 10 : 6);
        selectors[0] = Handler.stake.selector;
        selectors[1] = Handler.unstake.selector;
        selectors[2] = Handler.harvest.selector;
        selectors[3] = Handler.addStakingReward.selector;
        selectors[4] = Handler.advanceTime.selector;
        selectors[5] = Handler.advanceOneEpoch.selector;
        if (_withMigration) {
            selectors[6] = Handler.requestMigration.selector;
            selectors[7] = Handler.cancelMigration.selector;
            selectors[8] = Handler.executeMigration.selector;
            selectors[9] = Handler.expireMigration.selector;
        }
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                               SOLVENCY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The DEXY balance matches the principal of all open stakes, read from contract state
     * @dev No action sends DEXY to the contract other than stake, so the balance must be exactly the principal,
     *      which implies balance >= principal. The per-level totals must add up to the same principal
     */
    function invariant_dexyBalanceCoversPrincipal() public view {
        (uint256 principalFromStakes,) = _sumOpenStakes();
        uint256 principalFromLevels = 0;
        DexynthStakingV2_3.Level[] memory levels = staking.getLevels();
        for (uint256 i = 0; i < levels.length; i++) {
            principalFromLevels += levels[i].totalStaked;
        }
        assertEq(principalFromLevels, principalFromStakes, "level totals != open stakes");
        assertEq(dexy.balanceOf(address(staking)), principalFromStakes, "DEXY balance != open principal");
    }

    /**
     * @notice The reward balance covers the rewards accrued and not claimed, the rewards queued or scheduled and not
     *         yet streamed, and unallocatedRewards, and exceeds them only by rounding dust
     * @dev Accrued rewards are read with pendingRewards, which rounds each user down. The scheduled, queued and
     *      unallocated parts are kept scaled by 1e36, including the stream since the last pool update when no one is
     *      staked, and rounded up. The pool state is only written on updates, so the parts are rebuilt from it the
     *      way the next update will: the stored rate until nextEpochStart, then the queued rewards over the epoch
     *      after it. Lower bound: no tolerance, the balance is an integer and must be at least the rounded-up total.
     *      Upper bound: the only value that can stay in the contract without being owed or scheduled is rounding
     *      dust, below 1 wei per settlement (ghost_settlements), per executed migration (ghost_migrations) and per
     *      actor in the pendingRewards floor above (NUM_ACTORS), plus below 1 wei for all the 1e36-scaled
     *      truncations together (rate floors below epochDuration / 1e36 per epoch, accumulator floors below
     *      totalBoostedStake / 1e36, at most about 2e25 / 1e36, per update). Losing or withholding any real reward
     *      breaks the upper bound
     */
    function invariant_rewardBalanceMatchesLiabilities() public view {
        uint256 accrued = 0;
        for (uint256 a = 0; a < handler.NUM_ACTORS(); a++) {
            accrued += staking.pendingRewards(handler.getActor(a));
        }

        uint256 now_ = block.timestamp;
        uint256 last = staking.lastRewardTime();
        uint256 next = staking.nextEpochStart();
        uint256 duration = staking.epochDuration();
        uint256 rate = staking.rewardRate();
        uint256 queued = staking.queuedRewards();
        uint256 queuedRate = queued / duration;

        uint256 scaled = staking.unallocatedRewards();
        uint256 sinceUpdate = 0;
        if (now_ < next) {
            scaled += (next - now_) * rate + queued;
            sinceUpdate = (now_ - last) * rate;
        } else {
            uint256 queuedEnd = next + duration;
            if (now_ < queuedEnd) scaled += (queuedEnd - now_) * queuedRate;
            sinceUpdate = (next - last) * rate + ((now_ < queuedEnd ? now_ : queuedEnd) - next) * queuedRate;
        }
        // With no boosted stake, the stream since the last update is unallocated but not yet written to storage
        if (staking.totalBoostedStake() == 0) scaled += sinceUpdate;

        uint256 liabilities = accrued + Math.ceilDiv(scaled, 1e36);
        uint256 balance = reward.balanceOf(address(staking));
        assertGe(balance, liabilities, "reward balance < liabilities");
        uint256 maxDust = handler.ghost_settlements() + handler.ghost_migrations() + handler.NUM_ACTORS() + 1;
        assertLe(balance - liabilities, maxDust, "reward balance exceeds liabilities by more than rounding dust");
    }

    /**
     * @notice Every reward token added is either paid to a staker, migrated or still held, exactly
     */
    function invariant_rewardConservation() public view {
        uint256 paid = 0;
        for (uint256 a = 0; a < handler.NUM_ACTORS(); a++) {
            paid += reward.balanceOf(handler.getActor(a));
        }
        uint256 migrated = reward.balanceOf(handler.MIGRATION_TARGET());
        uint256 held = reward.balanceOf(address(staking));
        assertEq(handler.ghost_rewardsAdded(), paid + migrated + held, "added != paid + migrated + held");
        assertEq(handler.ghost_rewardsAdded(), staking.totalRewardsFunded(), "added != totalRewardsFunded");
    }

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice totalBoostedStake equals the boosted amounts of the open stakes and the users' boosted balances,
     *         and each user's totalStakedDexy equals the principal of their open stakes
     */
    function invariant_boostedAndUserAccounting() public view {
        uint256 sumUserBoosted = 0;
        for (uint256 a = 0; a < handler.NUM_ACTORS(); a++) {
            address actor = handler.getActor(a);
            (uint64 count,, uint128 staked, uint128 boosted,,) = staking.users(actor);
            sumUserBoosted += boosted;
            uint256 principal = 0;
            uint256 stakesBoosted = 0;
            for (uint64 i = 0; i < count; i++) {
                (bool unstaked,,,, uint128 amount, uint128 boostedAmount) = staking.stakeInfo(actor, i);
                if (!unstaked) {
                    principal += amount;
                    stakesBoosted += boostedAmount;
                }
            }
            assertEq(staked, principal, "user totalStakedDexy != open stakes");
            assertEq(boosted, stakesBoosted, "user boostedBalance != open stakes");
        }
        (, uint256 openBoosted) = _sumOpenStakes();
        assertEq(staking.totalBoostedStake(), openBoosted, "totalBoostedStake != open stakes");
        assertEq(staking.totalBoostedStake(), sumUserBoosted, "totalBoostedStake != user balances");
    }

    /**
     * @notice Appends the effective calls per action of the finished run to statsFile. Not an invariant
     */
    function afterInvariant() public {
        string[14] memory names = [
            "stake",
            "stakeAfterMigration",
            "unstake",
            "unstakeDuringStream",
            "harvest",
            "harvestNothing",
            "addReward",
            "addRewardAfterMigration",
            "requestMigration",
            "cancelMigration",
            "executeMigration",
            "expireMigration",
            "advanceTime",
            "advanceOneEpoch"
        ];
        string memory line = "";
        for (uint256 i = 0; i < names.length; i++) {
            line = string.concat(line, names[i], "=", vm.toString(handler.effective(bytes32(bytes(names[i])))), " ");
        }
        vm.writeLine(statsFile, line);
    }

    function _sumOpenStakes() internal view returns (uint256 principal, uint256 boosted) {
        for (uint256 a = 0; a < handler.NUM_ACTORS(); a++) {
            address actor = handler.getActor(a);
            (uint64 count,,,,,) = staking.users(actor);
            for (uint64 i = 0; i < count; i++) {
                (bool unstaked,,,, uint128 amount, uint128 boostedAmount) = staking.stakeInfo(actor, i);
                if (!unstaked) {
                    principal += amount;
                    boosted += boostedAmount;
                }
            }
        }
    }
}

/**
 * @notice Invariant that only means something when migrations happen, added to the migration campaign only
 */
abstract contract InvariantMigrationBase is InvariantBase {
    /**
     * @notice After a migration the stream stays stopped and no request can be pending
     */
    function invariant_migrationStopsStream() public view {
        if (!staking.migrated()) return;
        assertEq(staking.rewardRate(), 0, "rate after migration");
        assertEq(staking.queuedRewards(), 0, "queued after migration");
        assertEq(staking.unallocatedRewards(), 0, "unallocated after migration");
        assertEq(staking.pendingMigrationAddress(), address(0), "pending request after migration");
    }
}

/**
 * @notice Normal operation: stake, unstake, harvest, deposits by the owner and by stakers and time warps, no migration
 * @dev 128 calls per run: without migrations nothing ends a run early, and longer sequences let funded epochs end and
 *      new ones start, locks of up to 720 days expire and stakes of every level be withdrawn within one run
 */
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract InvariantNormalReward18 is InvariantBase {
    function setUp() public {
        statsFile = "cache/invariant-stats-normal-18.txt";
        _setUp(18, false);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract InvariantNormalReward6 is InvariantBase {
    function setUp() public {
        statsFile = "cache/invariant-stats-normal-6.txt";
        _setUp(6, false);
    }
}

/**
 * @notice Full handler including the migration lifecycle: request, cancel, execute and expiry
 * @dev 64 calls per run: a migration needs a request (discarded 7 times out of 8), the 30 day delay and an execution,
 *      and the runs that migrate still need calls before it for stake, unstake and harvest. About 4 in 10 runs
 *      execute a migration
 */
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract InvariantMigrationReward18 is InvariantMigrationBase {
    function setUp() public {
        statsFile = "cache/invariant-stats-migration-18.txt";
        _setUp(18, true);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract InvariantMigrationReward6 is InvariantMigrationBase {
    function setUp() public {
        statsFile = "cache/invariant-stats-migration-6.txt";
        _setUp(6, true);
    }
}
