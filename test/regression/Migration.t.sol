// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";

/**
 * @notice Round 1 finding 3: executeMigration moved every token balance, including locked principal and
 *         accrued rewards, and a migration request never expired
 */
contract MigrationTest is StakingFixture {
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
     * @notice Only what is not streamed yet moves, accrued rewards stay claimable
     * @dev 15,000 tokens for epoch 0, 15,000 for epoch 1 and 6,000 queued for epoch 2. The request is made at the
     *      deployment, so the migration runs 29 days into the first epochs, with one day of epoch 1 left: 1,000 of
     *      its tokens plus the 6,000 queued move. The moved amount is floor of the scaled sum, so it can be up to
     *      1 wei below 7,000 tokens. alice is the only staker, so her rewards are 29,000 tokens minus at most 1 wei
     *      from the final floor. Conservation is checked exactly.
     */
    function test_MigrationMovesOnlyUnstreamedRewards() public {
        _stake(alice, 1000 ether, 0);
        staking.requestMigration(NEW_CONTRACT);
        _fund(15_000 ether);
        vm.warp(START + 10 days);
        _fund(15_000 ether);
        vm.warp(START + 20 days);
        _fund(6_000 ether);

        vm.warp(DEPLOY_TIME + DELAY);
        assertEq(staking.nextEpochStart(), START + 2 * EPOCH);
        uint256 expectedMoved =
            ((uint256(staking.nextEpochStart()) - block.timestamp) * staking.rewardRate() + staking.queuedRewards())
                / 1e36;
        staking.executeMigration();

        uint256 moved = reward.balanceOf(NEW_CONTRACT);
        assertEq(moved, expectedMoved);
        assertLe(moved, 7_000 ether);
        assertGe(moved, 7_000 ether - 1);
        assertEq(staking.queuedRewards(), 0);

        // No more rewards accrue after the migration, not even in the epoch the queued deposit was for
        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        staking.harvest();
        uint256 paid = reward.balanceOf(alice);
        assertLe(paid, 29_000 ether);
        assertGe(paid, 29_000 ether - 1);

        assertEq(moved + paid + reward.balanceOf(address(staking)), 36_000 ether);
    }

    /**
     * @notice Rewards streamed while nobody was staked also move with the migration
     * @dev Epoch 0 ends before the migration with no stakers, so it is all unallocated and the moved amount is
     *      10,000 tokens minus at most 1 wei from the floor of the scaled amount
     */
    function test_MigrationMovesUnallocatedRewards() public {
        _fund(10_000 ether);
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
        staking.addStakingReward(1 ether);
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
