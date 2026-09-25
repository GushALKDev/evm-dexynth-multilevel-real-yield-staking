// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";

/**
 * @title DexynthStakingV2_2 invariant tests
 * @notice Solvency, conservation and accounting invariants, run with an 18-decimal and a 6-decimal reward token
 */
abstract contract InvariantBase is StdInvariant, Test {
    DexynthStakingV2_2 internal staking;
    MockERC20 internal dexy;
    MockERC20 internal reward;
    Handler internal handler;

    string internal statsFile;

    function _setUp(uint8 _rewardDecimals) internal {
        vm.warp(2_000_000_000);
        dexy = new MockERC20("Dexy Token", "DEXY", 18);
        reward = new MockERC20("Reward Token", "RWD", _rewardDecimals);

        DexynthStakingV2_2.Level[] memory levels = new DexynthStakingV2_2.Level[](5);
        levels[0] = DexynthStakingV2_2.Level(2592000, 6500000000, 0);
        levels[1] = DexynthStakingV2_2.Level(7776000, 8500000000, 0);
        levels[2] = DexynthStakingV2_2.Level(15552000, 10000000000, 0);
        levels[3] = DexynthStakingV2_2.Level(31536000, 11500000000, 0);
        levels[4] = DexynthStakingV2_2.Level(62208000, 13500000000, 0);
        staking = new DexynthStakingV2_2(address(dexy), address(reward), levels, 1296000);

        handler = new Handler(staking, dexy, reward);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = Handler.stake.selector;
        selectors[1] = Handler.unstake.selector;
        selectors[2] = Handler.harvest.selector;
        selectors[3] = Handler.addStakingReward.selector;
        selectors[4] = Handler.addStakingRewardNonOwner.selector;
        selectors[5] = Handler.requestMigration.selector;
        selectors[6] = Handler.cancelMigration.selector;
        selectors[7] = Handler.executeMigration.selector;
        selectors[8] = Handler.expireMigration.selector;
        selectors[9] = Handler.advanceTime.selector;
        selectors[10] = Handler.advanceOneEpoch.selector;
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
        DexynthStakingV2_2.Level[] memory levels = staking.getLevels();
        for (uint256 i = 0; i < levels.length; i++) {
            principalFromLevels += levels[i].totalStaked;
        }
        assertEq(principalFromLevels, principalFromStakes, "level totals != open stakes");
        assertEq(dexy.balanceOf(address(staking)), principalFromStakes, "DEXY balance != open principal");
    }

    /**
     * @notice The reward balance covers the rewards accrued and not claimed, the rewards scheduled and not yet
     *         streamed, and unallocatedRewards
     * @dev Accrued rewards are read with pendingRewards, which rounds each user down. The scheduled and unallocated
     *      parts are kept scaled by 1e36, including the stream since the last pool update when no one is staked,
     *      and rounded up. No tolerance: the balance is an integer, so it must be at least the rounded-up total
     */
    function invariant_rewardBalanceCoversLiabilities() public view {
        uint256 accrued = 0;
        for (uint256 a = 0; a < handler.NUM_ACTORS(); a++) {
            accrued += staking.pendingRewards(handler.getActor(a));
        }

        uint256 scaled = staking.unallocatedRewards();
        uint256 last = staking.lastRewardTime();
        uint256 end = staking.rewardEndTime();
        uint256 rate = staking.rewardRate();
        if (end > block.timestamp) scaled += (end - block.timestamp) * rate;
        // With no boosted stake, the stream since the last update is unallocated but not yet written to storage
        uint256 streamedEnd = block.timestamp < end ? block.timestamp : end;
        if (staking.totalBoostedStake() == 0 && streamedEnd > last) scaled += (streamedEnd - last) * rate;

        uint256 liabilities = accrued + Math.ceilDiv(scaled, 1e36);
        assertGe(reward.balanceOf(address(staking)), liabilities, "reward balance < liabilities");
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
     * @notice After a migration the stream stays stopped and no request can be pending
     */
    function invariant_migrationStopsStream() public view {
        if (!staking.migrated()) return;
        assertEq(staking.rewardRate(), 0, "rate after migration");
        assertEq(staking.unallocatedRewards(), 0, "unallocated after migration");
        assertEq(staking.pendingMigrationAddress(), address(0), "pending request after migration");
    }

    /**
     * @notice Appends the effective calls per action of the finished run to statsFile. Not an invariant
     */
    function afterInvariant() public {
        string[14] memory names = [
            "stake",
            "stakeAfterMigration",
            "unstake",
            "harvest",
            "harvestNothing",
            "addReward",
            "addRewardAfterMigration",
            "addRewardNonOwner",
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

contract InvariantReward18 is InvariantBase {
    function setUp() public {
        statsFile = "cache/invariant-stats-18.txt";
        _setUp(18);
    }
}

contract InvariantReward6 is InvariantBase {
    function setUp() public {
        statsFile = "cache/invariant-stats-6.txt";
        _setUp(6);
    }
}
