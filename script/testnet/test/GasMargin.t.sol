// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployTestnet} from "../DeployTestnet.s.sol";
import {TestnetFaucet, TestnetToken} from "../TestnetFaucet.sol";
import {DexynthStakingV2_2} from "../../../src/DexynthStaking.sol";

/**
 * @title GasMarginTest
 * @notice Measures the state-dependent cost the node's gas estimate can miss, and checks the app's margin covers it
 * @dev The node estimates a call at the latest block's timestamp. When another call already updated the pool in that
 *      block, _updatePool returns early in the estimate; when the user was also settled in that block, so does
 *      _settle. One block later both write, so the landed call costs more than the estimate. The app sends
 *      estimate * 125 / 100 + 25,000 gas (app/src/hooks/useTx.ts). Each scenario measures the call twice from the
 *      same state, in the estimate's block and one block later, with the contract's storage cooled first so both
 *      runs pay cold access as a separate transaction would
 */
contract GasMarginTest is Test {
    uint256 internal constant APP_MARGIN_FIXED = 25_000;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    DexynthStakingV2_2 internal staking;
    TestnetFaucet internal faucet;
    TestnetToken internal dexy;

    function setUp() public {
        vm.warp(1_800_000_000);
        DeployTestnet script = new DeployTestnet();
        script.run();
        (faucet, staking,,) = script.deployment();
        dexy = faucet.DEXY();
        address[2] memory users = [ALICE, BOB];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            faucet.claim();
            dexy.approve(address(staking), type(uint256).max);
            staking.stake(1_000e18, 0);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 2 days);
    }

    /**
     * @dev Bob's call updated the pool in the estimate's block; Alice was last settled long before
     */
    function test_StakeAfterAnotherCallInTheSameBlock() public {
        _poke(BOB);
        _check(abi.encodeCall(DexynthStakingV2_2.stake, (1_000e18, 0)));
    }

    /**
     * @dev Alice herself was settled in the estimate's block, by a harvest, so both early returns apply
     */
    function test_StakeAfterOwnHarvestInTheSameBlock() public {
        vm.prank(ALICE);
        staking.harvest();
        _check(abi.encodeCall(DexynthStakingV2_2.stake, (1_000e18, 0)));
    }

    function test_HarvestAfterAnotherCallInTheSameBlock() public {
        _poke(BOB);
        _check(abi.encodeCall(DexynthStakingV2_2.harvest, ()));
    }

    function test_UnstakeAfterAnotherCallInTheSameBlock() public {
        _poke(BOB);
        _check(abi.encodeCall(DexynthStakingV2_2.unstake, (0)));
    }

    function _poke(address _user) internal {
        vm.prank(_user);
        staking.harvest();
    }

    /**
     * @dev Gas of _call from Alice in the current block (the estimate) and two seconds later (the landing)
     */
    function _check(bytes memory _call) internal {
        uint256 snapshot = vm.snapshotState();
        uint256 estimated = _measure(_call);
        vm.revertToState(snapshot);
        vm.warp(block.timestamp + 2);
        uint256 landed = _measure(_call);

        emit log_named_uint("estimate block", estimated);
        emit log_named_uint("landing block", landed);
        assertGt(landed, estimated, "the landing block costs more");
        assertLe(landed - estimated, APP_MARGIN_FIXED, "the fixed margin alone covers the difference");
        assertLe(landed, estimated * 125 / 100 + APP_MARGIN_FIXED);
    }

    function _measure(bytes memory _call) internal returns (uint256 used) {
        vm.cool(address(staking));
        vm.cool(address(dexy));
        vm.cool(address(faucet.USDC()));
        vm.prank(ALICE);
        uint256 before = gasleft();
        (bool ok,) = address(staking).call(_call);
        used = before - gasleft();
        assertTrue(ok, "call succeeds");
    }
}
