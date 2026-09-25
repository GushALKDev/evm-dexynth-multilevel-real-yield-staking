// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV2_2} from "../src/DexynthStaking.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

/**
 * @notice A token that calls back into the staking contract during its transfers. Every reentrant call must hit
 *         the reentrancy guard, and the outer call must still complete with the expected state
 */
contract ReentrancyTest is Test {
    DexynthStakingV2_2 internal staking;
    ReentrantERC20 internal dexy;
    ReentrantERC20 internal reward;
    address internal user = address(0xA11CE);
    bytes internal constant GUARD_ERROR = abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call");

    function setUp() public {
        vm.warp(2_000_000_000);
        dexy = new ReentrantERC20();
        reward = new ReentrantERC20();
        DexynthStakingV2_2.Level[] memory levels = new DexynthStakingV2_2.Level[](2);
        levels[0] = DexynthStakingV2_2.Level(30 days, 5e9, 0);
        levels[1] = DexynthStakingV2_2.Level(60 days, 15e9, 0);
        staking = new DexynthStakingV2_2(address(dexy), address(reward), levels, 1 days);

        dexy.mint(user, 1000 ether);
        vm.prank(user);
        dexy.approve(address(staking), type(uint256).max);
        reward.mint(address(this), 1000 ether);
        reward.approve(address(staking), type(uint256).max);
    }

    function _assertBlocked(ReentrantERC20 _token) internal view {
        assertTrue(_token.attempted(), "no reentrant call was made");
        assertFalse(_token.succeeded(), "reentrant call succeeded");
        assertEq(_token.returnData(), GUARD_ERROR);
    }

    function test_StakeCannotBeReentered() public {
        dexy.arm(address(staking), abi.encodeCall(staking.stake, (1 ether, 0)));
        vm.prank(user);
        staking.stake(100 ether, 0);

        _assertBlocked(dexy);
        (uint64 count,,,,,) = staking.users(user);
        assertEq(count, 1);
        assertEq(staking.totalBoostedStake(), 50 ether);
    }

    function test_UnstakeCannotBeReentered() public {
        vm.prank(user);
        staking.stake(100 ether, 0);
        vm.warp(block.timestamp + 31 days);

        // The DEXY transfer back to the user tries to withdraw the same stake again
        dexy.arm(address(staking), abi.encodeCall(staking.unstake, (0)));
        vm.prank(user);
        staking.unstake(0);

        _assertBlocked(dexy);
        assertEq(dexy.balanceOf(user), 1000 ether);
        assertEq(dexy.balanceOf(address(staking)), 0);
    }

    function test_HarvestCannotBeReentered() public {
        vm.prank(user);
        staking.stake(100 ether, 0);
        staking.addStakingReward(100 ether, 10 days);
        vm.warp(block.timestamp + 10 days);

        // The reward transfer to the user tries to harvest again
        reward.arm(address(staking), abi.encodeCall(staking.harvest, ()));
        vm.prank(user);
        staking.harvest();

        _assertBlocked(reward);
        // Single staker, full stream: 100 tokens, at most 1 wei less from the one settlement, never more
        assertLe(reward.balanceOf(user), 100 ether);
        assertGe(reward.balanceOf(user), 100 ether - 1);
    }

    function test_AddStakingRewardCannotBeReentered() public {
        // The reward transferFrom tries to enter stake, which is also guarded
        reward.arm(address(staking), abi.encodeCall(staking.stake, (1 ether, 0)));
        staking.addStakingReward(100 ether, 10 days);

        _assertBlocked(reward);
        assertEq(staking.totalRewardsFunded(), 100 ether);
        assertEq(staking.totalBoostedStake(), 0);
    }

    function test_ExecuteMigrationCannotBeReentered() public {
        staking.addStakingReward(100 ether, 60 days);
        staking.requestMigration(address(0xDEAD));
        vm.warp(block.timestamp + 30 days);

        reward.arm(address(staking), abi.encodeCall(staking.harvest, ()));
        staking.executeMigration();

        _assertBlocked(reward);
        assertTrue(staking.migrated());
    }
}
