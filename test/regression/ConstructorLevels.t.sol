// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "../utils/StakingFixture.sol";
import {DexynthStakingV2_3} from "../../src/DexynthStaking.sol";

/**
 * @notice Found in round 2, outside the requested scope: the constructor copied Level.totalStaked from its
 *         argument, so a non-zero value created stake that nobody owns and that absorbed rewards
 */
contract ConstructorLevelsTest is StakingFixture {
    function setUp() public {
        _deploy(18);
    }

    function test_ConstructorIgnoresTotalStakedArgument() public {
        DexynthStakingV2_3.Level[] memory levels = _levels();
        levels[0].totalStaked = 1000 ether;
        staking = new DexynthStakingV2_3(address(dexy), address(reward), levels, EPOCH, START);
        vm.prank(alice);
        dexy.approve(address(staking), type(uint256).max);
        reward.approve(address(staking), type(uint256).max);

        assertEq(staking.getLevels()[0].totalStaked, 0);

        // Alice is the only real staker, so she receives the whole epoch minus at most 1 wei of flooring
        _stake(alice, 1000 ether, 0);
        _fund(10_000 ether);
        vm.warp(START + EPOCH);
        uint256 pending = staking.pendingRewards(alice);
        assertLe(pending, 10_000 ether);
        assertGe(pending, 10_000 ether - 1);
    }
}
