// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV2_1} from "../../src/DexynthStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @notice Shared deployment for the regression tests of the round 1 review findings
 * @dev Uses the example level configuration of the deploy script and a 15 day epoch
 */
abstract contract RegressionBase is Test {
    uint256 internal constant EPOCH = 1296000;

    DexynthStakingV2_1 internal staking;
    MockERC20 internal dexy;
    MockERC20 internal reward;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);

    function _deploy(uint8 _rewardDecimals) internal {
        vm.warp(2_000_000_000);
        dexy = new MockERC20("Dexy Token", "DEXY", 18);
        reward = new MockERC20("Reward Token", "RWD", _rewardDecimals);
        staking = new DexynthStakingV2_1(address(dexy), address(reward), _levels(), EPOCH);
        address[3] memory users = [alice, bob, attacker];
        for (uint256 i = 0; i < users.length; i++) {
            dexy.mint(users[i], 100_000_000 ether);
            vm.prank(users[i]);
            dexy.approve(address(staking), type(uint256).max);
            vm.prank(users[i]);
            reward.approve(address(staking), type(uint256).max);
        }
        reward.approve(address(staking), type(uint256).max);
    }

    function _levels() internal pure returns (DexynthStakingV2_1.Level[] memory levels) {
        levels = new DexynthStakingV2_1.Level[](5);
        levels[0] = DexynthStakingV2_1.Level(2592000, 6500000000, 0);
        levels[1] = DexynthStakingV2_1.Level(7776000, 8500000000, 0);
        levels[2] = DexynthStakingV2_1.Level(15552000, 10000000000, 0);
        levels[3] = DexynthStakingV2_1.Level(31536000, 11500000000, 0);
        levels[4] = DexynthStakingV2_1.Level(62208000, 13500000000, 0);
    }

    function _fund(uint256 _amount, uint256 _duration) internal {
        reward.mint(owner, _amount);
        staking.addStakingReward(_amount, _duration);
    }

    function _stake(address _user, uint256 _amount, uint8 _level) internal {
        vm.prank(_user);
        staking.stake(_amount, _level);
    }
}
