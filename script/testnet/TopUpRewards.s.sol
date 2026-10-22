// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";

/**
 * @title TopUpRewards
 * @notice Funds the demo's reward stream again: mints TOP_UP_USDC testnet USDC through the faucet and calls
 *         addStakingReward over TOP_UP_DAYS days. Testnet only, run by the owner of the staking contract and the
 *         faucet (the deployer of DeployTestnet.s.sol)
 * @dev addStakingReward spreads the new amount plus whatever the current stream has not streamed yet over the new
 *      duration, so the rate changes for every staker from the block the top-up lands in. Nothing in it depends on a
 *      price or a short time window, so it can be run at any time. A caller that is not the owner reverts in the
 *      simulation, before anything is sent.
 *
 *      Usage (Base Sepolia), reading the addresses from app/src/config/deployments/84532.json:
 *        TOP_UP_USDC=100000 TOP_UP_DAYS=365 forge script script/testnet/TopUpRewards.s.sol \
 *          --rpc-url https://sepolia.base.org --account <keystore> --broadcast
 *      Optional env: DEPLOYMENT_FILE.
 */
contract TopUpRewards is Script {
    function run() external {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", defaultPath));
        DexynthStakingV2_2 staking = DexynthStakingV2_2(vm.parseJsonAddress(json, ".staking"));
        TestnetFaucet faucet = TestnetFaucet(vm.parseJsonAddress(json, ".faucet"));

        uint256 amount = vm.envUint("TOP_UP_USDC") * 1e6;
        uint256 duration = vm.envUint("TOP_UP_DAYS") * 1 days;
        topUp(staking, faucet, amount, duration);
    }

    /**
     * @notice Mints _amount USDC to the caller through the faucet and funds the stream with it over _duration
     */
    function topUp(DexynthStakingV2_2 _staking, TestnetFaucet _faucet, uint256 _amount, uint256 _duration) public {
        address usdc = address(_faucet.USDC());

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        _faucet.mint(usdc, sender, _amount);
        IERC20(usdc).approve(address(_staking), _amount);
        _staking.addStakingReward(_amount, _duration);
        vm.stopBroadcast();

        console2.log("Reward rate (USDC units per second, scaled by 1e36):", _staking.rewardRate());
        console2.log("Stream ends at:", _staking.rewardEndTime());
    }
}
