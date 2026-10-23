// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "./utils/StakingFixture.sol";
import {DexynthStakingV2_3} from "../src/DexynthStaking.sol";

/**
 * @notice Constructor validations and parameter checks
 */
contract ValidationTest is StakingFixture {
    function setUp() public {
        _deploy(18);
    }

    function _new(address _dexy, address _reward, DexynthStakingV2_3.Level[] memory _lv, uint256 _epoch) internal {
        new DexynthStakingV2_3(_dexy, _reward, _lv, _epoch, block.timestamp + 1 days);
    }

    function test_RevertWhen_DexyIsZero() public {
        vm.expectRevert(DexynthStakingV2_3.WrongParams.selector);
        _new(address(0), address(reward), _levels(), EPOCH);
    }

    function test_RevertWhen_RewardTokenIsZero() public {
        vm.expectRevert(DexynthStakingV2_3.WrongParams.selector);
        _new(address(dexy), address(0), _levels(), EPOCH);
    }

    function test_RevertWhen_EpochShorterThanOneDay() public {
        vm.expectRevert(DexynthStakingV2_3.MinimumOneDay.selector);
        _new(address(dexy), address(reward), _levels(), 1 days - 1);
    }

    function test_EpochOfExactlyOneDayIsAccepted() public {
        DexynthStakingV2_3 s = new DexynthStakingV2_3(address(dexy), address(reward), _levels(), 1 days, START);
        assertEq(s.epochDuration(), 1 days);
    }

    function test_RevertWhen_FirstEpochStartIsNotInFuture() public {
        vm.expectRevert(abi.encodeWithSelector(DexynthStakingV2_3.StartNotInFuture.selector, block.timestamp));
        new DexynthStakingV2_3(address(dexy), address(reward), _levels(), EPOCH, block.timestamp);
    }

    function test_FirstEpochStartOneSecondAheadIsAccepted() public {
        DexynthStakingV2_3 s =
            new DexynthStakingV2_3(address(dexy), address(reward), _levels(), EPOCH, block.timestamp + 1);
        assertEq(s.I_GENESIS_EPOCH_TIMESTAMP(), block.timestamp + 1);
        assertEq(s.nextEpochStart(), block.timestamp + 1);
        assertEq(s.lastRewardTime(), block.timestamp);
    }

    function test_RevertWhen_FirstEpochStartDoesNotFitUint40() public {
        vm.expectRevert("SafeCast: value doesn't fit in 40 bits");
        new DexynthStakingV2_3(address(dexy), address(reward), _levels(), EPOCH, uint256(type(uint40).max) + 1);
    }

    function test_RevertWhen_EpochDoesNotFitUint32() public {
        vm.expectRevert("SafeCast: value doesn't fit in 32 bits");
        _new(address(dexy), address(reward), _levels(), uint256(type(uint32).max) + 1);
    }

    function test_RevertWhen_NoLevels() public {
        vm.expectRevert(DexynthStakingV2_3.NoLevels.selector);
        _new(address(dexy), address(reward), new DexynthStakingV2_3.Level[](0), EPOCH);
    }

    function test_SingleLevelMustBeOneX() public {
        DexynthStakingV2_3.Level[] memory lv = new DexynthStakingV2_3.Level[](1);
        lv[0] = DexynthStakingV2_3.Level(30 days, 1e10, 0);
        DexynthStakingV2_3 s = new DexynthStakingV2_3(address(dexy), address(reward), lv, EPOCH, START);
        assertEq(s.getNumberOfLevels(), 1);

        lv[0].boostP = 1e10 + 1;
        vm.expectRevert(DexynthStakingV2_3.BoostSumNotRight.selector);
        _new(address(dexy), address(reward), lv, EPOCH);
    }

    function test_RevertWhen_LockNotStrictlyIncreasing() public {
        DexynthStakingV2_3.Level[] memory lv = _levels();
        lv[3].lockingPeriod = lv[2].lockingPeriod;
        vm.expectRevert(DexynthStakingV2_3.WrongValues.selector);
        _new(address(dexy), address(reward), lv, EPOCH);
    }

    function test_RevertWhen_BoostNotStrictlyIncreasing() public {
        DexynthStakingV2_3.Level[] memory lv = _levels();
        // 0.65 + 0.85 + 1.0 + 1.0 + 1.5 = 5.0x, so only the ordering check can reject it
        lv[2].boostP = 10000000000;
        lv[3].boostP = 10000000000;
        lv[4].boostP = 15000000000;
        vm.expectRevert(DexynthStakingV2_3.WrongValues.selector);
        _new(address(dexy), address(reward), lv, EPOCH);
    }

    function test_RevertWhen_BoostsDoNotAverageOneX() public {
        DexynthStakingV2_3.Level[] memory lv = _levels();
        lv[4].boostP += 1;
        vm.expectRevert(DexynthStakingV2_3.BoostSumNotRight.selector);
        _new(address(dexy), address(reward), lv, EPOCH);
    }

    function test_RevertWhen_RewardDepositIsZero() public {
        vm.expectRevert(DexynthStakingV2_3.WrongParams.selector);
        staking.addStakingReward(0);
    }

    function test_RevertWhen_MigrationTargetIsZero() public {
        vm.expectRevert(DexynthStakingV2_3.AddressZero.selector);
        staking.requestMigration(address(0));
    }

    function test_RevertWhen_MigrationExecutedOneSecondBeforeDelay() public {
        staking.requestMigration(address(0xDEAD));
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(DexynthStakingV2_3.TimelockStillActive.selector);
        staking.executeMigration();
    }

    function test_RevertWhen_NonOwnerCancelsOrExecutesMigration() public {
        staking.requestMigration(address(0xDEAD));
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.cancelMigration();
        vm.expectRevert("Ownable: caller is not the owner");
        staking.executeMigration();
        vm.stopPrank();
    }
}
