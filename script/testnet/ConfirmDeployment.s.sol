// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {DeployTestnet} from "./DeployTestnet.s.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";
import {DexynthStakingV2_3} from "../../src/DexynthStaking.sol";

/**
 * @title ConfirmDeployment
 * @notice Checks on the chain the deployment that DeployTestnet.s.sol recorded in its pending file, then writes the
 *         deployment file the app reads. Testnet only, read-only: it sends nothing
 * @dev DeployTestnet runs in full before forge sends a transaction, so its pending file can name contracts that a
 *      failed broadcast never deployed. This script reads the chain instead: every address must hold code and the
 *      contracts must be wired and configured as DeployTestnet sets them up (tokens, owner, feeder, epoch, levels,
 *      seed, and the first deposit queued for or streaming in epoch 0). Anything else reverts and leaves the app's
 *      file as it was. Run it right after the deployment, within epoch 0. If the RPC has not caught up with the
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
        DexynthStakingV2_3 staking = DexynthStakingV2_3(vm.parseJsonAddress(json, ".staking"));
        TestnetFaucet faucet = TestnetFaucet(vm.parseJsonAddress(json, ".faucet"));
        address dexy = vm.parseJsonAddress(json, ".dexy");
        address reward = vm.parseJsonAddress(json, ".rewardToken");
        address owner = vm.parseJsonAddress(json, ".owner");
        address feeder = vm.parseJsonAddress(json, ".feeder");
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) revert Mismatch("chain id");

        _hasCode("staking", address(staking));
        _hasCode("faucet", address(faucet));
        _hasCode("dexy", dexy);
        _hasCode("rewardToken", reward);

        if (address(faucet.DEXY()) != dexy || address(faucet.USDC()) != reward) revert Mismatch("faucet tokens");
        if (staking.DEXY() != dexy || staking.REWARD_TOKEN() != reward) revert Mismatch("staking tokens");
        if (staking.owner() != owner || faucet.owner() != owner) revert Mismatch("owner");
        if (faucet.feeder() != feeder) revert Mismatch("feeder");
        if (staking.epochDuration() != expected.DEMO_EPOCH()) revert Mismatch("epoch");

        DexynthStakingV2_3.Level[] memory want = expected.demoLevels();
        DexynthStakingV2_3.Level[] memory live = staking.getLevels();
        if (live.length != want.length) revert Mismatch("level count");
        for (uint256 i = 0; i < want.length; i++) {
            if (live[i].lockingPeriod != want[i].lockingPeriod || live[i].boostP != want[i].boostP) {
                revert Mismatch("levels");
            }
        }

        (,, uint128 seeded,,,) = staking.users(address(faucet));
        if (seeded != expected.SEED_TOTAL()) revert Mismatch("seed");
        // The pool state is written lazily: until a call after the start, epoch 0's rewards are still queued
        uint256 genesis = staking.I_GENESIS_EPOCH_TIMESTAMP();
        uint256 next = staking.nextEpochStart();
        bool queued = next == genesis && staking.queuedRewards() >= expected.INITIAL_REWARDS() * 1e36;
        bool streaming = next == genesis + expected.DEMO_EPOCH() && staking.rewardRate() > 0;
        if (!queued && !streaming) revert Mismatch("first deposit");

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
