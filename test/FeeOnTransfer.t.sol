// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV2_3} from "../src/DexynthStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";

/**
 * @notice Fee-on-transfer tokens are not supported. The contract records the amount requested, not the amount
 *         received, so with a 1% fee token the books run ahead of the balance and the last withdrawals revert.
 *         These tests document that limitation, they do not describe intended behaviour
 */
contract FeeOnTransferTest is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function _levels() internal pure returns (DexynthStakingV2_3.Level[] memory levels) {
        levels = new DexynthStakingV2_3.Level[](1);
        levels[0] = DexynthStakingV2_3.Level(30 days, 1e10, 0);
    }

    function test_FeeOnTransferDexyLeavesPrincipalShortfall() public {
        vm.warp(2_000_000_000);
        FeeOnTransferERC20 dexy = new FeeOnTransferERC20();
        MockERC20 reward = new MockERC20("Reward Token", "RWD", 18);
        DexynthStakingV2_3 staking =
            new DexynthStakingV2_3(address(dexy), address(reward), _levels(), 1 days, block.timestamp + 1 days);

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            dexy.mint(users[i], 1000 ether);
            vm.startPrank(users[i]);
            dexy.approve(address(staking), type(uint256).max);
            staking.stake(1000 ether, 0);
            vm.stopPrank();
        }
        // 2000 recorded, 1980 received: 1% of each transfer was burned
        assertEq(staking.getLevels()[0].totalStaked, 2000 ether);
        assertEq(dexy.balanceOf(address(staking)), 1980 ether);

        vm.warp(block.timestamp + 32 days);
        vm.prank(alice);
        staking.unstake(0);
        // The contract sent 1000 of its 1980, bob's recorded 1000 no longer fits
        assertEq(dexy.balanceOf(address(staking)), 980 ether);

        vm.prank(bob);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        staking.unstake(0);
    }

    function test_FeeOnTransferRewardLeavesRewardShortfall() public {
        vm.warp(2_000_000_000);
        MockERC20 dexy = new MockERC20("Dexy Token", "DEXY", 18);
        FeeOnTransferERC20 reward = new FeeOnTransferERC20();
        DexynthStakingV2_3 staking =
            new DexynthStakingV2_3(address(dexy), address(reward), _levels(), 1 days, block.timestamp + 1 days);

        dexy.mint(alice, 1000 ether);
        vm.startPrank(alice);
        dexy.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether, 0);
        vm.stopPrank();

        reward.mint(address(this), 1000 ether);
        reward.approve(address(staking), type(uint256).max);
        staking.addStakingReward(1000 ether);
        assertEq(staking.totalRewardsFunded(), 1000 ether);
        assertEq(reward.balanceOf(address(staking)), 990 ether);

        // Epoch 0 promises 1000 tokens (minus at most 1 wei of flooring) against a balance of 990
        vm.warp(staking.nextEpochStart() + 1 days);
        uint256 pending = staking.pendingRewards(alice);
        assertGe(pending, 1000 ether - 1);
        vm.prank(alice);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        staking.harvest();
    }
}
