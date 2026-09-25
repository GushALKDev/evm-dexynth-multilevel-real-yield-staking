// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "./utils/StakingFixture.sol";

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
}
