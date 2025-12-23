// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/DexynthStaking.sol";

contract DeployDexynthStaking is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address dexy = vm.envAddress("DEXY_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");
        
        vm.startBroadcast(deployerPrivateKey);

        DexynthStakingV1.Level[] memory levels = new DexynthStakingV1.Level[](5);
        // [[2592000, 6500000000], [7776000, 8500000000], [15552000, 10000000000], [31536000, 11500000000], [62208000, 13500000000]]
        levels[0] = DexynthStakingV1.Level(2592000, 6500000000);
        levels[1] = DexynthStakingV1.Level(7776000, 8500000000);
        levels[2] = DexynthStakingV1.Level(15552000, 10000000000);
        levels[3] = DexynthStakingV1.Level(31536000, 11500000000);
        levels[4] = DexynthStakingV1.Level(62208000, 13500000000);

        uint256 epochDuration = 1296000; // 15 days

        new DexynthStakingV1(dexy, usdt, levels, epochDuration);

        vm.stopBroadcast();
    }
}
