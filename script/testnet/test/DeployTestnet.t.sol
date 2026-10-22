// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {DeployDexynthStaking} from "../../DeployDexynthStaking.s.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";
import {TopUpRewards} from "../TopUpRewards.s.sol";
import {TestnetFaucet, TestnetToken} from "../TestnetFaucet.sol";
import {DexynthStakingV2_2} from "../../../src/DexynthStaking.sol";

/**
 * @dev Exposes the deploy script's levels, to check the testnet keeps its multipliers
 */
contract DeployHarness is DeployDexynthStaking {
    function levels() external pure returns (DexynthStakingV2_2.Level[] memory) {
        return _levels();
    }
}

/**
 * @title DeployTestnetTest
 * @notice Rehearses DeployTestnet.s.sol, then drives the deployment the way the demo app does: claim, approve the
 *         exact amount, stake, harvest and unstake, plus the failure modes and what a stranger can try
 * @dev Run with FOUNDRY_PROFILE=testnet. Outside a --broadcast run the deploy script writes no file
 */
contract DeployTestnetTest is Test {
    string internal constant DRY_RUN_FILE = "cache/testnet-dry-run-must-not-exist.json";

    address internal constant VISITOR = address(0xA11CE);
    address internal constant GRIEFER = address(0xBAD);

    DeployTestnet internal script;
    DexynthStakingV2_2 internal staking;
    TestnetFaucet internal faucet;
    TestnetToken internal dexy;
    TestnetToken internal usdc;
    address internal owner;
    uint256 internal deployedAt;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.setEnv("PENDING_FILE", DRY_RUN_FILE);
        script = new DeployTestnet();
        script.run();
        (faucet, staking, owner,) = script.deployment();
        dexy = faucet.DEXY();
        usdc = faucet.USDC();
        deployedAt = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_LevelsKeepTheDeployMultipliersWithDemoLocks() public {
        DexynthStakingV2_2.Level[] memory production = new DeployHarness().levels();
        DexynthStakingV2_2.Level[] memory live = staking.getLevels();
        uint32[5] memory locks = [uint32(1 hours), 1 days, 3 days, 7 days, 14 days];
        assertEq(live.length, production.length);
        for (uint256 i = 0; i < live.length; i++) {
            assertEq(live[i].boostP, production[i].boostP, "multiplier");
            assertEq(live[i].lockingPeriod, locks[i], "lock");
        }
        assertEq(staking.epochDuration(), 1 days);
        assertEq(staking.I_GENESIS_EPOCH_TIMESTAMP(), deployedAt);
    }

    function test_TokensAndOwnership() public view {
        assertEq(staking.DEXY(), address(dexy));
        assertEq(staking.REWARD_TOKEN(), address(usdc));
        assertEq(staking.owner(), owner);
        assertEq(faucet.owner(), owner);
    }

    function test_SeedIsStakedByTheFaucetInEveryLevel() public view {
        uint256[5] memory seed = script.seedAmounts();
        DexynthStakingV2_2.Level[] memory live = staking.getLevels();
        uint256 sum;
        uint256 boosted;
        for (uint256 i = 0; i < seed.length; i++) {
            assertEq(live[i].totalStaked, seed[i], "level total");
            sum += seed[i];
            boosted += seed[i] * live[i].boostP / 1e10;
        }
        assertEq(sum, script.SEED_TOTAL());
        (uint64 stakeCount,, uint128 totalStakedDexy, uint128 boostedBalance,,) = staking.users(address(faucet));
        assertEq(stakeCount, 5);
        assertEq(totalStakedDexy, sum);
        assertEq(boostedBalance, boosted);
        assertEq(staking.totalBoostedStake(), boosted);
        assertEq(dexy.balanceOf(address(staking)), sum);
    }

    function test_StreamIsFundedAfterTheSeed() public view {
        assertEq(staking.rewardRate(), uint256(100_000e6) * 1e36 / 365 days);
        assertEq(staking.rewardEndTime(), deployedAt + 365 days);
        assertEq(staking.totalRewardsFunded(), 100_000e6);
        assertEq(usdc.balanceOf(address(staking)), 100_000e6);
        // Funded after the seed, so nothing was streamed into an empty pool
        assertEq(staking.unallocatedRewards(), 0);
    }

    function test_DryRunWritesNoPendingFile() public view {
        assertFalse(vm.exists(DRY_RUN_FILE));
        assertEq(script.pendingFile(), DRY_RUN_FILE);
    }

    function test_SmokeTestLeavesNoTrace() public {
        address smoke = makeAddr("DeployTestnet smoke test");
        (uint64 stakeCount,,,,,) = staking.users(smoke);
        assertEq(stakeCount, 0);
        assertEq(faucet.lastClaim(smoke), 0);
        assertEq(usdc.balanceOf(smoke), 0);
        assertEq(block.timestamp, deployedAt);
    }

    /*//////////////////////////////////////////////////////////////
                           APP-LIKE FLOWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The calls the app sends, in order: claim, approve of the exact amount, stake, harvest, unstake
     */
    function test_VisitorStakesHarvestsAndUnstakes() public {
        uint256 amount = 2_500e18;
        vm.warp(deployedAt + 6 hours);
        _claimAndStake(VISITOR, amount, 0);
        DexynthStakingV2_2.Stake memory s = _stake(VISITOR, 0);
        // Next epoch start (deploy + 1 day) plus the level 0 lock of 1 hour
        assertEq(s.unlockTime, deployedAt + 1 days + 1 hours);
        assertEq(s.boostedAmount, amount * 65 / 100);

        vm.warp(deployedAt + 12 hours);
        uint256 expected = _appPending(VISITOR, block.timestamp);
        assertEq(staking.pendingRewards(VISITOR), expected, "app projection");
        vm.prank(VISITOR);
        staking.harvest();
        assertEq(usdc.balanceOf(VISITOR), expected, "harvested");

        vm.warp(s.unlockTime - 1);
        vm.expectRevert(DexynthStakingV2_2.StakeStillLocked.selector);
        vm.prank(VISITOR);
        staking.unstake(0);

        vm.warp(s.unlockTime);
        uint256 more = _appPending(VISITOR, block.timestamp);
        vm.prank(VISITOR);
        staking.unstake(0);
        assertEq(dexy.balanceOf(VISITOR), 10_000e18, "principal back");
        assertEq(usdc.balanceOf(VISITOR), expected + more, "unstake pays the rest");
    }

    function test_StakeOneSecondBeforeTheEpochTurnsUnlocksALockLater() public {
        vm.warp(deployedAt + 1 days - 1);
        _claimAndStake(VISITOR, 1_000e18, 1);
        assertEq(_stake(VISITOR, 0).unlockTime, deployedAt + 1 days + 1 days);

        vm.warp(deployedAt + 1 days);
        vm.startPrank(VISITOR);
        dexy.approve(address(staking), 1_000e18);
        staking.stake(1_000e18, 1);
        vm.stopPrank();
        assertEq(_stake(VISITOR, 1).unlockTime, deployedAt + 2 days + 1 days, "one epoch later");
    }

    function test_RewardsStopAtTheEndOfTheStream() public {
        _claimAndStake(VISITOR, 1_000e18, 4);
        vm.warp(deployedAt + 365 days);
        uint256 atEnd = staking.pendingRewards(VISITOR);
        vm.warp(deployedAt + 400 days);
        assertEq(staking.pendingRewards(VISITOR), atEnd);
        assertEq(_appPending(VISITOR, block.timestamp), atEnd);
    }

    /*//////////////////////////////////////////////////////////////
                            FAILURE MODES
    //////////////////////////////////////////////////////////////*/

    function test_HarvestWithoutStakeReverts() public {
        vm.expectRevert(DexynthStakingV2_2.NoStakedTokens.selector);
        vm.prank(VISITOR);
        staking.harvest();
    }

    function test_SecondHarvestInTheSameBlockReverts() public {
        _claimAndStake(VISITOR, 1_000e18, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(VISITOR);
        staking.harvest();
        vm.expectRevert(DexynthStakingV2_2.NoRewardsToHarvest.selector);
        staking.harvest();
        vm.stopPrank();
    }

    function test_StakeFailures() public {
        vm.startPrank(VISITOR);
        faucet.claim();
        // 1 wei at 0.65x boosts to zero
        dexy.approve(address(staking), type(uint256).max);
        vm.expectRevert(DexynthStakingV2_2.ZeroBoostedStake.selector);
        staking.stake(1, 0);
        vm.expectRevert(DexynthStakingV2_2.WrongParams.selector);
        staking.stake(1e18, 5);
        vm.expectRevert(DexynthStakingV2_2.WrongParams.selector);
        staking.stake(0, 0);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        staking.stake(10_001e18, 0);
        dexy.approve(address(staking), 1e18);
        vm.expectRevert("ERC20: insufficient allowance");
        staking.stake(2e18, 0);
        vm.stopPrank();
    }

    function test_UnstakeFailures() public {
        _claimAndStake(VISITOR, 1_000e18, 0);
        vm.startPrank(VISITOR);
        vm.expectRevert(DexynthStakingV2_2.StakeNotFound.selector);
        staking.unstake(1);
        vm.warp(_stake(VISITOR, 0).unlockTime);
        staking.unstake(0);
        vm.expectRevert(DexynthStakingV2_2.AlreadyUnstaked.selector);
        staking.unstake(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              GRIEFING
    //////////////////////////////////////////////////////////////*/

    function test_StrangerCannotTouchTheStreamOrMigrate() public {
        vm.startPrank(GRIEFER);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.addStakingReward(0, 1);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.requestMigration(GRIEFER);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.renounceOwnership();
        vm.expectRevert("Ownable: caller is not the owner");
        staking.transferOwnership(GRIEFER);
        vm.stopPrank();
    }

    /**
     * @dev A griefer stakes dust every block and donates tokens to the contract: visitors still stake, earn their
     *      exact share, harvest and unstake
     */
    function test_DustStakesAndDonationsDoNotBlockVisitors() public {
        vm.startPrank(GRIEFER);
        faucet.claim();
        dexy.approve(address(staking), type(uint256).max);
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + 2);
            staking.stake(2, 0);
        }
        dexy.transfer(address(staking), 1_000e18);
        vm.stopPrank();

        _claimAndStake(VISITOR, 1_000e18, 0);
        vm.warp(block.timestamp + 6 hours);
        uint256 expected = _appPending(VISITOR, block.timestamp);
        vm.prank(VISITOR);
        staking.harvest();
        assertEq(usdc.balanceOf(VISITOR), expected);
        vm.warp(_stake(VISITOR, 0).unlockTime);
        vm.prank(VISITOR);
        staking.unstake(0);
        assertEq(dexy.balanceOf(VISITOR), 10_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                               TOP UP
    //////////////////////////////////////////////////////////////*/

    function test_TopUpSpreadsTheLeftoverAndTheNewAmount() public {
        vm.warp(deployedAt + 100 days);
        uint256 leftover = (staking.rewardEndTime() - block.timestamp) * staking.rewardRate();
        new TopUpRewards().topUp(staking, faucet, 50_000e6, 180 days);
        assertEq(staking.rewardRate(), (leftover + uint256(50_000e6) * 1e36) / 180 days);
        assertEq(staking.rewardEndTime(), block.timestamp + 180 days);
        assertEq(staking.totalRewardsFunded(), 150_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _claimAndStake(address _user, uint256 _amount, uint8 _level) internal {
        vm.startPrank(_user);
        faucet.claim();
        dexy.approve(address(staking), _amount);
        staking.stake(_amount, _level);
        vm.stopPrank();
    }

    function _stake(address _user, uint64 _index) internal view returns (DexynthStakingV2_2.Stake memory s) {
        (s.unstaked, s.level, s.timestamp, s.unlockTime, s.stakedDexy, s.boostedAmount) =
            staking.stakeInfo(_user, _index);
    }

    /**
     * @dev The app's projection (app/src/lib/staking.ts): the accumulator advanced to _t, capped at the stream's end,
     *      then the user's settlement rounded down
     */
    function _appPending(address _user, uint256 _t) internal view returns (uint256) {
        (, uint128 stored,, uint128 boosted,, uint256 snapshot) = staking.users(_user);
        uint256 acc = staking.accRewardPerBoostedShare();
        uint256 last = staking.lastRewardTime();
        uint256 end = Math.min(_t, staking.rewardEndTime());
        uint256 total = staking.totalBoostedStake();
        if (end > last && total > 0) acc += (end - last) * staking.rewardRate() / total;
        return stored + Math.mulDiv(boosted, acc - snapshot, 1e36);
    }
}
