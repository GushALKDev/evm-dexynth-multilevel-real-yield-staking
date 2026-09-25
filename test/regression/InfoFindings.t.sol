// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegressionBase} from "./RegressionBase.sol";

/**
 * @notice Round 1 INFO findings
 */
contract InfoFindingsTest is RegressionBase {
    bytes4 internal constant STAKE_NOT_FOUND = bytes4(keccak256("StakeNotFound()"));

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
}
