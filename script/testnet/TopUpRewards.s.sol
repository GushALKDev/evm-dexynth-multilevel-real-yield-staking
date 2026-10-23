// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {DexynthStakingV2_3} from "../../src/DexynthStaking.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";

/**
 * @title TopUpRewards
 * @notice Deposits extra rewards in the demo by hand: mints TOP_UP_USDC testnet USDC through the faucet and deposits
 *         it with addStakingReward, streamed over the next epoch to start. Testnet only, run by the owner of the
 *         faucet (the deployer of DeployTestnet.s.sol). The feeder's daily deposits do not need it
 * @dev The deposit joins whatever is already queued for the next epoch and leaves the running epoch unchanged.
 *      Nothing in it depends on a price or a short time window, so it can be run at any time. A caller that is not
 *      the faucet's owner reverts in the simulation, before anything is sent.
 *
 *      Usage (Base Sepolia), reading the addresses from app/src/config/deployments/84532.json:
 *        TOP_UP_USDC=1000 forge script script/testnet/TopUpRewards.s.sol \
 *          --rpc-url https://sepolia.base.org --account <keystore> --broadcast
 *      Optional env: DEPLOYMENT_FILE.
 */
contract TopUpRewards is Script {
    function run() external {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", defaultPath));
        DexynthStakingV2_3 staking = DexynthStakingV2_3(vm.parseJsonAddress(json, ".staking"));
        TestnetFaucet faucet = TestnetFaucet(vm.parseJsonAddress(json, ".faucet"));

        uint256 amount = vm.envUint("TOP_UP_USDC") * 1e6;
        topUp(staking, faucet, amount);
    }

    /**
     * @notice Mints _amount USDC to the caller through the faucet and deposits it for the next epoch
     */
    function topUp(DexynthStakingV2_3 _staking, TestnetFaucet _faucet, uint256 _amount) public {
        address usdc = address(_faucet.USDC());

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        _faucet.mint(usdc, sender, _amount);
        IERC20(usdc).approve(address(_staking), _amount);
        _staking.addStakingReward(_amount);
        vm.stopBroadcast();

        console2.log("Queued for the next epoch (USDC units, scaled by 1e36):", _staking.queuedRewards());
        console2.log("Next epoch starts at:", _staking.nextEpochStart());
    }
}
