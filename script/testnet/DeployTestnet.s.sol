// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {DeployDexynthStaking} from "../DeployDexynthStaking.s.sol";
import {DexynthStakingV2_2} from "../../src/DexynthStaking.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";

/**
 * @title DeployTestnet
 * @notice Public testnet deployment of the demo (Base Sepolia by default): the faucet with its DEXY and USDC
 *         stand-ins, the staking contract, five seed stakes and a funded reward stream. Testnet only
 * @dev What differs from DeployDexynthStaking.s.sol, and why:
 *      - Tokens: TestnetFaucet deploys DEXY (18 decimals) and a 6-decimal USDC stand-in as the reward token.
 *      - Time: epochs of 1 day, the constructor's minimum, and locks of 1 hour to 14 days instead of 30 to 720
 *        days, so a visitor can unstake a level 0 stake within about a day. The multipliers are the deploy
 *        script's, read from DeployDexynthStaking._levels().
 *      - Seed: the faucet stakes SEED_TOTAL DEXY across the five levels before the stream is funded, so the pool is
 *        never empty and no dust stake can be alone in it when the stream starts. The faucet cannot unstake.
 *      - Stream: STREAM_AMOUNT USDC over STREAM_DURATION, funded by the deployer, who stays the owner.
 *      The protocol has no oracle or other external dependency. Before anything is sent, the script runs a smoke
 *      test in simulation: a fresh address claims, stakes, earns for an hour and harvests, and the run reverts if
 *      any step fails. On a --broadcast run it writes the addresses to a pending file in cache/. Forge runs the whole
 *      script before it sends anything, so that file can name contracts a failed broadcast never deployed:
 *      ConfirmDeployment.s.sol checks them on the chain and only then writes the deployment file the app reads.
 *
 *      Usage (Base Sepolia):
 *        forge script script/testnet/DeployTestnet.s.sol --rpc-url https://sepolia.base.org \
 *          --account <keystore> --broadcast
 *        forge script script/testnet/ConfirmDeployment.s.sol --rpc-url https://sepolia.base.org
 *      Optional env: PENDING_FILE.
 */
contract DeployTestnet is DeployDexynthStaking {
    /**
     * @notice The smoke test found the deployment unusable
     */
    error SmokeTestFailed(string reason);

    /**
     * @notice Epoch length of the demo, the minimum the constructor accepts
     */
    uint256 public constant DEMO_EPOCH = 1 days;

    /**
     * @notice USDC streamed by the initial funding, 6 decimals
     */
    uint256 public constant STREAM_AMOUNT = 100_000e6;

    /**
     * @notice Length of the initial stream
     */
    uint256 public constant STREAM_DURATION = 365 days;

    /**
     * @notice DEXY staked by the faucet across the five levels
     */
    uint256 public constant SEED_TOTAL = 1_000_000e18;

    /**
     * @notice Everything the run deploys
     */
    struct TestnetDeployment {
        TestnetFaucet faucet;
        DexynthStakingV2_2 staking;
        address owner;
        uint256 deployBlock;
    }

    /**
     * @notice The contracts of the last run, for tests and the deployment file
     */
    TestnetDeployment public deployment;

    function run() external override {
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        TestnetFaucet faucet = new TestnetFaucet(deployer);
        address usdc = address(faucet.USDC());
        DexynthStakingV2_2 staking = new DexynthStakingV2_2(address(faucet.DEXY()), usdc, demoLevels(), DEMO_EPOCH);

        // Seed first: a stream funded into an empty pool would go to the first staker alone, however small
        uint256[5] memory seed = seedAmounts();
        for (uint8 i = 0; i < seed.length; i++) {
            faucet.seedStake(address(staking), i, seed[i]);
        }

        faucet.mint(usdc, deployer, STREAM_AMOUNT);
        IERC20(usdc).approve(address(staking), STREAM_AMOUNT);
        staking.addStakingReward(STREAM_AMOUNT, STREAM_DURATION);

        vm.stopBroadcast();

        deployment = TestnetDeployment({faucet: faucet, staking: staking, owner: deployer, deployBlock: deployBlock});

        _smokeTest(faucet, staking);

        // Only on a --broadcast run, and still to a pending file: forge has not sent anything yet at this point
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) vm.writeJson(deploymentJson(), pendingFile());

        console2.log("Staking:", address(staking));
        console2.log("Faucet:", address(faucet));
    }

    /**
     * @notice The deploy script's levels with the demo lock periods: 1 hour, 1 day, 3 days, 7 days and 14 days
     */
    function demoLevels() public pure returns (DexynthStakingV2_2.Level[] memory levels) {
        levels = _levels();
        uint32[5] memory locks = [uint32(1 hours), 1 days, 3 days, 7 days, 14 days];
        for (uint256 i = 0; i < locks.length; i++) {
            levels[i].lockingPeriod = locks[i];
        }
    }

    /**
     * @notice DEXY the faucet stakes in each level, SEED_TOTAL in all
     */
    function seedAmounts() public pure returns (uint256[5] memory) {
        return [uint256(100_000e18), 150_000e18, 250_000e18, 250_000e18, 250_000e18];
    }

    /**
     * @notice Where the run records the addresses for ConfirmDeployment: PENDING_FILE, or a file in cache/ per chain
     */
    function pendingFile() public view returns (string memory) {
        string memory defaultPath = string.concat("cache/testnet-deployment-", vm.toString(block.chainid), ".json");
        return vm.envOr("PENDING_FILE", defaultPath);
    }

    /**
     * @dev Simulation only, after stopBroadcast, and rolled back afterwards: a fresh address does what a visitor does
     *      in the app. Any failure reverts the run before anything is sent
     */
    function _smokeTest(TestnetFaucet _faucet, DexynthStakingV2_2 _staking) internal {
        uint256 snapshot = vm.snapshotState();
        // A throwaway sender: forge rejects scripts that rely on their own ephemeral address
        address visitor = makeAddr("DeployTestnet smoke test");
        uint256 drip = _faucet.DEXY_DRIP();
        IERC20 usdc = IERC20(address(_faucet.USDC()));

        vm.startPrank(visitor, visitor);
        _faucet.claim();
        _faucet.DEXY().approve(address(_staking), drip);
        _staking.stake(drip, 0);
        vm.warp(block.timestamp + 1 hours);
        uint256 pending = _staking.pendingRewards(visitor);
        if (pending == 0) revert SmokeTestFailed("no rewards after an hour");
        _staking.harvest();
        vm.stopPrank();

        if (usdc.balanceOf(visitor) != pending) revert SmokeTestFailed("harvest paid a different amount");
        vm.revertToState(snapshot);
    }

    /**
     * @notice The addresses the app needs, as the JSON of its deployment file. The app reads every parameter (levels,
     *         epoch, stream) from the contracts themselves
     */
    function deploymentJson() public returns (string memory) {
        TestnetDeployment memory d = deployment;
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", d.deployBlock);
        vm.serializeAddress(root, "staking", address(d.staking));
        vm.serializeAddress(root, "faucet", address(d.faucet));
        vm.serializeAddress(root, "dexy", address(d.faucet.DEXY()));
        vm.serializeAddress(root, "rewardToken", address(d.faucet.USDC()));
        return vm.serializeAddress(root, "owner", d.owner);
    }
}
