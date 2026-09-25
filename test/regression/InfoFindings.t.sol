// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";
import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";

/**
 * @notice Round 1 INFO findings
 */
contract InfoFindingsTest is StakingFixture {
    bytes4 internal constant STAKE_NOT_FOUND = bytes4(keccak256("StakeNotFound()"));
    bytes4 internal constant SAME_TOKEN = bytes4(keccak256("SameToken()"));
    bytes4 internal constant TOO_MANY_LEVELS = bytes4(keccak256("TooManyLevels()"));

    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice unstake on an index the caller never used used to succeed and emit DEXYUnstaked with amount 0
     */
    function test_RevertWhen_UnstakeNonexistentIndex() public {
        vm.prank(alice);
        vm.expectRevert(STAKE_NOT_FOUND);
        staking.unstake(999);
    }

    function test_RevertWhen_UnstakeFirstUnusedIndex() public {
        _stake(alice, 1000 ether, 0);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        vm.expectRevert(STAKE_NOT_FOUND);
        staking.unstake(1);
    }

    /**
     * @notice The constructor accepted the same address for DEXY and REWARD_TOKEN, which mixes principal and rewards
     */
    function test_RevertWhen_DexyEqualsRewardToken() public {
        vm.expectRevert(SAME_TOKEN);
        new DexynthStakingV2_2(address(dexy), address(dexy), _levels(), EPOCH);
    }

    /**
     * @notice The number of levels had no cap, and the constructor loop used a uint8 counter
     * @dev 11 levels with multipliers 0.5x to 1.5x in 0.1x steps average exactly 1.0x, so only the cap can reject them
     */
    function test_RevertWhen_MoreThanMaxLevels() public {
        vm.expectRevert(TOO_MANY_LEVELS);
        new DexynthStakingV2_2(address(dexy), address(reward), _evenLevels(11), EPOCH);
    }

    /**
     * @dev 10 levels with multipliers 0.55x to 1.45x in 0.1x steps average exactly 1.0x
     */
    function test_MaxLevelsIsAccepted() public {
        DexynthStakingV2_2 s10 = new DexynthStakingV2_2(address(dexy), address(reward), _evenLevels(10), EPOCH);
        assertEq(s10.getNumberOfLevels(), 10);
    }

    /**
     * @dev n levels with lock i + 1 days and multipliers centred on 1.0x in 0.1x steps
     */
    function _evenLevels(uint256 _n) internal pure returns (DexynthStakingV2_2.Level[] memory levels) {
        levels = new DexynthStakingV2_2.Level[](_n);
        for (uint256 i = 0; i < _n; i++) {
            // boost = 1.0x + (i - (n - 1) / 2) * 0.1x, written with 1e9 = 0.1x and doubled to stay in integers
            uint256 boost = (2e10 + (2 * i + 1) * 1e9 - _n * 1e9) / 2;
            levels[i] = DexynthStakingV2_2.Level(uint32((i + 1) * 1 days), uint64(boost), 0);
        }
    }

    /**
     * @notice migrationRequestTime was stored as uint32, which truncates timestamps from February 2106
     * @dev 2^32 + 100 is 100 seconds after the last uint32 timestamp
     */
    function test_MigrationTimestampAfter2106() public {
        vm.warp(uint256(type(uint32).max) + 101);
        staking.requestMigration(address(0xDEAD));
        assertEq(staking.migrationRequestTime(), block.timestamp);

        vm.warp(block.timestamp + 30 days);
        staking.executeMigration();
        assertTrue(staking.migrated());
    }
}
