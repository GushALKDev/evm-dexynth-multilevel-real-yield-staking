// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_2} from "../src/DexynthStaking.sol";

/**
 * @notice harvest must not loop over stakes, levels or epochs
 * @dev Every scenario reaches harvest with the same zero and non-zero storage slots, so the gas of the harvest
 *      call must be identical. Any loop over stakes, levels or epochs would make it differ
 */
contract HarvestGasIndependenceTest is StakingFixture {
    function setUp() public {
        _deploy(18);
        _stake(bob, 1000 ether, 2);
        _fund(1_000_000 ether, 3650 days);
    }

    function _harvestGasAfterStakes(uint256 _stakes) internal returns (uint256) {
        for (uint256 i = 0; i < _stakes; i++) {
            _stake(alice, 100 ether, 0);
        }
        vm.warp(block.timestamp + 60 days);
        vm.prank(alice);
        staking.harvest();
        return vm.lastCallGas().gasTotalUsed;
    }

    function test_HarvestGasIndependentOfStakeCount() public {
        uint256 snap = vm.snapshotState();
        uint256 g1 = _harvestGasAfterStakes(1);
        vm.revertToState(snap);
        uint256 g10 = _harvestGasAfterStakes(10);
        vm.revertToState(snap);
        uint256 g100 = _harvestGasAfterStakes(100);
        vm.revertToState(snap);
        uint256 g500 = _harvestGasAfterStakes(500);

        assertEq(g10, g1);
        assertEq(g100, g1);
        assertEq(g500, g1);
    }

    function test_HarvestGasIndependentOfEpochs() public {
        _stake(alice, 100 ether, 0);
        uint256 snap = vm.snapshotState();
        uint256[4] memory epochs = [uint256(1), 10, 52, 100];
        uint256[4] memory gas;
        for (uint256 i = 0; i < epochs.length; i++) {
            vm.revertToState(snap);
            vm.warp(block.timestamp + epochs[i] * EPOCH);
            vm.prank(alice);
            staking.harvest();
            gas[i] = vm.lastCallGas().gasTotalUsed;
        }
        assertEq(gas[1], gas[0]);
        assertEq(gas[2], gas[0]);
        assertEq(gas[3], gas[0]);
    }

    function test_HarvestGasIndependentOfLevelsTouched() public {
        uint256 snap = vm.snapshotState();
        _stake(alice, 100 ether, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        staking.harvest();
        uint256 oneLevel = vm.lastCallGas().gasTotalUsed;

        vm.revertToState(snap);
        for (uint8 l = 0; l < 5; l++) {
            _stake(alice, 100 ether, l);
        }
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        staking.harvest();
        assertEq(vm.lastCallGas().gasTotalUsed, oneLevel);
    }

    /**
     * @notice A deployment with 10 levels harvests at the same cost as one with a single level
     * @dev Both use the scenario of the other tests on a fresh contract. A loop over the configured levels would make
     *      the 10-level harvest more expensive
     */
    function test_HarvestGasIndependentOfConfiguredLevels() public {
        uint256 snap = vm.snapshotState();
        uint256 oneLevel = _harvestGasWithLevels(1);
        vm.revertToState(snap);
        uint256 tenLevels = _harvestGasWithLevels(10);
        assertEq(tenLevels, oneLevel);
    }

    function _harvestGasWithLevels(uint256 _count) internal returns (uint256) {
        DexynthStakingV2_2.Level[] memory levels = new DexynthStakingV2_2.Level[](_count);
        for (uint256 i = 0; i < _count; i++) {
            // Multipliers centred on 1.0x in 0.1x steps, lock of i + 1 days
            uint256 boost = (2e10 + (2 * i + 1) * 1e9 - _count * 1e9) / 2;
            levels[i] = DexynthStakingV2_2.Level(uint32((i + 1) * 1 days), uint64(boost), 0);
        }
        staking = new DexynthStakingV2_2(address(dexy), address(reward), levels, EPOCH);
        vm.prank(alice);
        dexy.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        dexy.approve(address(staking), type(uint256).max);
        reward.approve(address(staking), type(uint256).max);

        _stake(bob, 1000 ether, 0);
        _fund(1_000_000 ether, 3650 days);
        _stake(alice, 100 ether, 0);
        vm.warp(block.timestamp + 60 days);
        vm.prank(alice);
        staking.harvest();
        return vm.lastCallGas().gasTotalUsed;
    }
}
