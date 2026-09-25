// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DexynthStakingV1} from "../bench/DexynthStakingV1.sol";
import {DexynthStakingV2_2} from "../src/DexynthStaking.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/**
 * @notice Gas benchmarks of v1 (bench/, original Dexynth contract) and v2.2 under the same named scenarios
 * @dev Run with `FOUNDRY_PROFILE=gas forge test`. Each scenario measures one call with vm.snapshotGasLastCall,
 *      which writes the value to snapshots/<group>.json (groups "v1" and "v2_2"). Figures are the gas of the call
 *      itself, without the 21,000 intrinsic transaction gas and calldata cost.
 *
 *      Common setup for both versions:
 *      - 15 day epochs. Levels use the example multipliers (0.65x, 0.85x, 1.0x, 1.15x, 1.35x) and the example
 *        locks, except that level 0 has no lock so that unstake can be measured one epoch after staking.
 *      - bob stakes 1000 DEXY at level 2, then 1,000,000 reward tokens are added (v2.2 streams them over
 *        3650 days, v1 splits them over the epochs it closes).
 *      - "after N epochs" means the call happens N + 1 epochs and 1 hour after alice's stake: v1 only pays rewards
 *        for epochs that start after the stake and have been closed, so this gives both versions N rewarded epochs.
 *      - Every measured call is 1 hour into an epoch. The original v1 computes epoch start times with
 *        (epochDuration + 1) * index, which drifts 1 second per epoch, and its checkForClosingEpochs underflows in
 *        the first L + 1 seconds of an epoch once L epochs are closed. The offset keeps v1 out of that window.
 */
abstract contract GasScenarios is Test {
    uint256 internal constant EPOCH = 15 days;
    uint256 internal constant OFFSET = 1 hours;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    MockERC20 internal dexy;
    MockERC20 internal reward;

    function _group() internal pure virtual returns (string memory);
    function _deployStaking() internal virtual returns (address);
    function _stake(address _user, uint256 _amount, uint8 _level) internal virtual;
    function _unstake(address _user, uint64 _index) internal virtual;
    function _harvest(address _user) internal virtual;
    function _addReward(uint256 _amount) internal virtual;

    function setUp() public {
        vm.warp(2_000_000_000);
        dexy = new MockERC20("Dexy Token", "DEXY", 18);
        reward = new MockERC20("Reward Token", "RWD", 18);
        address staking = _deployStaking();
        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            dexy.mint(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            dexy.approve(staking, type(uint256).max);
        }
        reward.mint(address(this), 1_000_000 ether);
        reward.approve(staking, type(uint256).max);

        _stake(bob, 1000 ether, 2);
        _addReward(1_000_000 ether);
    }

    function _snap(string memory _name) internal {
        vm.snapshotGasLastCall(_group(), _name);
    }

    /**
     * @notice alice's first stake, 1000 DEXY at level 0, with bob already staked
     */
    function test_stake_first() public {
        _stake(alice, 1000 ether, 0);
        _snap("stake_first");
    }

    /**
     * @notice alice's second stake in the same block, 1000 DEXY at level 0
     */
    function test_stake_subsequent() public {
        _stake(alice, 1000 ether, 0);
        _stake(alice, 1000 ether, 0);
        _snap("stake_subsequent");
    }

    function _harvestAfterEpochs(uint256 _epochs, string memory _name) internal {
        _stake(alice, 1000 ether, 0);
        vm.warp(block.timestamp + (_epochs + 1) * EPOCH + OFFSET);
        _harvest(alice);
        _snap(_name);
    }

    /**
     * @notice harvest of alice's single stake after N rewarded epochs
     */
    function test_harvest_after_1_epoch() public {
        _harvestAfterEpochs(1, "harvest_after_1_epoch");
    }

    function test_harvest_after_10_epochs() public {
        _harvestAfterEpochs(10, "harvest_after_10_epochs");
    }

    function test_harvest_after_52_epochs() public {
        _harvestAfterEpochs(52, "harvest_after_52_epochs");
    }

    function test_harvest_after_100_epochs() public {
        _harvestAfterEpochs(100, "harvest_after_100_epochs");
    }

    function _unstakeAfterEpochs(uint256 _epochs, string memory _name) internal {
        _stake(alice, 1000 ether, 0);
        vm.warp(block.timestamp + (_epochs + 1) * EPOCH + OFFSET);
        _unstake(alice, 0);
        _snap(_name);
    }

    /**
     * @notice unstake of alice's single level 0 stake after N rewarded epochs, rewards included
     */
    function test_unstake_after_1_epoch() public {
        _unstakeAfterEpochs(1, "unstake_after_1_epoch");
    }

    function test_unstake_after_10_epochs() public {
        _unstakeAfterEpochs(10, "unstake_after_10_epochs");
    }

    function test_unstake_after_52_epochs() public {
        _unstakeAfterEpochs(52, "unstake_after_52_epochs");
    }

    function test_unstake_after_100_epochs() public {
        _unstakeAfterEpochs(100, "unstake_after_100_epochs");
    }

    function _harvestWithStakes(uint256 _stakes, string memory _name) internal {
        for (uint256 i = 0; i < _stakes; i++) {
            _stake(alice, 100 ether, 0);
        }
        vm.warp(block.timestamp + 2 * EPOCH + OFFSET);
        _harvest(alice);
        _snap(_name);
    }

    /**
     * @notice harvest after 1 rewarded epoch when alice holds N stakes of 100 DEXY at level 0
     */
    function test_harvest_with_1_stake() public {
        _harvestWithStakes(1, "harvest_with_1_stake");
    }

    function test_harvest_with_10_stakes() public {
        _harvestWithStakes(10, "harvest_with_10_stakes");
    }

    function test_harvest_with_100_stakes() public {
        _harvestWithStakes(100, "harvest_with_100_stakes");
    }

    function test_harvest_with_500_stakes() public {
        _harvestWithStakes(500, "harvest_with_500_stakes");
    }

    /**
     * @notice harvest after 1 rewarded epoch with alice's 100 DEXY stakes in 1 level or in all 5 levels
     */
    function test_harvest_levels_touched_1() public {
        _stake(alice, 100 ether, 0);
        vm.warp(block.timestamp + 2 * EPOCH + OFFSET);
        _harvest(alice);
        _snap("harvest_levels_touched_1");
    }

    function test_harvest_levels_touched_5() public {
        for (uint8 l = 0; l < 5; l++) {
            _stake(alice, 100 ether, l);
        }
        vm.warp(block.timestamp + 2 * EPOCH + OFFSET);
        _harvest(alice);
        _snap("harvest_levels_touched_5");
    }
}

