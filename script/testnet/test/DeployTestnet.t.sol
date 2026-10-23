// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {DeployDexynthStaking} from "../../DeployDexynthStaking.s.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";
import {TopUpRewards} from "../TopUpRewards.s.sol";
import {TestnetFaucet, TestnetToken} from "../TestnetFaucet.sol";
import {DexynthStakingV2_3} from "../../../src/DexynthStaking.sol";

/**
 * @dev Exposes the deploy script's levels, to check the testnet keeps its multipliers
 */
contract DeployHarness is DeployDexynthStaking {
    function levels() external pure returns (DexynthStakingV2_3.Level[] memory) {
        return _levels();
    }
}

/**
 * @title DeployTestnetTest
 * @notice Rehearses DeployTestnet.s.sol, then drives the deployment the way the demo app does: claim, approve the
 *         exact amount, stake, harvest, unstake and deposit, plus the failure modes and what a stranger can try
 * @dev Run with FOUNDRY_PROFILE=testnet. Outside a --broadcast run the deploy script writes no file
 */
contract DeployTestnetTest is Test {
    string internal constant DRY_RUN_FILE = "cache/testnet-dry-run-must-not-exist.json";

    address internal constant VISITOR = address(0xA11CE);
    address internal constant GRIEFER = address(0xBAD);
    address internal constant FEEDER = address(0xFEED);

    DeployTestnet internal script;
    DexynthStakingV2_3 internal staking;
    TestnetFaucet internal faucet;
    TestnetToken internal dexy;
    TestnetToken internal usdc;
    address internal owner;
    uint256 internal deployedAt;
    uint256 internal genesis;
    uint256 internal epoch;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.setEnv("PENDING_FILE", DRY_RUN_FILE);
        vm.setEnv("FEEDER_ADDRESS", vm.toString(FEEDER));
        script = new DeployTestnet();
        script.run();
        (faucet, staking, owner,,) = script.deployment();
        dexy = faucet.DEXY();
        usdc = faucet.USDC();
        deployedAt = block.timestamp;
        genesis = staking.I_GENESIS_EPOCH_TIMESTAMP();
        epoch = staking.epochDuration();
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_LevelsKeepTheDeployMultipliersWithDemoLocks() public {
        DexynthStakingV2_3.Level[] memory production = new DeployHarness().levels();
        DexynthStakingV2_3.Level[] memory live = staking.getLevels();
        uint32[5] memory locks = [uint32(1 hours), 1 days, 3 days, 7 days, 14 days];
        assertEq(live.length, production.length);
        for (uint256 i = 0; i < live.length; i++) {
            assertEq(live[i].boostP, production[i].boostP, "multiplier");
            assertEq(live[i].lockingPeriod, locks[i], "lock");
        }
        assertEq(epoch, 7 days);
        assertEq(genesis, deployedAt + 5 minutes);
    }

    function test_TokensOwnershipAndFeeder() public view {
        assertEq(staking.DEXY(), address(dexy));
        assertEq(staking.REWARD_TOKEN(), address(usdc));
        assertEq(staking.owner(), owner);
        assertEq(faucet.owner(), owner);
        assertEq(faucet.feeder(), FEEDER);
    }

    function test_SeedIsStakedByTheFaucetInEveryLevel() public view {
        uint256[5] memory seed = script.seedAmounts();
        DexynthStakingV2_3.Level[] memory live = staking.getLevels();
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

    /**
     * @dev The first deposit waits for epoch 0 and streams over it to the seed, the only staker
     */
    function test_FirstDepositStreamsDuringEpochZero() public {
        assertEq(staking.queuedRewards(), uint256(2_000e6) * 1e36);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.nextEpochStart(), genesis);
        assertEq(staking.totalRewardsFunded(), 2_000e6);
        assertEq(usdc.balanceOf(address(staking)), 2_000e6);
        assertEq(staking.unallocatedRewards(), 0);

        vm.warp(genesis);
        assertEq(staking.pendingRewards(address(faucet)), 0);
        vm.warp(genesis + epoch / 2);
        uint256 half = staking.pendingRewards(address(faucet));
        assertLe(half, 1_000e6);
        assertGe(half, 1_000e6 - 1);
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
        assertEq(faucet.lastFundedAt(), 0);
        assertEq(staking.queuedRewards(), uint256(2_000e6) * 1e36);
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
        vm.warp(genesis + 6 hours);
        _claimAndStake(VISITOR, amount, 0);
        DexynthStakingV2_3.Stake memory s = _stake(VISITOR, 0);
        // The level 0 lock of 1 hour, counted from the stake
        assertEq(s.unlockTime, block.timestamp + 1 hours);
        assertEq(s.boostedAmount, amount * 65 / 100);

        vm.warp(block.timestamp + 30 minutes);
        uint256 expected = _appPending(VISITOR, block.timestamp);
        assertEq(staking.pendingRewards(VISITOR), expected, "app projection");
        vm.prank(VISITOR);
        staking.harvest();
        assertEq(usdc.balanceOf(VISITOR), 500e6 + expected, "harvested");

        vm.warp(s.unlockTime - 1);
        vm.expectRevert(DexynthStakingV2_3.StakeStillLocked.selector);
        vm.prank(VISITOR);
        staking.unstake(0);

        vm.warp(s.unlockTime);
        uint256 more = _appPending(VISITOR, block.timestamp);
        vm.prank(VISITOR);
        staking.unstake(0);
        assertEq(dexy.balanceOf(VISITOR), 10_000e18, "principal back");
        assertEq(usdc.balanceOf(VISITOR), 500e6 + expected + more, "unstake pays the rest");
    }

    /**
     * @dev A visitor deposits the faucet's USDC during epoch 0: epoch 1 streams it, epoch 0 keeps its rate
     */
    function test_VisitorDepositStreamsOverTheNextEpoch() public {
        vm.warp(genesis + 1 days);
        vm.startPrank(VISITOR, VISITOR);
        faucet.claim();
        usdc.approve(address(staking), 500e6);
        vm.expectEmit(true, true, true, true, address(staking));
        emit DexynthStakingV2_3.RewardAdded(VISITOR, 1, 500e6);
        staking.addStakingReward(500e6);
        vm.stopPrank();
        assertEq(staking.rewardRate(), uint256(2_000e6) * 1e36 / epoch);

        // The app projects across the epoch turn before any call writes it
        uint256 projected = _appPending(address(faucet), genesis + epoch + 1 days);
        vm.warp(genesis + epoch + 1 days);
        assertEq(staking.pendingRewards(address(faucet)), projected, "app projection");
        _claimAndStake(GRIEFER, 1_000e18, 0);
        assertEq(staking.rewardRate(), uint256(500e6) * 1e36 / epoch);
    }

    function test_LockCountsFromTheStakeAcrossAnEpochTurn() public {
        vm.warp(genesis + epoch - 1);
        _claimAndStake(VISITOR, 1_000e18, 1);
        assertEq(_stake(VISITOR, 0).unlockTime, block.timestamp + 1 days);

        vm.warp(genesis + epoch);
        vm.startPrank(VISITOR);
        dexy.approve(address(staking), 1_000e18);
        staking.stake(1_000e18, 1);
        vm.stopPrank();
        assertEq(_stake(VISITOR, 1).unlockTime, block.timestamp + 1 days, "the same lock");
    }

    function test_AnEpochWithoutDepositsStreamsNothing() public {
        _claimAndStake(VISITOR, 1_000e18, 4);
        vm.warp(genesis + epoch);
        uint256 atEnd = staking.pendingRewards(VISITOR);
        assertGt(atEnd, 0);
        vm.warp(genesis + 3 * epoch);
        assertEq(staking.pendingRewards(VISITOR), atEnd);
        assertEq(_appPending(VISITOR, block.timestamp), atEnd);
    }

    /*//////////////////////////////////////////////////////////////
                            FAILURE MODES
    //////////////////////////////////////////////////////////////*/

    function test_HarvestWithoutStakeReverts() public {
        vm.expectRevert(DexynthStakingV2_3.NoStakedTokens.selector);
        vm.prank(VISITOR);
        staking.harvest();
    }

    function test_SecondHarvestInTheSameBlockReverts() public {
        _claimAndStake(VISITOR, 1_000e18, 0);
        vm.warp(genesis + 1 hours);
        vm.startPrank(VISITOR);
        staking.harvest();
        vm.expectRevert(DexynthStakingV2_3.NoRewardsToHarvest.selector);
        staking.harvest();
        vm.stopPrank();
    }

    function test_StakeFailures() public {
        vm.startPrank(VISITOR, VISITOR);
        faucet.claim();
        // 1 wei at 0.65x boosts to zero
        dexy.approve(address(staking), type(uint256).max);
        vm.expectRevert(DexynthStakingV2_3.ZeroBoostedStake.selector);
        staking.stake(1, 0);
        vm.expectRevert(DexynthStakingV2_3.WrongParams.selector);
        staking.stake(1e18, 5);
        vm.expectRevert(DexynthStakingV2_3.WrongParams.selector);
        staking.stake(0, 0);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        staking.stake(10_001e18, 0);
        dexy.approve(address(staking), 1e18);
        vm.expectRevert("ERC20: insufficient allowance");
        staking.stake(2e18, 0);
        vm.stopPrank();
    }

    function test_DepositFailures() public {
        vm.startPrank(VISITOR, VISITOR);
        faucet.claim();
        vm.expectRevert(DexynthStakingV2_3.WrongParams.selector);
        staking.addStakingReward(0);
        vm.expectRevert("ERC20: insufficient allowance");
        staking.addStakingReward(1e6);
        usdc.approve(address(staking), type(uint256).max);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        staking.addStakingReward(501e6);
        vm.stopPrank();
    }

    function test_UnstakeFailures() public {
        _claimAndStake(VISITOR, 1_000e18, 0);
        vm.startPrank(VISITOR);
        vm.expectRevert(DexynthStakingV2_3.StakeNotFound.selector);
        staking.unstake(1);
        vm.warp(_stake(VISITOR, 0).unlockTime);
        staking.unstake(0);
        vm.expectRevert(DexynthStakingV2_3.AlreadyUnstaked.selector);
        staking.unstake(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              GRIEFING
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deposits are open to anyone and only add to the next epoch; migration, ownership, the feeder and minting
     *      stay out of a stranger's reach
     */
    function test_StrangerCanDepositButNotMigrateOrMint() public {
        vm.warp(genesis + 1 days);
        vm.startPrank(GRIEFER, GRIEFER);
        faucet.claim();
        usdc.approve(address(staking), 1);
        staking.addStakingReward(1);
        assertEq(staking.rewardRate(), uint256(2_000e6) * 1e36 / epoch, "epoch 0 unchanged");

        vm.expectRevert("Ownable: caller is not the owner");
        staking.requestMigration(GRIEFER);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.renounceOwnership();
        vm.expectRevert("Ownable: caller is not the owner");
        staking.transferOwnership(GRIEFER);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.OnlyFeeder.selector, GRIEFER));
        faucet.fundRewards(address(staking), 1e6);
        vm.expectRevert("Ownable: caller is not the owner");
        faucet.setFeeder(GRIEFER);
        vm.expectRevert("Ownable: caller is not the owner");
        faucet.mint(address(usdc), GRIEFER, 1e6);
        vm.stopPrank();
    }

    /**
     * @dev A griefer stakes dust every block and donates tokens to the contract: visitors still stake, earn their
     *      exact share, harvest and unstake
     */
    function test_DustStakesAndDonationsDoNotBlockVisitors() public {
        vm.startPrank(GRIEFER, GRIEFER);
        faucet.claim();
        dexy.approve(address(staking), type(uint256).max);
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + 2);
            staking.stake(2, 0);
        }
        assertTrue(dexy.transfer(address(staking), 1_000e18));
        vm.stopPrank();

        _claimAndStake(VISITOR, 1_000e18, 0);
        vm.warp(genesis + 6 hours);
        uint256 expected = _appPending(VISITOR, block.timestamp);
        vm.prank(VISITOR);
        staking.harvest();
        assertEq(usdc.balanceOf(VISITOR), 500e6 + expected);
        vm.warp(_stake(VISITOR, 0).unlockTime);
        vm.prank(VISITOR);
        staking.unstake(0);
        assertEq(dexy.balanceOf(VISITOR), 10_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                               TOP UP
    //////////////////////////////////////////////////////////////*/

    function test_TopUpQueuesForTheNextEpoch() public {
        vm.warp(genesis + 3 days);
        new TopUpRewards().topUp(staking, faucet, 50e6);
        assertEq(staking.rewardRate(), uint256(2_000e6) * 1e36 / epoch, "epoch 0 unchanged");
        assertEq(staking.queuedRewards(), uint256(50e6) * 1e36);
        assertEq(staking.nextEpochStart(), genesis + epoch);
        assertEq(staking.totalRewardsFunded(), 2_050e6);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _claimAndStake(address _user, uint256 _amount, uint8 _level) internal {
        vm.startPrank(_user, _user);
        faucet.claim();
        dexy.approve(address(staking), _amount);
        staking.stake(_amount, _level);
        vm.stopPrank();
    }

    function _stake(address _user, uint64 _index) internal view returns (DexynthStakingV2_3.Stake memory s) {
        (s.unstaked, s.level, s.timestamp, s.unlockTime, s.stakedDexy, s.boostedAmount) =
            staking.stakeInfo(_user, _index);
    }

    /**
     * @dev The app's projection (app/src/lib/staking.ts): the pool advanced to _t the way the next update will, the
     *      stored rate until nextEpochStart and then the queued rewards over the epoch after it, then the user's
     *      settlement rounded down
     */
    function _appPending(address _user, uint256 _t) internal view returns (uint256) {
        (, uint128 stored,, uint128 boosted,, uint256 snapshot) = staking.users(_user);
        uint256 acc = staking.accRewardPerBoostedShare();
        uint256 total = staking.totalBoostedStake();
        if (total > 0) acc += _streamedUntil(_t) / total;
        return stored + Math.mulDiv(boosted, acc - snapshot, 1e36);
    }

    function _streamedUntil(uint256 _t) internal view returns (uint256) {
        uint256 last = staking.lastRewardTime();
        if (_t <= last) return 0;
        uint256 next = staking.nextEpochStart();
        uint256 rate = staking.rewardRate();
        if (_t < next) return (_t - last) * rate;
        uint256 queuedRate = staking.queuedRewards() / epoch;
        return (next - last) * rate + (Math.min(_t, next + epoch) - next) * queuedRate;
    }
}
