const { assert, expect } = require("chai");
const { network, getNamedAccounts, deployments, ethers } = require("hardhat");
const helpers = require("@nomicfoundation/hardhat-network-helpers");

describe("DexynthStakingV1", async function () {
  let stakingContract;
  let dexy;
  let usdt;
  let owner;
  let user1;
  let user2;
  let user3;
  // Set initial timestamp and snapshot
  before(async function () {
    // Set block timestamp
    helpers.time.setNextBlockTimestamp(2000000000);
    // helpers.mine();
  });

  // Deploy the contracts before running the tests
  beforeEach(async function () {
    // Get signers (accounts) from Hardhat
    deployer = (await getNamedAccounts()).deployer;
    const signers = await ethers.getSigners();
    owner = signers[0]; // Owner account used for privileged operations
    user1 = signers[1]; // User 1 account for testing staking and rewards
    user2 = signers[2]; // User 2 account for testing staking and rewards
    user3 = signers[3]; // User 3 account for testing staking and rewards
    // // console.log("[TEST] - owner",owner.address);
    // // console.log("[TEST] - user1",user1.address);
    // // console.log("[TEST] - user2",user2.address);
    const DEXY = await ethers.getContractFactory("DEXYToken");
    dexy = await DEXY.deploy();
    const USDT = await ethers.getContractFactory("USDTToken");
    usdt = await USDT.deploy();
    const DexynthStakingV1 = await ethers.getContractFactory("DexynthStakingV1");
    stakingContract = await DexynthStakingV1.deploy(dexy.target, usdt.target, [[2592000,6500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]], 1296000);
    // Transfer DEXY tokens to the staking contract
    await dexy.transfer(stakingContract.target, ethers.parseEther("10000000"));
    // Approve staking contract to spend USDT tokens
    await usdt.approve(stakingContract.target, ethers.parseEther("100000"));
    // Transfer DEXY tokens to users
    await dexy.transfer(user1.address, ethers.parseEther("100000"));
    await dexy.transfer(user2.address, ethers.parseEther("100000"));
    await dexy.transfer(user3.address, ethers.parseEther("100000"));
    // Approve staking contract to spend user's DEXY tokens
    await dexy.connect(user1).approve(stakingContract.target, ethers.parseEther("100000"));
    await dexy.connect(user2).approve(stakingContract.target, ethers.parseEther("100000"));
    await dexy.connect(user3).approve(stakingContract.target, ethers.parseEther("100000"));
  });

  describe("Deploy", function () {
    it("Should deploy the contract correctly", async function () {
      // Ensure that the contract has been deployed correctly and the owner is set
      const contractOwner = await stakingContract.owner();
      expect(contractOwner).to.equal(owner.address);
    });
    it("Deployer of staking and tokens contracts should be the same", async function () {
      // Ensure that the contract has been deployed correctly and the owner is set
      const stakingOwner = await stakingContract.owner();
      const dexyOwner = await dexy.owner();
      const usdtOwner = await usdt.owner();
      expect(stakingOwner).to.equal(dexyOwner).to.equal(usdtOwner);
    });
  });

  describe("Gov address configuration", function () {
    it("Should revert setting new gov by non gov address", async function () {
      await expect(stakingContract.connect(user3).setGov("0x8886552d9A798c71f2724c8c6901f0c0D9Cc2edE")).to.be.rejectedWith('GOV_ONLY');
    });
    it("Should work setting new gov by gov address", async function () {
      await expect(stakingContract.connect(owner).setGov("0x8886552d9A798c71f2724c8c6901f0c0D9Cc2edE")).to.not.be.reverted;
    });
  });

  describe("Levels configuration", function () {
    it("Should revert setting new levels by non gov addrress", async function () {
      await expect(stakingContract.connect(user3).setLevels([[2592000,6500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]])).to.be.rejectedWith('GOV_ONLY');
    });
    it("Should revert if there are more than 5 levels", async function () {
      await expect(stakingContract.connect(owner).setLevels([[2592000,6500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000],[62208000,13500000000]])).to.be.rejectedWith('array is wrong length');
    });
    it("Should revert if there are less than 5 levels", async function () {
      await expect(stakingContract.connect(owner).setLevels([[2592000,6500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000]])).to.be.rejectedWith('array is wrong length');
    });
    it("Should work if there are 5 levels and the requester is the owner", async function () {
      await expect(stakingContract.connect(owner).setLevels([[2592000,6500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]])).to.not.be.reverted;
    });
    it("Should revert if the sum of boosts is higher than 5 (number of levels)", async function () {
      await expect(stakingContract.connect(owner).setLevels([[2592000,16500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]])).to.be.rejectedWith('BOOST_SUM_NOT_RIGHT');
    });
    it("Should revert if the sum of boosts is lower than 5 (number of levels)", async function () {
      await expect(stakingContract.connect(owner).setLevels([[2592000,500000000],[7776000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]])).to.be.rejectedWith('BOOST_SUM_NOT_RIGHT');
    });
    it("Should revert if the order of periods is not right", async function () {
      await expect(stakingContract.connect(owner).setLevels([[7776000,6500000000],[2592000,8500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]])).to.be.rejectedWith('WRONG_VALUES');
    });
    it("Should revert if the order of boosts is not right", async function () {
      await expect(stakingContract.connect(owner).setLevels([[2592000,8500000000],[7776000,6500000000],[15552000,10000000000],[31536000,11500000000],[62208000,13500000000]])).to.be.rejectedWith('WRONG_VALUES');
    });
  });

  describe("Epochs", function () {
    it("Epoch closing by stake", async function () {
      // console.log("lastClosedEpochIndex()", await stakingContract.lastClosedEpochIndex());
      assert.equal(await stakingContract.lastClosedEpochIndex()+BigInt(1), 1);
      await helpers.time.increase(95*86400); // 95 days -> 6 epochs
      await stakingContract.connect(user1).stake(ethers.parseEther("50"), 0);
      assert.equal(await stakingContract.lastClosedEpochIndex()+BigInt(1), 7);
    });
    it("Epoch closing by unstake/harvest", async function () {
      assert.equal(await stakingContract.lastClosedEpochIndex()+BigInt(1), 1);
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 6600$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("6600")); // Rewards 6600 $
      await stakingContract.connect(user1).stake(ethers.parseEther("50"), 0);
      await helpers.time.increase(95*86400); // 95 days -> 6 epochs
      await stakingContract.connect(user1).unstake(0);
      assert.equal(await stakingContract.lastClosedEpochIndex()+BigInt(1), 7);

    });
    it("Total Rewards", async function () {
      await stakingContract.addStakingReward(ethers.parseEther("55621")); // Rewards 55621 $
      const totalRewards = await stakingContract.accRewards();
      await helpers.time.increase(95*86400); // 95 days
      await stakingContract.checkForClosingEpochs();
      for (i=1; i<7; i++) {
        const epoch = await stakingContract.epoch(i);
        // console.log("[TEST] - Epoch %s - Stored Rewards %s", i, epoch[0]);
        expect(epoch[0]).to.be.above(ethers.parseEther("8782.1"));
        expect(epoch[0]).to.be.below(ethers.parseEther("8782.3"));
      }
    });
    it("Left Rewards", async function () {
      await stakingContract.addStakingReward(ethers.parseEther("55621")); // Rewards 55621 $
      const totalRewards = await stakingContract.accRewards();
      await helpers.time.increase(95*86400); // 95 days
      await stakingContract.checkForClosingEpochs();
      let tempRewards = BigInt(0);
      for (i=1; i<7; i++) {
        const epoch = await stakingContract.epoch(1);
        // console.log("[TEST] - Epoch %s - Stored Rewards %s", i, epoch[0]);
        tempRewards += epoch[0];
        expect(epoch[0]).to.be.above(ethers.parseEther("8782.1"));
        expect(epoch[0]).to.be.below(ethers.parseEther("8782.3"));
      }
      const rewardsLeft = await stakingContract.accRewards();
      expect(rewardsLeft).to.equal(totalRewards - tempRewards);
    });
    it("Total Tokens Boosted & accStakedTokensPerEpochAndLevel", async function () {
      // Stake DEXY Tokens several times on different levels for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("50"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("300"), 1);
      await stakingContract.connect(user1).stake(ethers.parseEther("150"), 2);
      await stakingContract.connect(user1).stake(ethers.parseEther("200"), 3);
      await stakingContract.connect(user1).stake(ethers.parseEther("300"), 4);
      // Stake DEXY Tokens several times on different levels for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("300"), 0);
      await stakingContract.connect(user2).stake(ethers.parseEther("125"), 1);
      await stakingContract.connect(user2).stake(ethers.parseEther("175"), 2);
      await stakingContract.connect(user2).stake(ethers.parseEther("1000"), 3);
      await stakingContract.connect(user2).stake(ethers.parseEther("400"), 4);
      // Check accStakedTokensPerEpochAndLevel
      const accStakedTokensPerEpochAndLevel0 = await stakingContract.accStakedTokensPerEpochAndLevel(2, 0);
      const accStakedTokensPerEpochAndLevel1 = await stakingContract.accStakedTokensPerEpochAndLevel(2, 1);
      const accStakedTokensPerEpochAndLevel2 = await stakingContract.accStakedTokensPerEpochAndLevel(2, 2);
      const accStakedTokensPerEpochAndLevel3 = await stakingContract.accStakedTokensPerEpochAndLevel(2, 3);
      const accStakedTokensPerEpochAndLevel4 = await stakingContract.accStakedTokensPerEpochAndLevel(2, 4);
      assert.equal(accStakedTokensPerEpochAndLevel0, ethers.parseEther("350"));
      assert.equal(accStakedTokensPerEpochAndLevel1, ethers.parseEther("425"));
      assert.equal(accStakedTokensPerEpochAndLevel2, ethers.parseEther("325"));
      assert.equal(accStakedTokensPerEpochAndLevel3, ethers.parseEther("1200"));
      assert.equal(accStakedTokensPerEpochAndLevel4, ethers.parseEther("700"));
      // forwading epochs
      await stakingContract.addStakingReward(ethers.parseEther("20000"));
      await helpers.time.increase(30*86400); // 30 days
      await stakingContract.checkForClosingEpochs();
      const epoch2 = await stakingContract.epoch(2);
      // console.log("[TEST] - epoch2.totalTokensBoosted,", epoch2.totalTokensBoosted,);
      assert.equal(await epoch2.totalTokensBoosted, ethers.parseEther("3238.75"));
    });
    it("Start & End Timestamps", async function () {
      // Creating new epoch
      await helpers.time.increase(30*86400); // 30 days
      await stakingContract.checkForClosingEpochs();
      const epoch0 = await stakingContract.epoch(0);
      const epoch1 = await stakingContract.epoch(1);
      const epoch2 = await stakingContract.epoch(2);
      const epochDuration = await stakingContract.epochDuration();
      // console.log("[TEST] -         Start & End Timestamps - Epoch 0 -> startTimestamp", parseInt(epoch0.startTimestamp));
      assert.equal(epoch1.startTimestamp, epoch0.endTimestamp + BigInt(1));
      assert.equal(epoch1.endTimestamp, epoch1.startTimestamp + epochDuration);
      assert.equal(epoch2.startTimestamp, epoch1.endTimestamp + BigInt(1));
      assert.equal(epoch2.endTimestamp, epoch2.startTimestamp + epochDuration);
    });
  });

  describe("Stake", function () {
    it("Should allow different users to stake DEXY tokens in different levels", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
    });
    it("Users balances after staking", async function () {
      // Dexy Balances before staking
      const balanceUser1BeforeStaking = await dexy.balanceOf(user1.address);
      const balanceUser2BeforeStaking = await dexy.balanceOf(user2.address);
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Dexy Balances after staking
      const balanceUser1AfterStaking = await dexy.balanceOf(user1.address);
      const balanceUser2AfterStaking = await dexy.balanceOf(user2.address);
      // Check if the balance after staking is right
      expect(balanceUser1BeforeStaking - balanceUser1AfterStaking).to.equal(ethers.parseEther("600") + ethers.parseEther("400"));
      expect(balanceUser2BeforeStaking - balanceUser2AfterStaking).to.equal(ethers.parseEther("1800"));
      // Check that the user's staked balance is correct
      const stakedAmount1a = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user1.address, 2, 0);
      const stakedAmount1b = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user1.address, 2, 4);
      expect(stakedAmount1a + stakedAmount1b).to.equal(ethers.parseEther("600") + ethers.parseEther("400"));
      const stakedAmount2 = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user2.address, 2, 1);
      expect(stakedAmount2).to.equal(ethers.parseEther("1800"));
    });
    it("Users balances after multiple stakings", async function () {
      // Dexy Balances before staking
      let balanceUser1BeforeStaking = await dexy.balanceOf(user1.address);
      let balanceUser2BeforeStaking = await dexy.balanceOf(user2.address);
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Dexy Balances after staking
      let balanceUser1AfterStaking = await dexy.balanceOf(user1.address);
      let balanceUser2AfterStaking = await dexy.balanceOf(user2.address);
      // Check if the balance after staking is right
      expect(balanceUser1BeforeStaking - balanceUser1AfterStaking).to.equal(ethers.parseEther("600") + ethers.parseEther("400"));
      expect(balanceUser2BeforeStaking - balanceUser2AfterStaking).to.equal(ethers.parseEther("1800"));
      // Check that the user's staked balance is correct
      let stakedAmount1a = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user1.address, 2, 0);
      let stakedAmount1b = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user1.address, 2, 4);
      expect(stakedAmount1a + stakedAmount1b).to.equal(ethers.parseEther("600") + ethers.parseEther("400"));
      let stakedAmount2 = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user2.address, 2, 1);
      expect(stakedAmount2).to.equal(ethers.parseEther("1800"));

      // Next epoch
      await helpers.time.increase(15*86400);
      await stakingContract.checkForClosingEpochs();
      
      // Dexy Balances before staking
      balanceUser1BeforeStaking = await dexy.balanceOf(user1.address);
      balanceUser2BeforeStaking = await dexy.balanceOf(user2.address);

      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("1200"), 2);
      await stakingContract.connect(user1).stake(ethers.parseEther("1000"), 1);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("5000"), 4);
      // Dexy Balances after staking
      balanceUser1AfterStaking = await dexy.balanceOf(user1.address);
      balanceUser2AfterStaking = await dexy.balanceOf(user2.address);
      // Check if the balance after staking is right
      expect(balanceUser1BeforeStaking - balanceUser1AfterStaking).to.equal(ethers.parseEther("1200") + ethers.parseEther("1000"));
      expect(balanceUser2BeforeStaking - balanceUser2AfterStaking).to.equal(ethers.parseEther("5000"));
      // Check that the user's staked balance is correct
      stakedAmount1a = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user1.address, 3, 2);
      stakedAmount1b = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user1.address, 3, 1);
      expect(stakedAmount1a + stakedAmount1b).to.equal(ethers.parseEther("1200") + ethers.parseEther("1000"));
      stakedAmount2 = await stakingContract.stakedTokensPerWalletAndEpochAndLevel(user2.address, 3, 4);
      expect(stakedAmount2).to.equal(ethers.parseEther("5000"));
    });
    it("Users data after staking", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);

      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Get User Data
      const user1Data = await stakingContract.user(user1.address);
      const user2Data = await stakingContract.user(user2.address);
      // Check totalStakedDEXYs
      expect(user1Data.totalStakedDEXYs).to.equal(ethers.parseEther("600") + ethers.parseEther("400"));
      expect(user2Data.totalStakedDEXYs).to.equal(ethers.parseEther("1800"));
      // Check totalStakedDEXYs
      expect(user1Data.totalHarvestedRewards).to.equal(0);
      expect(user2Data.totalHarvestedRewards).to.equal(0);
      // Check stakeIndex
      expect(user1Data.stakeIndex).to.equal(2);
      expect(user2Data.stakeIndex).to.equal(1);
      // Check lastEpochHarvested
      expect(user1Data.lastEpochHarvested).to.equal(0);
      expect(user2Data.lastEpochHarvested).to.equal(0);
    });
    it("Stake data after staking", async function () {
      // EPOCH 1 (Staking effectives on Epoch 2)
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);

      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Get User Data
      const user1StakeInfo1 = await stakingContract.stakeInfo(user1.address,0);
      const user1StakeInfo2 = await stakingContract.stakeInfo(user1.address,1);
      const user2StakeInfo1 = await stakingContract.stakeInfo(user2.address,0);
      // Check levels
      expect(user1StakeInfo1.level).to.equal(0);
      expect(user1StakeInfo2.level).to.equal(4);
      expect(user2StakeInfo1.level).to.equal(1);
      // Check stackedDEXYs
      expect(user1StakeInfo1.stackedDEXYs).to.equal(ethers.parseEther("600"));
      expect(user1StakeInfo2.stackedDEXYs).to.equal(ethers.parseEther("400"));
      expect(user2StakeInfo1.stackedDEXYs).to.equal(ethers.parseEther("1800"));
      // Check startingEpoch
      const currentEpochIndex = await stakingContract.lastClosedEpochIndex()+BigInt(1);
      expect(user1StakeInfo1.startingEpoch).to.equal(currentEpochIndex+BigInt(1));
      expect(user1StakeInfo2.startingEpoch).to.equal(currentEpochIndex+BigInt(1));
      expect(user2StakeInfo1.startingEpoch).to.equal(currentEpochIndex+BigInt(1));
      // Check unlockingEpoch
      const level0 = await stakingContract.level(0);
      const level1 = await stakingContract.level(1);
      const level4 = await stakingContract.level(4);
      const epochDuration = await stakingContract.epochDuration();
      expect(user1StakeInfo1.unlockingEpoch).to.equal(currentEpochIndex+BigInt(1) + (level0.lockingPeriod / epochDuration));
      expect(user1StakeInfo2.unlockingEpoch).to.equal(currentEpochIndex+BigInt(1) + (level4.lockingPeriod / epochDuration));
      expect(user2StakeInfo1.unlockingEpoch).to.equal(currentEpochIndex+BigInt(1) + (level1.lockingPeriod / epochDuration));
      // Check unstacked
      expect(user1StakeInfo1.unstacked).to.equal(false);
      expect(user1StakeInfo2.unstacked).to.equal(false);
      expect(user2StakeInfo1.unstacked).to.equal(false);
    });
  });
  describe("Unstake", async function () {
    it("Should allow users to unstake tokens after the unlocking period", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
    });
    it("Should revert unstake tokens before the unlocking period", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Forwading 1 epoch
      await helpers.time.increase(15*86400);
      await stakingContract.checkForClosingEpochs();
      // Unstake
      await expect(stakingContract.connect(user1).unstake(0)).to.be.rejectedWith('STAKE_STILL_LOCKED');
      await expect(stakingContract.connect(user2).unstake(0)).to.be.rejectedWith('STAKE_STILL_LOCKED');
      await expect(stakingContract.connect(user1).unstake(1)).to.be.rejectedWith('STAKE_STILL_LOCKED');
    });
    it("Should revert unstake tokens if they are already unstaked", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Forwading 3 epoch
      await helpers.time.increase(50*86400);
      await stakingContract.checkForClosingEpochs();
      // Unstake Stake locked from 2 to 3 (2 epochs)
      await stakingContract.connect(user1).unstake(0);
      // Unstake again
      await expect(stakingContract.connect(user1).unstake(0)).to.be.rejectedWith('ALREADY_UNSTAKED');
    });
    it("Users balances after unstake", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0); // User Stake 0
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4); // User Stake 1
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1); // User Stake 0
      // Dexy Balances before unstake
      const DEXYBalanceUser1BeforeUnstake = await dexy.balanceOf(user1.address);
      const DEXYBalanceUser2BeforeUnstake = await dexy.balanceOf(user2.address);
      // Forwading 3 epoch
      await helpers.time.increase(45*86400);
      await stakingContract.checkForClosingEpochs(); // Epochs 1, 2 & 3 closed
      // console.log("[TEST] - Checkpoint 1");
      // Unstake
      await stakingContract.connect(user1).unstake(0);
      // console.log("[TEST] - Checkpoint 2");
      // Forwading 4 epoch
      await helpers.time.increase(60*86400);
      await stakingContract.checkForClosingEpochs();  // Epochs 4, 5, 6 & 7 closed
      // Unstake
      await stakingContract.connect(user2).unstake(0);
      // Forwading 42 epoch
      await helpers.time.increase(645*86400);
      await stakingContract.checkForClosingEpochs();
      // Unstake
      await stakingContract.connect(user1).unstake(1);
      // Dexy Balances after staking
      const DEXYBalanceUser1AfterUnstake = await dexy.balanceOf(user1.address);
      const DEXYBalanceUser2AfterUnstake = await dexy.balanceOf(user2.address);
      // Check if the wallet balance after staking is right
      // Unstake + Rewards Harvested
      // DEXY Balance
      expect(DEXYBalanceUser1BeforeUnstake + ethers.parseEther("600") + ethers.parseEther("400")).to.be.equal(DEXYBalanceUser1AfterUnstake);
      expect(DEXYBalanceUser2BeforeUnstake + ethers.parseEther("1800")).to.be.equal(DEXYBalanceUser2AfterUnstake);
    });
    it("Users data after unstake", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("400"), 4);
      // Stake DEXY tokens for the user 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1800"), 1);
      // Dexy Balances before unstake
      const balanceUser1BeforeUntake = await dexy.balanceOf(user1.address);
      const balanceUser2BeforeUntake = await dexy.balanceOf(user2.address);
      // Forwading 3 epoch
      await helpers.time.increase(45*86400);
      await stakingContract.checkForClosingEpochs(); // Epochs 1, 2 & 3 closed
      // Unstake
      await stakingContract.connect(user1).unstake(0);
      // Forwading 4 epoch
      await helpers.time.increase(60*86400);
      await stakingContract.checkForClosingEpochs();  // Epochs 4, 5, 6 & 7 closed
      // Unstake
      await stakingContract.connect(user2).unstake(0);
      // Forwading 42 epoch
      await helpers.time.increase(645*86400);
      await stakingContract.checkForClosingEpochs();
      // Unstake
      await stakingContract.connect(user1).unstake(1);
      // Get User Data
      const user1StakeInfo1 = await stakingContract.stakeInfo(user1.address,0);
      const user1StakeInfo2 = await stakingContract.stakeInfo(user1.address,1);
      const user2StakeInfo1 = await stakingContract.stakeInfo(user2.address,0);
      // Check levels
      expect(user1StakeInfo1.level).to.equal(0);
      expect(user1StakeInfo2.level).to.equal(4);
      expect(user2StakeInfo1.level).to.equal(1);
      // Check stackedDEXYs
      expect(user1StakeInfo1.stackedDEXYs).to.equal(ethers.parseEther("600"));
      expect(user1StakeInfo2.stackedDEXYs).to.equal(ethers.parseEther("400"));
      expect(user2StakeInfo1.stackedDEXYs).to.equal(ethers.parseEther("1800"));
      // Check unstacked
      expect(user1StakeInfo1.unstacked).to.equal(true);
      expect(user1StakeInfo2.unstacked).to.equal(true);
      expect(user2StakeInfo1.unstacked).to.equal(true);
    });
    it("Should allow unstake tokens after havesting", async function () {
      //Adding Rewards
      // console.log("======================================");
      // console.log("Adding 10000$ rewards")
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("======================================");
      // console.log("Starting at Epoch 1")
      // console.log("======================================");
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("======================================");
      // console.log("User 1 Stake 750 DEXYs at Level 0");
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 1 Stake 250 DEXYs at Level 1");
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 2 Stake 1745 DEXYs at Level 0");
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 2 Stake 2250 DEXYs at Level 4");
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 3 Stake 1500 DEXYs at Level 2");
      // console.log("======================================");
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Moving forward 1 epoch");
      // console.log("======================================");
      await helpers.time.increase(15*86400);
      // console.log("======================================");
      // console.log("Check for closing epochs (epoch 1)")
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs(); // CLOSE EPOCH 1
      //Adding Rewards
      //Adding Rewards
      // console.log("======================================");
      // console.log("Adding 20000$ rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("20000")); // Rewards 20000 $
      // Moving forward 2 Epochs
      // console.log("======================================");
      // console.log("Moving forward 1 epoch");
      // console.log("======================================");
      await helpers.time.increase(30*86400);
      // console.log("======================================");
      // console.log("Check for closing epochs (epochs 2 & 3)");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs(); // CLOSE EPOCHS 2 & 3
      // harvesting
      // console.log("======================================");
      // console.log("Harvesting User 1 Rewards");
      // console.log("======================================");
      await stakingContract.connect(user1).harvest();
      // Dexy Balances before unstake
      const balanceUser1BeforeHarvesting = await dexy.balanceOf(user1.address);
      // console.log("======================================");
      // console.log("Dexy Balances before unstake", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // Assert
      // console.log("======================================");
      // console.log("Unstaking stake 0");
      // console.log("======================================");
      await expect(stakingContract.connect(user1).unstake(0)).to.not.be.reverted;
      // Dexy Balances after unstake
      const balanceUser1AfterHarvesting = await dexy.balanceOf(user1.address);
      // console.log("======================================");
      // console.log("Dexy Balances before unstake", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // Check stackedDEXYs
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.equal(ethers.parseEther("750"));
    });
  });

  describe("Harvest", async function () {
    it("Should revert if there are no staked tokens", async function () {
      // Adding Rewards
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $
      // Moving forward 2 Epochs
      await helpers.time.increase(30*86400);
      await stakingContract.checkForClosingEpochs(); // CLOSE EPOCHS 1 & 2
      // expect(await stakingContract.connect(user1).isHarvestable()).to.equal(false);
      await expect(stakingContract.connect(user1).harvest()).to.be.rejectedWith("NO_STAKED_TOKENS");
    });
    it("Should revert if there are no epochs to harvest", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      // Check havest
      // expect(await stakingContract.connect(user1).isHarvestable()).to.equal(false);
      await expect(stakingContract.connect(user1).harvest()).to.be.rejectedWith("NO_EPOCHS_TO_HARVEST");
    });
    it("Should allow harvesting rewards", async function () {
      // Stake DEXY tokens for the user 1
      await stakingContract.connect(user1).stake(ethers.parseEther("600"), 0);
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1);
      await stakingContract.connect(user1).stake(ethers.parseEther("745"), 3);
      // Adding Rewards
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $
      // Moving forward 2 Epochs
      await helpers.time.increase(30*86400);
      await expect(stakingContract.connect(user1).harvest()).to.not.be.reverted;
    });
    it("Rewards distribution is right for several users & stakings in a single epoch", async function () {
      // console.log("======================================");
      // console.log("Starting at Epoch 1")
      // console.log("======================================");
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("======================================");
      // console.log("User 1 Stake 750 DEXYs at Level 0")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 1 Stake 250 DEXYs at Level 1")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 2 Stake 1745 DEXYs at Level 0")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 2 Stake 2250 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 3 Stake 1500 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Dexy Balances before harvesting
      const balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // Moving forward 1 Epochs
      // console.log("======================================");
      // console.log("Increase time to Epoch 2")
      // console.log("======================================");
      await helpers.time.increase(15*86400);
      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 1");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();
      // console.log("======================================");
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 10000$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $
      // Moving forward 2 Epochs
      await helpers.time.increase(30*86400);
      // harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // Dexy Balances after harvesting
      const balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      // Asserts
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("1098.59"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("1098.6"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("6547.22"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("6547.23"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("2354.12"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("2354.13"));
    });
    it("Rewards distribution is right for several users & stakings in several epochs", async function () {
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Adding Rewards
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $
      // Moving forward 1 Epochs
      await helpers.time.increase(15*86400);
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      await stakingContract.connect(user1).stake(ethers.parseEther("999"), 4);
      await stakingContract.connect(user2).stake(ethers.parseEther("500"), 2);
      await stakingContract.connect(user2).stake(ethers.parseEther("700"), 4);
      // Dexy Balances before harvesting
      const balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // Adding Rewards
      await stakingContract.addStakingReward(ethers.parseEther("20000")); // Rewards 10000 $
      // Moving forward 2 Epochs
      await helpers.time.increase(30*86400);
      // harvesting
      await stakingContract.connect(user1).harvest();
      await stakingContract.connect(user2).harvest();
      await stakingContract.connect(user3).harvest();
      // Dexy Balances after harvesting
      const balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // Asserts
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("3333.79"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("3333.8"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("12675.45"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("12675.46"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("3990.72"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("3990.73"));
    });
    it("Rewards distribution is right for several users & stakings in several epochs, missing stake in some of them", async function () {
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Adding Rewards
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $
      // Moving forward 1 Epochs
      await helpers.time.increase(15*86400);
      // Stake DEXY tokens EFFECTIVE EPOCH 3
      await stakingContract.connect(user1).stake(ethers.parseEther("999"), 4); // EFFECTIVE ON EPOCH 3
      await stakingContract.connect(user2).stake(ethers.parseEther("500"), 2); // EFFECTIVE ON EPOCH 3
      await stakingContract.connect(user2).stake(ethers.parseEther("700"), 4); // EFFECTIVE ON EPOCH 3
      // Dexy Balances before harvesting
      const balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // Adding Rewards
      await stakingContract.addStakingReward(ethers.parseEther("30000")); // Rewards 10000 $
      // Moving forward 2 Epochs
      await helpers.time.increase(45*86400);
      // harvesting
      await stakingContract.connect(user1).harvest();
      await stakingContract.connect(user2).harvest();
      await stakingContract.connect(user3).harvest();
      // Dexy Balances after harvesting
      const balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // Asserts
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("5568.99"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("5569"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("18803.66"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("18803.67"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("5627.31"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("5627.32"));
    });
    it("Rewards distribution is right for several users & stakings in several epochs with different rewards, missing stake in some of them", async function () {
      // console.log("======================================");
      // console.log("Starting at Epoch 1")
      // console.log("======================================");
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("======================================");
      // console.log("User 1 Stake 750 DEXYs at Level 0")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 1 Stake 250 DEXYs at Level 1")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 2 Stake 1745 DEXYs at Level 0")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 2 Stake 2250 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      // console.log("======================================");
      // console.log("User 3 Stake 1500 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Moving forward 1 Epochs
      // console.log("======================================");
      // console.log("Increase time to Epoch 2")
      // console.log("======================================");
      await helpers.time.increase(15*86400);
      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 1");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 7500$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("7500")); // Rewards 7500 $
      // Stake DEXY tokens EFFECTIVE EPOCH 3
      // console.log("======================================");
      // console.log("User 1 Stake 999 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("999"), 4); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 500 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("500"), 2); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 700 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("700"), 4); // EFFECTIVE ON EPOCH 3
      // Dexy Balances before harvesting
      const balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 12300$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("12300")); // Rewards 12300 $
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 6600$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("6600")); // Rewards 6600 $
      // console.log("======================================");
      // console.log("Increase time to Epoch 5")
      // console.log("======================================");
      // Moving forward 2 Epochs
      await helpers.time.increase(45*86400);
      // harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // Dexy Balances after harvesting
      const balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      // Asserts
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("4900.69"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("4900.70"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("16547.15"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("16547.16"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("4952.01"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("4952.02"));
    });
    it("Rewards distribution is right harvesting after another harvest without staking aditional tokens", async function () {
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("=================================");
      // console.log("User 1 Stake 750 DEXYs at Level 0");
      // console.log("=================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 1 Stake 250 DEXYs at Level 1");
      // console.log("=================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 2 Stake 1745 DEXYs at Level 0");
      // console.log("=================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 2 Stake 2250 DEXYs at Level 4");
      // console.log("=================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 3 Stake 1500 DEXYs at Level 2");
      // console.log("=================================");
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Moving forward 1 Epochs
      // console.log("======================================");
      // console.log("Increase time to Epoch 2")
      // console.log("======================================");
      await helpers.time.increase(15*86400);
      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 1");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 7500$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("7500")); // Rewards 7500 $
      // Stake DEXY tokens EFFECTIVE EPOCH 3
      // console.log("======================================");
      // console.log("User 1 Stake 999 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("999"), 4); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 500 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("500"), 2); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 700 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("700"), 4); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("Increase time to Epoch 5")
      // console.log("======================================");
      // Moving forward 3 Epochs to epoch 5
      await helpers.time.increase(45*86400);
      // harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 19000$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("19000")); // Rewards 19000 $
      // console.log("======================================");
      // console.log("Increase time to Epoch 7")
      // console.log("======================================");
      // Moving forward 3 Epochs to epoch 7
      await helpers.time.increase(30*86400);
      // Dexy Balances before harvesting
      const balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");
      // harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // Dexy Balances after harvesting
      const balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      const balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      const balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      // Asserts
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("4246.8"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("4246.9"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("11643.5"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("11643.6"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("3109.5"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("3109.6"));
    });
    it("Rewards distribution is right in low complex staking, unstaking some tokens in the middle", async function () {
      let balanceUser1BeforeHarvesting;
      let balanceUser2BeforeHarvesting;
      let balanceUser3BeforeHarvesting;
      let balanceUser1AfterHarvesting;
      let balanceUser2AfterHarvesting;
      let balanceUser3AfterHarvesting;

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 0 - EPOCH BY TIME 1 ///
      /////////////////////////////////////////////
      
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("=================================");
      // console.log("User 1 Stake 750 DEXYs at Level 0");
      // console.log("=================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 1 Stake 250 DEXYs at Level 1");
      // console.log("=================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 2 Stake 1745 DEXYs at Level 0");
      // console.log("=================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 2 Stake 2250 DEXYs at Level 4");
      // console.log("=================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 3 Stake 1500 DEXYs at Level 2");
      // console.log("=================================");
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Moving forward 1 Epochs
      // console.log("======================================");
      // console.log("Increase time to Epoch 2 - Epoch 1 forwaded!")
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 0 - EPOCH BY TIME 2 ///
      /////////////////////////////////////////////

      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 1");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 1 - EPOCH BY TIME 2 ///
      /////////////////////////////////////////////

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 7500$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("7500")); // Rewards 7500 $
      // Stake DEXY tokens EFFECTIVE EPOCH 3

      // console.log("======================================");
      // console.log("User 1 Stake 999 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("999"), 4); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 500 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("500"), 2); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 700 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("700"), 4); // EFFECTIVE ON EPOCH 3

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 3 - Epoch 2 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 2");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 2 - EPOCH BY TIME 3 ///
      /////////////////////////////////////////////

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 12300$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("12300")); // Rewards 12300 $
      // Dexy Balances before harvesting
      balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 2 - EPOCH BY TIME 3 ///
      /////////////////////////////////////////////

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 4 - Epoch 3 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 2 - EPOCH BY TIME 4 ///
      /////////////////////////////////////////////

      // Unstaking some tokens
      // console.log("======================================");
      // console.log("User 1 Unstake its stake 0");
      // console.log("======================================");
      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 3 - EPOCH BY TIME 4 ///
      /////////////////////////////////////////////
      await stakingContract.connect(user1).unstake(0);
      // Harvesting
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // USDT Balances after harvesting
      balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("3573.2"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("3573.3"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("12448"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("12448.1"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("3778.5"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("3778.6"));

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 6600$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("6600")); // Rewards 6600 $

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 5 - Epoch 4 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 3 - EPOCH BY TIME 5 ///
      /////////////////////////////////////////////

      // Dexy Balances before harvesting
      balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");
    
      // Harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 4 - EPOCH BY TIME 5 ///
      /////////////////////////////////////////////
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // USDT Balances after harvesting
      balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("1187.3"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("1187.4"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("4271.8"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("4271.9"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("1140.8"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("1140.9"));
    });
    it("Rewards distribution is right in complex staking, unstaking some tokens in the middle and users harvesting in different epochs", async function () {
      let balanceUser1BeforeHarvesting;
      let balanceUser2BeforeHarvesting;
      let balanceUser3BeforeHarvesting;
      let balanceUser1AfterHarvesting;
      let balanceUser2AfterHarvesting;
      let balanceUser3AfterHarvesting;

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 0 - EPOCH BY TIME 1 ///
      /////////////////////////////////////////////
      
      // Stake DEXY tokens EFFECTIVE EPOCH 2
      // console.log("=================================");
      // console.log("User 1 Stake 750 DEXYs at Level 0");
      // console.log("=================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("750"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 1 Stake 250 DEXYs at Level 1");
      // console.log("=================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("250"), 1); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 2 Stake 1745 DEXYs at Level 0");
      // console.log("=================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("1745"), 0); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 2 Stake 2250 DEXYs at Level 4");
      // console.log("=================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("2250"), 4); // EFFECTIVE ON EPOCH 2
      // console.log("=================================");
      // console.log("User 3 Stake 1500 DEXYs at Level 2");
      // console.log("=================================");
      await stakingContract.connect(user3).stake(ethers.parseEther("1500"), 2); // EFFECTIVE ON EPOCH 2
      // Moving forward 1 Epochs
      // console.log("======================================");
      // console.log("Increase time to Epoch 2 - Epoch 1 forwaded!")
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 0 - EPOCH BY TIME 2 ///
      /////////////////////////////////////////////

      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 1");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 1 - EPOCH BY TIME 2 ///
      /////////////////////////////////////////////

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 7500$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("7500")); // Rewards 7500 $
      // Stake DEXY tokens EFFECTIVE EPOCH 3

      // console.log("======================================");
      // console.log("User 1 Stake 999 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user1).stake(ethers.parseEther("999"), 4); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 500 DEXYs at Level 2")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("500"), 2); // EFFECTIVE ON EPOCH 3
      // console.log("======================================");
      // console.log("User 2 Stake 700 DEXYs at Level 4")
      // console.log("======================================");
      await stakingContract.connect(user2).stake(ethers.parseEther("700"), 4); // EFFECTIVE ON EPOCH 3

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 3 - Epoch 2 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      // Closing epoch 1
      // console.log("======================================");
      // console.log("Closing epoch 2");
      // console.log("======================================");
      await stakingContract.checkForClosingEpochs();

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 2 - EPOCH BY TIME 3 ///
      /////////////////////////////////////////////

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 12300$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("12300")); // Rewards 12300 $
      // Dexy Balances before harvesting
      balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 2 - EPOCH BY TIME 3 ///
      /////////////////////////////////////////////

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 4 - Epoch 3 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 2 - EPOCH BY TIME 4 ///
      /////////////////////////////////////////////

      // Unstaking some tokens
      // console.log("======================================");
      // console.log("User 1 Unstake its stake 0");
      // console.log("======================================");
      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 3 - EPOCH BY TIME 4 ///
      /////////////////////////////////////////////
      await stakingContract.connect(user1).unstake(0);
      // Harvesting
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // USDT Balances after harvesting
      balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("3573.2"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("3573.3"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("12448"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("12448.1"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("3778.5"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("3778.6"));

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 6600$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("6600")); // Rewards 6600 $

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 5 - Epoch 4 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 3 - EPOCH BY TIME 5 ///
      /////////////////////////////////////////////

      // Dexy Balances before harvesting
      balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");
    
      // Harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 4 - EPOCH BY TIME 5 ///
      /////////////////////////////////////////////
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // USDT Balances after harvesting
      balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("1187.3"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("1187.4"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("4271.8"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("4271.9"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("1140.8"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("1140.9"));

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 9000$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("9000")); // Rewards 9000 $

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 6 - Epoch 5 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 4 - EPOCH BY TIME 6 ///
      /////////////////////////////////////////////

      // USDT Balances before harvesting
      balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");

      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 5 - EPOCH BY TIME 6 ///
      /////////////////////////////////////////////
      await stakingContract.connect(user2).harvest();

      // USDT Balances after harvesting
      balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      
      // Assert
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("5825.1"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("5825.2"));

      // Adding Rewards
      // console.log("======================================");
      // console.log("Add 10000$ as rewards");
      // console.log("======================================");
      await stakingContract.addStakingReward(ethers.parseEther("10000")); // Rewards 10000 $

      // Moving forward 1 Epoch
      // console.log("======================================");
      // console.log("Increase time to Epoch 7 - Epoch 6 forwaded!");
      // console.log("======================================");
      await helpers.time.increase(15*86400);

      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 5 - EPOCH BY TIME 7 ///
      /////////////////////////////////////////////

      // Dexy Balances before harvesting
      balanceUser1BeforeHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2BeforeHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3BeforeHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance Before Harvesting", balanceUser1BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance Before Harvesting", balanceUser2BeforeHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance Before Harvesting", balanceUser3BeforeHarvesting);
      // console.log("======================================");
    
      // Harvesting
      // console.log("======================================");
      // console.log("User 1 Harvest")
      // console.log("======================================");
      /////////////////////////////////////////////
      /// LAST CLOSED EPOCH 6 - EPOCH BY TIME 7 ///
      /////////////////////////////////////////////
      await stakingContract.connect(user1).harvest();
      // console.log("======================================");
      // console.log("User 2 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user2).harvest();
      // console.log("======================================");
      // console.log("User 3 Harvest")
      // console.log("======================================");
      await stakingContract.connect(user3).harvest();
      // USDT Balances after harvesting
      balanceUser1AfterHarvesting = await usdt.balanceOf(user1.address);
      balanceUser2AfterHarvesting = await usdt.balanceOf(user2.address);
      balanceUser3AfterHarvesting = await usdt.balanceOf(user3.address);
      // console.log("======================================");
      // console.log("User 1 Balance After Harvesting", balanceUser1AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 2 Balance After Harvesting", balanceUser2AfterHarvesting);
      // console.log("======================================");
      // console.log("======================================");
      // console.log("User 3 Balance After Harvesting", balanceUser3AfterHarvesting);
      // console.log("======================================");
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.above(ethers.parseEther("3418"));
      expect(balanceUser1AfterHarvesting - balanceUser1BeforeHarvesting).to.be.below(ethers.parseEther("3418.1"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.above(ethers.parseEther("6472.4"));
      expect(balanceUser2AfterHarvesting - balanceUser2BeforeHarvesting).to.be.below(ethers.parseEther("6472.5"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.above(ethers.parseEther("3284.1"));
      expect(balanceUser3AfterHarvesting - balanceUser3BeforeHarvesting).to.be.below(ethers.parseEther("3284.2"));
    });
  });
  describe("Development", function () {
    // it("1", async function () {
    //   // console.log("getEpochIndexByTimestamp(\"2016849015\")", await stakingContract.getEpochIndexByTimestamp("20037586035"));
    // });
  });
});