contract GasV1 is GasScenarios {
    DexynthStakingV1 internal staking;

    function _group() internal pure override returns (string memory) {
        return "v1";
    }

    function _deployStaking() internal override returns (address) {
        DexynthStakingV1.Level[5] memory levels = [
            DexynthStakingV1.Level(0, 6500000000),
            DexynthStakingV1.Level(7776000, 8500000000),
            DexynthStakingV1.Level(15552000, 10000000000),
            DexynthStakingV1.Level(31536000, 11500000000),
            DexynthStakingV1.Level(62208000, 13500000000)
        ];
        staking = new DexynthStakingV1(address(dexy), address(reward), levels, EPOCH);
        return address(staking);
    }

    function _stake(address _user, uint256 _amount, uint8 _level) internal override {
        vm.prank(_user);
        staking.stake(_amount, _level);
    }

    function _unstake(address _user, uint64 _index) internal override {
        vm.prank(_user);
        staking.unstake(_index);
    }

    function _harvest(address _user) internal override {
        vm.prank(_user);
        staking.harvest();
    }

    function _addReward(uint256 _amount) internal override {
        staking.addStakingReward(_amount);
    }
}

contract GasV2_2 is GasScenarios {
    DexynthStakingV2_2 internal staking;

    function _group() internal pure override returns (string memory) {
        return "v2_2";
    }

    function _deployStaking() internal override returns (address) {
        DexynthStakingV2_2.Level[] memory levels = new DexynthStakingV2_2.Level[](5);
        levels[0] = DexynthStakingV2_2.Level(0, 6500000000, 0);
        levels[1] = DexynthStakingV2_2.Level(7776000, 8500000000, 0);
        levels[2] = DexynthStakingV2_2.Level(15552000, 10000000000, 0);
        levels[3] = DexynthStakingV2_2.Level(31536000, 11500000000, 0);
        levels[4] = DexynthStakingV2_2.Level(62208000, 13500000000, 0);
        staking = new DexynthStakingV2_2(address(dexy), address(reward), levels, EPOCH);
        return address(staking);
    }

    function _stake(address _user, uint256 _amount, uint8 _level) internal override {
        vm.prank(_user);
        staking.stake(_amount, _level);
    }

    function _unstake(address _user, uint64 _index) internal override {
        vm.prank(_user);
        staking.unstake(_index);
    }

    function _harvest(address _user) internal override {
        vm.prank(_user);
        staking.harvest();
    }

    function _addReward(uint256 _amount) internal override {
        staking.addStakingReward(_amount, 3650 days);
    }
}
