// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {DeployTestnet} from "./DeployTestnet.s.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";
import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";

/**
 * @title ConfirmDeployment
 * @notice Checks on the chain the deployment that DeployTestnet.s.sol recorded in its pending file, then writes the
 *         deployment file the app reads. Testnet only, read-only: it sends nothing
 * @dev DeployTestnet runs in full before forge sends a transaction, so its pending file can name contracts that a
 *      failed broadcast never deployed. This script reads the chain instead: every address must hold code and the
 *      contracts must be wired and configured as DeployTestnet sets them up (tokens, owner, epoch, levels, seed,
 *      stream). Anything else reverts and leaves the app's file as it was. If the RPC has not caught up with the
 *      deployment yet, run it again.
 *
 *      Usage (Base Sepolia), after DeployTestnet.s.sol:
 *        forge script script/testnet/ConfirmDeployment.s.sol --rpc-url https://sepolia.base.org
 *      Optional env: PENDING_FILE, DEPLOYMENT_FILE.
 */
contract ConfirmDeployment is Script {
    /**
     * @notice A recorded address holds no code on this chain
     */
    error NotDeployed(string name, address at);

    /**
     * @notice A deployed contract is not set up as DeployTestnet sets it up
     */
    error Mismatch(string what);

    function run() external {
        // Deployed locally only, for its configuration and pending file path; nothing is broadcast
        confirm(new DeployTestnet().pendingFile(), deploymentFile());
    }

    /**
     * @notice Checks the deployment recorded in _pendingFile and, if it holds, writes _appFile
     */
    function confirm(string memory _pendingFile, string memory _appFile) public {
        DeployTestnet expected = new DeployTestnet();
        string memory json = vm.readFile(_pendingFile);
        DexynthStakingV2_2 staking = DexynthStakingV2_2(vm.parseJsonAddress(json, ".staking"));
        TestnetFaucet faucet = TestnetFaucet(vm.parseJsonAddress(json, ".faucet"));
        address dexy = vm.parseJsonAddress(json, ".dexy");
        address reward = vm.parseJsonAddress(json, ".rewardToken");
        address owner = vm.parseJsonAddress(json, ".owner");
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) revert Mismatch("chain id");

        _hasCode("staking", address(staking));
        _hasCode("faucet", address(faucet));
        _hasCode("dexy", dexy);
        _hasCode("rewardToken", reward);

        if (address(faucet.DEXY()) != dexy || address(faucet.USDC()) != reward) revert Mismatch("faucet tokens");
        if (staking.DEXY() != dexy || staking.REWARD_TOKEN() != reward) revert Mismatch("staking tokens");
        if (staking.owner() != owner || faucet.owner() != owner) revert Mismatch("owner");
        if (staking.epochDuration() != expected.DEMO_EPOCH()) revert Mismatch("epoch");

        DexynthStakingV2_2.Level[] memory want = expected.demoLevels();
        DexynthStakingV2_2.Level[] memory live = staking.getLevels();
        if (live.length != want.length) revert Mismatch("level count");
        for (uint256 i = 0; i < want.length; i++) {
            if (live[i].lockingPeriod != want[i].lockingPeriod || live[i].boostP != want[i].boostP) {
                revert Mismatch("levels");
            }
        }

        (,, uint128 seeded,,,) = staking.users(address(faucet));
        if (seeded != expected.SEED_TOTAL()) revert Mismatch("seed");
        if (staking.totalRewardsFunded() < expected.STREAM_AMOUNT() || staking.rewardRate() == 0) {
            revert Mismatch("stream");
        }

        vm.writeJson(json, _appFile);
        console2.log("Confirmed, wrote", _appFile);
    }

    /**
     * @notice Where the app's deployment file lives: DEPLOYMENT_FILE, or the app's file for this chain id
     */
    function deploymentFile() public view returns (string memory) {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        return vm.envOr("DEPLOYMENT_FILE", defaultPath);
    }

    function _hasCode(string memory _name, address _at) internal view {
        if (_at.code.length == 0) revert NotDeployed(_name, _at);
    }
}
