// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegressionBase} from "./RegressionBase.sol";

/**
 * @notice Round 1 finding 3: executeMigration moved every token balance, including locked principal and
 *         accrued rewards, and a migration request never expired
 */
contract MigrationTest is RegressionBase {
    bytes4 internal constant MIGRATION_EXPIRED = bytes4(keccak256("MigrationExpired()"));
    bytes4 internal constant ALREADY_MIGRATED = bytes4(keccak256("AlreadyMigrated()"));
    address internal constant NEW_CONTRACT = address(0xDEAD);
    uint256 internal constant DELAY = 30 days;
    uint256 internal constant WINDOW = 7 days;

    function setUp() public {
        _deploy(18);
    }

    /**
     * @notice Round 1 PoC: a 720 day lock stake and a migration after the 30 day delay
     */
    function test_MigrationDoesNotMoveLockedPrincipal() public {
        _stake(alice, 1000 ether, 4);
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY);
        staking.executeMigration();

        assertEq(dexy.balanceOf(address(staking)), 1000 ether);
        assertEq(dexy.balanceOf(NEW_CONTRACT), 0);

        // The stake is still locked for about 735 days, but after a migration principal can always leave
        vm.prank(alice);
        staking.unstake(0);
        assertEq(dexy.balanceOf(alice), 100_000_000 ether);
    }

    /**
     * @notice Round 1 PoC: a request made three years earlier could still be executed
     */
    function test_RevertWhen_RequestIsExecutedAfterWindow() public {
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + 3 * 365 days);
        _stake(alice, 1000 ether, 0);
        vm.expectRevert(MIGRATION_EXPIRED);
        staking.executeMigration();
    }

    function test_RequestIsExecutableUntilLastSecondOfWindow() public {
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY + WINDOW);
        staking.executeMigration();
        assertEq(staking.pendingMigrationAddress(), address(0));
    }

    function test_RevertWhen_RequestIsExecutedOneSecondAfterWindow() public {
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY + WINDOW + 1);
        vm.expectRevert(MIGRATION_EXPIRED);
        staking.executeMigration();
    }

    function test_NewRequestAllowedAfterExpiry() public {
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY + WINDOW + 1);
        staking.requestMigration(address(0xBEEF));
        assertEq(staking.pendingMigrationAddress(), address(0xBEEF));
    }

    /**
     * @notice Only the unstreamed part of the stream moves, accrued rewards stay claimable
     * @dev 30,000 tokens over 90 days, migration after 30 days: 20,000 tokens are unstreamed. The moved amount
     *      is floor((rewardEndTime - now) * rewardRate / 1e36), so it can be up to 1 wei below 20,000 tokens.
     *      Alice is the only staker for the first 30 days, so her rewards are 10,000 tokens minus at most
     *      1 wei from the final floor. Conservation is checked exactly.
     */
    function test_MigrationMovesOnlyUnstreamedRewards() public {
        _stake(alice, 1000 ether, 0);
        _fund(30_000 ether, 90 days);
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY);
        uint256 expectedMoved = (uint256(staking.rewardEndTime()) - block.timestamp) * staking.rewardRate() / 1e36;
        staking.executeMigration();

        uint256 moved = reward.balanceOf(NEW_CONTRACT);
        assertEq(moved, expectedMoved);
        assertLe(moved, 20_000 ether);
        assertGe(moved, 20_000 ether - 1);

        // No more rewards accrue after the migration
        vm.warp(block.timestamp + 60 days);
        vm.prank(alice);
        staking.harvest();
        uint256 paid = reward.balanceOf(alice);
        assertLe(paid, 10_000 ether);
        assertGe(paid, 10_000 ether - 1);

        assertEq(moved + paid + reward.balanceOf(address(staking)), 30_000 ether);
    }

    /**
     * @notice Rewards streamed while nobody was staked also move with the migration
     * @dev The whole stream is unallocated or unstreamed, so the moved amount is 10,000 tokens minus at most
     *      1 wei from the floor of the scaled amount
     */
    function test_MigrationMovesUnallocatedRewards() public {
        _fund(10_000 ether, 60 days);
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY);
        staking.executeMigration();
        assertLe(reward.balanceOf(NEW_CONTRACT), 10_000 ether);
        assertGe(reward.balanceOf(NEW_CONTRACT), 10_000 ether - 1);
    }

    function test_RevertWhen_StakeAfterMigration() public {
        _migrate();
        vm.prank(alice);
        vm.expectRevert(ALREADY_MIGRATED);
        staking.stake(1000 ether, 0);
    }

    function test_RevertWhen_AddStakingRewardAfterMigration() public {
        _migrate();
        reward.mint(owner, 1 ether);
        vm.expectRevert(ALREADY_MIGRATED);
        staking.addStakingReward(1 ether, 1 days);
    }

    function test_RevertWhen_RequestMigrationAfterMigration() public {
        _migrate();
        vm.expectRevert(ALREADY_MIGRATED);
        staking.requestMigration(NEW_CONTRACT);
    }

    function _migrate() internal {
        staking.requestMigration(NEW_CONTRACT);
        vm.warp(block.timestamp + DELAY);
        staking.executeMigration();
    }
}
