// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "forge-std/Test.sol";
import "../src/DexynthStaking.sol";
import "../src/DEXY.sol";
import "../src/USDT.sol";

contract DexynthStakingTest is Test {
    DexynthStakingV1 public staking;
    DEXYToken public dexy;
    USDTToken public usdt;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    DexynthStakingV1.Level[5] public levels;

    function setUp() public {
        // Set timestamp first to avoid underflow in constructor
        vm.warp(2000000000);

        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        // Deploy Tokens
        dexy = new DEXYToken();
        usdt = new USDTToken();

        // Setup Levels
        // Note: Struct order is (lockingPeriod, boostP)
        levels[0] = DexynthStakingV1.Level(2592000, 6500000000);
        levels[1] = DexynthStakingV1.Level(7776000, 8500000000);
        levels[2] = DexynthStakingV1.Level(15552000, 10000000000);
        levels[3] = DexynthStakingV1.Level(31536000, 11500000000);
        levels[4] = DexynthStakingV1.Level(62208000, 13500000000);

        // Deploy Staking
        staking = new DexynthStakingV1(
            address(dexy),
            address(usdt),
            levels,
            1296000
        );

        // Setup Balances
        dexy.transfer(address(staking), 10_000_000 ether);
        
        dexy.transfer(user1, 100_000 ether);
        dexy.transfer(user2, 100_000 ether);
        dexy.transfer(user3, 100_000 ether);

        // Approvals
        vm.prank(user1);
        dexy.approve(address(staking), 100_000 ether);
        
        vm.prank(user2);
        dexy.approve(address(staking), 100_000 ether);
        
        vm.prank(user3);
        dexy.approve(address(staking), 100_000 ether);

        // Owner approves USDT for rewards
        usdt.approve(address(staking), 100_000 ether);
        
        // Set timestamp
        vm.warp(2000000000);
    }

    function testDeploy() public {
        assertEq(staking.owner(), owner);
        assertEq(dexy.owner(), owner);
        assertEq(usdt.owner(), owner);
    }

    function testGovAddressConfiguration() public {
        // Should revert setting new gov by non gov address
        vm.prank(user3);
        vm.expectRevert(DexynthStakingV1.GovOnly.selector);
        staking.setGov(address(0x999));

        // Should work setting new gov by gov address
        staking.setGov(address(0x999));
        assertEq(staking.s_govAddress(), address(0x999));
    }

    function testLevelsConfiguration() public {
        // Should revert setting new levels by non gov address
        vm.prank(user3);
        vm.expectRevert(DexynthStakingV1.GovOnly.selector);
        staking.setLevels(levels);

        // Should work if there are 5 levels and the requester is the owner
        staking.setLevels(levels);
    }

    function testSetLevelsFailValidation() public {
        DexynthStakingV1.Level[5] memory badLevels = levels;
        // Change boostP so sum is wrong
        badLevels[0].boostP = 1; 
        
        vm.expectRevert(DexynthStakingV1.BoostSumNotRight.selector);
        staking.setLevels(badLevels);
    }

    function testSetLevelsFailOrdering() public {
        DexynthStakingV1.Level[5] memory badLevels = levels;
        // Make level 1 locking period smaller than level 0
        badLevels[1].lockingPeriod = badLevels[0].lockingPeriod - 1;
        
        vm.expectRevert(DexynthStakingV1.WrongValues.selector);
        staking.setLevels(badLevels);
    }

    function testSetGovAddressZero() public {
        vm.expectRevert(DexynthStakingV1.AddressZero.selector);
        staking.setGov(address(0));
    }

    function testMigrateContract() public {
        // Setup some balances
        staking.addStakingReward(1000 ether); // USDT
        
        vm.prank(user1);
        staking.stake(500 ether, 0); // DEXY
        
        address newContract = address(0x999);
        
        uint256 usdtBalBefore = usdt.balanceOf(newContract);
        uint256 dexyBalBefore = dexy.balanceOf(newContract);
        
        staking.migrateContract(newContract);
        
        uint256 usdtBalAfter = usdt.balanceOf(newContract);
        uint256 dexyBalAfter = dexy.balanceOf(newContract);
        
        assertEq(usdtBalAfter - usdtBalBefore, 1000 ether);
        // In setUp, we transferred 10_000_000 ether DEXY to staking contract.
        // Plus user1 staked 500 ether.
        // Total DEXY in contract = 10_000_000 + 500 = 10_000_500 ether.
        assertEq(dexyBalAfter - dexyBalBefore, 10_000_500 ether);
        
        assertEq(usdt.balanceOf(address(staking)), 0);
        assertEq(dexy.balanceOf(address(staking)), 0);
    }

    function testMigrateContractFailNotGov() public {
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV1.GovOnly.selector);
        staking.migrateContract(address(0x999));
    }

    function testGetLevels() public {
        uint256[2][5] memory levelsData = staking.getLevels();
        // Check a few values
        assertEq(levelsData[0][0], levels[0].lockingPeriod);
        assertEq(levelsData[0][1], levels[0].boostP);
        assertEq(levelsData[4][0], levels[4].lockingPeriod);
        assertEq(levelsData[4][1], levels[4].boostP);
    }

    // --- Epochs Tests ---

    function testEpochClosingByStake() public {
        assertEq(staking.s_lastClosedEpochIndex() + 1, 1);
        
        vm.warp(block.timestamp + 95 days); // 95 days -> 6 epochs
        
        vm.prank(user1);
        staking.stake(50 ether, 0);
        
        assertEq(staking.s_lastClosedEpochIndex() + 1, 7);
    }

    function testEpochClosingByUnstakeHarvest() public {
        assertEq(staking.s_lastClosedEpochIndex() + 1, 1);
        
        staking.addStakingReward(6600 ether);
        
        vm.prank(user1);
        staking.stake(50 ether, 0);
        
        vm.warp(block.timestamp + 95 days);
        
        vm.prank(user1);
        staking.unstake(0);
        
        assertEq(staking.s_lastClosedEpochIndex() + 1, 7);
    }

    function testTotalRewards() public {
        staking.addStakingReward(55621 ether);
        
        vm.warp(block.timestamp + 95 days);
        staking.checkForClosingEpochs();
        
        for (uint32 i = 1; i < 7; i++) {
            (uint256 totalRewards, , , ) = staking.s_epoch(i);
            assertGt(totalRewards, 8782.1 ether);
            assertLt(totalRewards, 8782.3 ether);
        }
    }

    function testLeftRewards() public {
        staking.addStakingReward(55621 ether);
        uint256 totalRewardsInitial = staking.s_accRewards();
        
        vm.warp(block.timestamp + 95 days);
        staking.checkForClosingEpochs();
        
        uint256 tempRewards = 0;
        for (uint32 i = 1; i < 7; i++) {
            (uint256 epochRewards, , , ) = staking.s_epoch(i); // Note: JS test had a bug using epoch(1) in loop, but logic implies summing all. I'll sum all.
            // Wait, JS test said: const epoch = await stakingContract.epoch(1); inside the loop i=1..7. That looks like a bug in the JS test?
            // "const epoch = await stakingContract.epoch(1);" -> It was always reading epoch 1?
            // "tempRewards += epoch[0];"
            // But the loop variable is 'i'.
            // Let's assume the intention was 'i'.
            tempRewards += epochRewards;
        }
        
        // Re-reading JS test carefully:
        // for (i=1; i<7; i++) {
        //   const epoch = await stakingContract.epoch(1); <--- BUG in JS test!
        //   tempRewards += epoch[0];
        // }
        // If I fix the bug here, the assertion might fail if the JS test passed because of the bug.
        // However, since I'm rewriting, I should write correct tests.
        // But wait, if I fix it, the math might be different.
        // Let's look at the logic. It sums up rewards distributed to epochs.
        // The remaining rewards should be total - distributed.
        // If the JS test was summing epoch 1 six times, it was testing weird math.
        // I will implement the CORRECT logic: sum rewards of all closed epochs.
        
        // Actually, let's re-read the JS test execution. It passed.
        // If epoch 1 rewards are roughly 8782.2, and it summed it 6 times, that's ~52693.
        // Total was 55621. Left ~2928.
        // If the rewards are distributed evenly (which they are, per second), then all epochs should have similar rewards.
        // So summing epoch 1 six times is roughly equivalent to summing epochs 1-6.
        // So I will implement the loop correctly using 'i'.
        
        uint256 rewardsLeft = staking.s_accRewards();
        // Note: In Solidity we can't easily check "total - temp == left" due to precision, but let's try exact match first.
        // The JS test did: expect(rewardsLeft).to.equal(totalRewards - tempRewards);
        
        // Let's recalculate tempRewards correctly
        tempRewards = 0;
        for (uint32 i = 1; i < 7; i++) {
            (uint256 epochRewards, , , ) = staking.s_epoch(i);
            tempRewards += epochRewards;
        }
        
        assertEq(rewardsLeft, totalRewardsInitial - tempRewards);
    }

    function testTotalTokensBoosted() public {
        // User 1 stakes
        vm.startPrank(user1);
        staking.stake(50 ether, 0);
        staking.stake(300 ether, 1);
        staking.stake(150 ether, 2);
        staking.stake(200 ether, 3);
        staking.stake(300 ether, 4);
        vm.stopPrank();

        // User 2 stakes
        vm.startPrank(user2);
        staking.stake(300 ether, 0);
        staking.stake(125 ether, 1);
        staking.stake(175 ether, 2);
        staking.stake(1000 ether, 3);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        // Check accStakedTokensPerEpochAndLevel for epoch 2 (current + 1)
        // Note: In JS test, it checks epoch 2.
        // In setUp, we are at timestamp 2000000000.
        // Genesis epoch starts at 2000000000 - 1296000.
        // Current epoch is 0.
        // Staking adds to currentEpoch + 1 = 1.
        // Wait, let's check `stake` function:
        // stakeInfo...startingEpoch = getCurrentEpochIndex() + 1;
        // accStakedTokensPerEpochAndLevel[getCurrentEpochIndex() + 1]...
        
        // In JS test:
        // assert.equal(await stakingContract.lastClosedEpochIndex()+BigInt(1), 1);
        // This means lastClosed is 0. Current is 1?
        // No, lastClosedEpochIndex starts at 0 (in contract definition? No, default 0).
        // Constructor: epoch[0] initialized.
        // getCurrentEpochIndex() returns index based on timestamp.
        // If timestamp == end of epoch 0, index is 1?
        // getEpochIndexByTimestamp: (timestamp - GENESIS) / duration.
        // At setup: timestamp = 2000000000. GENESIS = 2000000000 - 1296000.
        // (2000000000 - (2000000000 - 1296000)) / 1296000 = 1296000 / 1296000 = 1.
        // So current epoch is 1.
        // So staking goes to epoch 1. Correct.

        (uint256 acc0) = staking.s_accStakedTokensPerEpochAndLevel(1, 0);
        (uint256 acc1) = staking.s_accStakedTokensPerEpochAndLevel(1, 1);
        (uint256 acc2) = staking.s_accStakedTokensPerEpochAndLevel(1, 2);
        (uint256 acc3) = staking.s_accStakedTokensPerEpochAndLevel(1, 3);
        (uint256 acc4) = staking.s_accStakedTokensPerEpochAndLevel(1, 4);

        assertEq(acc0, 350 ether);
        assertEq(acc1, 425 ether);
        assertEq(acc2, 325 ether);
        assertEq(acc3, 1200 ether);
        assertEq(acc4, 700 ether);

        // Forwarding epochs
        staking.addStakingReward(20000 ether);
        vm.warp(block.timestamp + 30 days + 100);
        staking.checkForClosingEpochs();

        (, uint256 totalTokensBoosted, , ) = staking.s_epoch(1);
        assertEq(totalTokensBoosted, 3238.75 ether);
    }

    function testStartEndTimestamps() public {
        vm.warp(block.timestamp + 30 days + 100);
        staking.checkForClosingEpochs();

        (, , uint40 start0, uint40 end0) = staking.s_epoch(0);
        (, , uint40 start1, uint40 end1) = staking.s_epoch(1);
        (, , uint40 start2, uint40 end2) = staking.s_epoch(2);
        uint32 duration = staking.s_epochDuration();

        assertEq(start1, end0 + 1);
        assertEq(end1, start1 + duration);
        assertEq(start2, end1 + 1);
        assertEq(end2, start2 + duration);
    }

    // --- Stake Tests ---

    function testStakeDifferentLevels() public {
        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);
    }

    function testUsersBalancesAfterStaking() public {
        uint256 balanceUser1Before = dexy.balanceOf(user1);
        uint256 balanceUser2Before = dexy.balanceOf(user2);

        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        uint256 balanceUser1After = dexy.balanceOf(user1);
        uint256 balanceUser2After = dexy.balanceOf(user2);

        assertEq(balanceUser1Before - balanceUser1After, 1000 ether);
        assertEq(balanceUser2Before - balanceUser2After, 1800 ether);

                // Check staked tokens mapping
        (uint256 staked1a) = staking.s_stakedTokensPerWalletAndEpochAndLevel(user1, 1, 0);
        (uint256 staked1b) = staking.s_stakedTokensPerWalletAndEpochAndLevel(user1, 1, 4);
        assertEq(staked1a + staked1b, 1000 ether);

        (uint256 staked2) = staking.s_stakedTokensPerWalletAndEpochAndLevel(user2, 1, 1);
        assertEq(staked2, 1800 ether);
    }

    function testUsersDataAfterStaking() public {
        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        (uint256 totalStaked1, uint256 totalHarvested1, uint64 index1, uint32 lastEpoch1) = staking.s_user(user1);
        (uint256 totalStaked2, uint256 totalHarvested2, uint64 index2, uint32 lastEpoch2) = staking.s_user(user2);

        assertEq(totalStaked1, 1000 ether);
        assertEq(totalStaked2, 1800 ether);
        assertEq(totalHarvested1, 0);
        assertEq(totalHarvested2, 0);
        assertEq(index1, 2);
        assertEq(index2, 1);
        assertEq(lastEpoch1, 0);
        assertEq(lastEpoch2, 0);
    }

    function testStakeDataAfterStaking() public {
        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        (uint256 staked1a, , uint32 start1a, , uint8 level1a, ) = staking.s_stakeInfo(user1, 0);
        (uint256 staked1b, , uint32 start1b, , uint8 level1b, ) = staking.s_stakeInfo(user1, 1);
        (uint256 staked2, , uint32 start2, , uint8 level2, ) = staking.s_stakeInfo(user2, 0);

        assertEq(staked1a, 600 ether);
        assertEq(staked1b, 400 ether);
        assertEq(staked2, 1800 ether);

        assertEq(level1a, 0);
        assertEq(level1b, 4);
        assertEq(level2, 1);

        assertEq(start1a, 1);
        assertEq(start1b, 1);
        assertEq(start2, 1);
    }

    function testStakeFailZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV1.WrongParams.selector);
        staking.stake(0, 0);
    }

    function testStakeFailInvalidLevel() public {
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV1.WrongParams.selector);
        staking.stake(100 ether, 5); // Level 5 does not exist (0-4)
    }

    // --- Unstake Tests ---

    function testUnstake() public {
        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        // Forward time to unlock
        vm.warp(block.timestamp + 365 days); // Enough for all levels

        vm.prank(user1);
        staking.unstake(0);

        vm.prank(user2);
        staking.unstake(0);
    }

    function testUsersBalancesAfterUnstaking() public {
        uint256 balanceUser1Before = dexy.balanceOf(user1);
        uint256 balanceUser2Before = dexy.balanceOf(user2);

        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        vm.warp(block.timestamp + 365 days);

        vm.prank(user1);
        staking.unstake(0);

        vm.prank(user2);
        staking.unstake(0);

        uint256 balanceUser1After = dexy.balanceOf(user1);
        uint256 balanceUser2After = dexy.balanceOf(user2);

        // User 1 staked 1000 total, unstaked 600. Net change -400.
        assertEq(balanceUser1Before - balanceUser1After, 400 ether);
        // User 2 staked 1800, unstaked 1800. Net change 0.
        assertEq(balanceUser2Before, balanceUser2After);
    }

    function testUsersDataAfterUnstaking() public {
        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        vm.warp(block.timestamp + 365 days);

        vm.prank(user1);
        staking.unstake(0);

        vm.prank(user2);
        staking.unstake(0);

        (uint256 totalStaked1, , , ) = staking.s_user(user1);
        (uint256 totalStaked2, , , ) = staking.s_user(user2);

        assertEq(totalStaked1, 400 ether);
        assertEq(totalStaked2, 0);
    }

    function testStakeDataAfterUnstaking() public {
        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        vm.warp(block.timestamp + 365 days);

        vm.prank(user1);
        staking.unstake(0);

        vm.prank(user2);
        staking.unstake(0);

        (, , , , , bool unstaked1a) = staking.s_stakeInfo(user1, 0);
        (, , , , , bool unstaked1b) = staking.s_stakeInfo(user1, 1);
        (, , , , , bool unstaked2) = staking.s_stakeInfo(user2, 0);

        assertEq(unstaked1a, true);
        assertEq(unstaked1b, false);
        assertEq(unstaked2, true);
    }

    function testUnstakeLocked() public {
        vm.prank(user1);
        staking.stake(600 ether, 0);

        // Try to unstake immediately
        vm.prank(user1);
        vm.expectRevert(DexynthStakingV1.StakeStillLocked.selector);
        staking.unstake(0);
    }

    function testUnstakeTwice() public {
        vm.prank(user1);
        staking.stake(600 ether, 0);

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(user1);
        staking.unstake(0);
        vm.expectRevert(DexynthStakingV1.AlreadyUnstaked.selector);
        staking.unstake(0); // Should fail
        vm.stopPrank();
    }

    // --- Harvest Tests ---

    function testHarvest() public {
        staking.addStakingReward(20000 ether);

        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        vm.warp(block.timestamp + 30 days + 100); // Ensure epochs close

        vm.prank(user1);
        staking.harvest();

        vm.prank(user2);
        staking.harvest();
    }

    function testUsersBalancesAfterHarvesting() public {
        staking.addStakingReward(20000 ether);
        uint256 balanceUser1Before = usdt.balanceOf(user1);
        uint256 balanceUser2Before = usdt.balanceOf(user2);

        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        vm.warp(block.timestamp + 30 days + 100);

        vm.prank(user1);
        staking.harvest();

        vm.prank(user2);
        staking.harvest();

        uint256 balanceUser1After = usdt.balanceOf(user1);
        uint256 balanceUser2After = usdt.balanceOf(user2);

        // Rewards are distributed based on boost points.
        // User 1: 600*1 (L0) + 400*1.75 (L4) = 600 + 700 = 1300 boost points
        // User 2: 1800*1.25 (L1) = 2250 boost points
        // Total boost: 3550
        // Rewards approx 20000 distributed over 2 epochs (Epoch 1 and Epoch 2).
        // Users staked in Epoch 2 (startingEpoch = current + 1 = 2).
        // So they only get rewards for Epoch 2.
        // Epoch 2 rewards ~ 10000.
        // User 1 share: 10000 * 1300 / 3550 ~ 3661
        // User 2 share: 10000 * 2250 / 3550 ~ 6338
        
        assertGt(balanceUser1After - balanceUser1Before, 3600 ether);
        assertGt(balanceUser2After - balanceUser2Before, 6000 ether);
    }

    function testUsersDataAfterHarvesting() public {
        staking.addStakingReward(20000 ether);

        vm.startPrank(user1);
        staking.stake(600 ether, 0);
        staking.stake(400 ether, 4);
        vm.stopPrank();

        vm.prank(user2);
        staking.stake(1800 ether, 1);

        vm.warp(block.timestamp + 30 days + 100);

        vm.prank(user1);
        staking.harvest();

        vm.prank(user2);
        staking.harvest();

        (, uint256 totalHarvested1, , uint32 lastEpoch1) = staking.s_user(user1);
        (, uint256 totalHarvested2, , uint32 lastEpoch2) = staking.s_user(user2);

        assertGt(totalHarvested1, 3600 ether);
        assertGt(totalHarvested2, 6000 ether);
        
        // Current epoch index should be around 3 (start + 30 days)
        // lastEpochHarvested should be currentEpoch - 1
        uint32 currentEpoch = staking.getCurrentEpochIndex();
        assertEq(lastEpoch1, currentEpoch - 1);
        assertEq(lastEpoch2, currentEpoch - 1);
    }

    function testHarvestTwice() public {
        staking.addStakingReward(20000 ether);
        vm.prank(user1);
        staking.stake(600 ether, 0);

        vm.warp(block.timestamp + 30 days + 100);

        vm.startPrank(user1);
        staking.harvest();
        vm.expectRevert(DexynthStakingV1.NoEpochsToHarvest.selector);
        staking.harvest(); // Should fail: NoEpochsToHarvest
        vm.stopPrank();
    }

    function testHarvestNoRewards() public {
        // No rewards added
        vm.prank(user1);
        staking.stake(600 ether, 0);

        vm.warp(block.timestamp + 30 days + 100);

        vm.prank(user1);
        // If no rewards, it might revert with NoRewardsToHarvest OR NoEpochsToHarvest if accRewards is 0?
        // isHarvestable checks accRewards > 0.
        // If accRewards == 0, isHarvestable returns false.
        // But harvest() calls checkForClosingEpochs() then checks epochs.
        // If accRewards == 0, checkForClosingEpochs does nothing (rewardsPerSecond=0).
        // Then it checks epochs.
        // If epochs passed, it enters loop.
        // Inside loop, payoutPerTokenAtThisLevel = 0.
        // totalUserRewards = 0.
        // Then it checks totalUserRewards == 0 -> revert NoRewardsToHarvest.
        
        // Wait, isHarvestable is NOT called in harvest(). It's called in unstake().
        // harvest() logic:
        // if (((getCurrentEpochIndex()) - (user[msg.sender].lastEpochHarvested + 1)) == 0) revert NoEpochsToHarvest();
        // ... loop ...
        // if (totalUserRewards == 0) revert NoRewardsToHarvest();
        
        vm.expectRevert(DexynthStakingV1.NoRewardsToHarvest.selector);
        staking.harvest(); 
    }

    // --- Fuzz Tests ---

    function testFuzz_Stake(uint256 amount, uint8 level) public {
        // Bound inputs to valid ranges
        // Amount: 1 wei to 100,000 ether (user balance)
        amount = bound(amount, 1, 100_000 ether);
        // Level: 0 to 4
        level = uint8(bound(level, 0, 4));

        uint256 balanceBefore = dexy.balanceOf(user1);
        
        vm.startPrank(user1);
        staking.stake(amount, level);
        vm.stopPrank();

        uint256 balanceAfter = dexy.balanceOf(user1);
        
        // Verify balance change
        assertEq(balanceBefore - balanceAfter, amount);

        // Verify stake info
        (uint256 staked, , , , uint8 stakedLevel, ) = staking.s_stakeInfo(user1, 0);
        assertEq(staked, amount);
        assertEq(stakedLevel, level);

        // Verify user totals
        (uint256 totalStaked, , , ) = staking.s_user(user1);
        assertEq(totalStaked, amount);
    }

    function testFuzz_Unstake(uint256 _amount, uint8 _levelIndex) public {
        // Bound inputs
        _amount = bound(_amount, 1 ether, 100_000 ether);
        _levelIndex = uint8(bound(_levelIndex, 0, 4));

        // Setup
        uint256 initialBalance = dexy.balanceOf(user1);
        
        vm.startPrank(user1);
        staking.stake(_amount, _levelIndex);
        
        // Get locking period from test storage
        uint256 lockingPeriod = levels[_levelIndex].lockingPeriod;
        
        // Warp to unlock (lockingPeriod + 1 epoch buffer to ensure we are in the next epoch)
        // The contract requires: getCurrentEpochIndex() >= unlockingEpoch
        // unlockingEpoch = startingEpoch + (lockingPeriod / epochDuration)
        // startingEpoch = current + 1
        // So we need to pass lockingPeriod + current epoch remainder.
        // Adding 2 * epochDuration is a safe buffer.
        vm.warp(block.timestamp + lockingPeriod + 1296000 * 2);
        
        // Unstake (index 0 because it's the first stake)
        staking.unstake(0);
        vm.stopPrank();

        // Assertions
        assertEq(dexy.balanceOf(user1), initialBalance);
    }

    function testFuzz_Harvest(uint256 _amount, uint8 _levelIndex, uint32 _epochsToWait) public {
        // Bound inputs
        _amount = bound(_amount, 1 ether, 100_000 ether);
        _levelIndex = uint8(bound(_levelIndex, 0, 4));
        _epochsToWait = uint32(bound(_epochsToWait, 2, 50)); // Wait at least 2 epochs to ensure 1 full epoch passed

        // Setup Stake
        vm.prank(user1);
        staking.stake(_amount, _levelIndex);

        // Add Rewards (as owner)
        uint256 rewardAmount = 10_000 ether;
        staking.addStakingReward(rewardAmount);

        // Warp time
        // epochDuration is 1296000
        vm.warp(block.timestamp + (uint256(_epochsToWait) * 1296000));

        // Harvest
        vm.prank(user1);
        staking.harvest();

        // Assertions
        assertGt(usdt.balanceOf(user1), 0);
    }

    function testFuzz_MultipleStakes(uint256 amount1, uint8 level1, uint256 amount2, uint8 level2) public {
        // Bound inputs
        amount1 = bound(amount1, 1 ether, 50_000 ether);
        amount2 = bound(amount2, 1 ether, 50_000 ether); // Ensure sum doesn't exceed 100k balance
        level1 = uint8(bound(level1, 0, 4));
        level2 = uint8(bound(level2, 0, 4));

        vm.startPrank(user1);
        staking.stake(amount1, level1);
        staking.stake(amount2, level2);
        vm.stopPrank();

        // Verify User Totals
        (uint256 totalStaked, , uint64 stakeIndex, ) = staking.s_user(user1);
        assertEq(totalStaked, amount1 + amount2);
        assertEq(stakeIndex, 2);

        // Verify Individual Stakes
        (uint256 staked1, , , , uint8 l1, ) = staking.s_stakeInfo(user1, 0);
        (uint256 staked2, , , , uint8 l2, ) = staking.s_stakeInfo(user1, 1);

        assertEq(staked1, amount1);
        assertEq(l1, level1);
        assertEq(staked2, amount2);
        assertEq(l2, level2);
    }

    function testFuzz_DynamicRewards(uint256 stakeAmount, uint8 levelIndex, uint256 rewardAmount, uint32 epochsToWait) public {
        // Bound inputs
        stakeAmount = bound(stakeAmount, 1 ether, 100_000 ether);
        levelIndex = uint8(bound(levelIndex, 0, 4));
        // Reward: from 1 ether to 1M ether
        rewardAmount = bound(rewardAmount, 1 ether, 1_000_000 ether); 
        epochsToWait = uint32(bound(epochsToWait, 2, 50));

        // Setup Stake
        vm.prank(user1);
        staking.stake(stakeAmount, levelIndex);

        // Mint and Approve Rewards
        usdt.transfer(address(this), rewardAmount); // Ensure test contract has enough USDT (it minted 10M in constructor?)
        // Actually, usdt is a MockToken, let's check setUp.
        // usdt = new USDTToken(); -> Mints 100M to msg.sender (test contract)
        // So we have enough balance. Just need approval.
        usdt.approve(address(staking), rewardAmount);

        // Add Rewards
        staking.addStakingReward(rewardAmount);

        // Warp time
        vm.warp(block.timestamp + (uint256(epochsToWait) * 1296000));

        // Harvest
        vm.prank(user1);
        staking.harvest();

        // Assertions
        assertGt(usdt.balanceOf(user1), 0);
    }
}
