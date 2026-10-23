// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {DexynthStakingV2_3} from "../src/DexynthStaking.sol";

contract DeployDexynthStaking is Script {
    uint256 internal constant EPOCH_DURATION = 1296000; // 15 days

    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address dexy = vm.envAddress("DEXY_ADDRESS");
        address rewardToken = vm.envAddress("REWARD_TOKEN_ADDRESS");
        // Start of epoch 0, a timestamp after the deployment. The rewards deposited before it stream during epoch 0
        uint256 firstEpochStart = vm.envUint("FIRST_EPOCH_START");

        vm.startBroadcast(deployerPrivateKey);

        new DexynthStakingV2_3(dexy, rewardToken, _levels(), EPOCH_DURATION, firstEpochStart);

        vm.stopBroadcast();
    }

    function _levels() internal pure returns (DexynthStakingV2_3.Level[] memory levels) {
        levels = new DexynthStakingV2_3.Level[](5);
        // Level(lockingPeriod, boostP, totalStaked)
        levels[0] = DexynthStakingV2_3.Level(2592000, 6500000000, 0);
        levels[1] = DexynthStakingV2_3.Level(7776000, 8500000000, 0);
        levels[2] = DexynthStakingV2_3.Level(15552000, 10000000000, 0);
        levels[3] = DexynthStakingV2_3.Level(31536000, 11500000000, 0);
        levels[4] = DexynthStakingV2_3.Level(62208000, 13500000000, 0);
    }
}
