// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestnetFaucet, TestnetToken} from "../TestnetFaucet.sol";
import {DexynthStakingV2_2} from "../../../src/DexynthStaking.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";

/**
 * @dev Claims through throwaway contracts, each a fresh address, in one transaction
 */
contract Farmer {
    constructor(TestnetFaucet _faucet, address _to) {
        _faucet.claim();
        _faucet.DEXY().transfer(_to, _faucet.DEXY_DRIP());
    }
}

/**
 * @title TestnetFaucetTest
 * @notice The faucet's daily limit, its owner-only functions and what a stranger can and cannot do with it
 * @dev Run with FOUNDRY_PROFILE=testnet
 */
contract TestnetFaucetTest is Test {
    address internal constant OWNER = address(0x0E);
    address internal constant ALICE = address(0xA11CE);
    address internal constant GRIEFER = address(0xBAD);

    TestnetFaucet internal faucet;
    TestnetToken internal dexy;
    TestnetToken internal usdc;

    function setUp() public {
        vm.warp(1_800_000_000);
        faucet = new TestnetFaucet(OWNER);
        dexy = faucet.DEXY();
        usdc = faucet.USDC();
    }

    function test_TokensHaveTheirDecimalsAndTheFaucetAsMinter() public view {
        assertEq(dexy.decimals(), 18);
        assertEq(usdc.decimals(), 6);
        assertEq(dexy.MINTER(), address(faucet));
        assertEq(usdc.MINTER(), address(faucet));
        assertEq(faucet.owner(), OWNER);
    }

    function test_ClaimSendsTheDripOnly() public {
        vm.prank(ALICE, ALICE);
        faucet.claim();
        assertEq(dexy.balanceOf(ALICE), 10_000e18);
        assertEq(usdc.balanceOf(ALICE), 0);
        assertEq(faucet.nextClaimAt(ALICE), block.timestamp + 1 days);
    }

    function test_OwnerClaimAlsoSendsUsdcToFundTheStream() public {
        vm.prank(OWNER, OWNER);
        faucet.claim();
        assertEq(dexy.balanceOf(OWNER), 10_000e18);
        assertEq(usdc.balanceOf(OWNER), 100_000e6);
        assertEq(faucet.nextClaimAt(OWNER), block.timestamp + 1 days);
    }

    function test_SecondClaimWithinADayReverts() public {
        vm.prank(ALICE, ALICE);
        faucet.claim();
        uint256 next = block.timestamp + 1 days;

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.ClaimTooSoon.selector, ALICE, next));
        vm.prank(ALICE, ALICE);
        faucet.claim();

        vm.warp(next);
        vm.prank(ALICE, ALICE);
        faucet.claim();
        assertEq(dexy.balanceOf(ALICE), 20_000e18);
    }

    function test_ContractsCannotClaim() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.ClaimFromContract.selector, address(this)));
        faucet.claim();
    }

    /**
     * @dev Without the check, 100 contracts claimed the whole seed's worth of DEXY in one transaction
     */
    function test_ClaimsCannotBeFarmedThroughContracts() public {
        vm.startPrank(GRIEFER, GRIEFER);
        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert();
            new Farmer(faucet, GRIEFER);
        }
        vm.stopPrank();
        assertEq(dexy.balanceOf(GRIEFER), 0);
    }

    function test_NobodyButTheFaucetMintsTokens() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetToken.OnlyMinter.selector, GRIEFER));
        vm.prank(GRIEFER);
        dexy.mint(GRIEFER, 1);

        vm.expectRevert(abi.encodeWithSelector(TestnetToken.OnlyMinter.selector, OWNER));
        vm.prank(OWNER);
        usdc.mint(OWNER, 1);
    }

    function test_MintIsOwnerOnlyAndLimitedToItsTokens() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(GRIEFER);
        faucet.mint(address(usdc), GRIEFER, 1e6);

        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.UnknownToken.selector, address(0x1234)));
        vm.prank(OWNER);
        faucet.mint(address(0x1234), OWNER, 1);

        vm.prank(OWNER);
        faucet.mint(address(usdc), ALICE, 5e6);
        assertEq(usdc.balanceOf(ALICE), 5e6);
    }

    function test_SeedStakeIsOwnerOnlyAndBelongsToTheFaucet() public {
        DeployTestnet script = new DeployTestnet();
        DexynthStakingV2_2 staking = new DexynthStakingV2_2(address(dexy), address(usdc), script.demoLevels(), 1 days);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(GRIEFER);
        faucet.seedStake(address(staking), 0, 1e18);

        vm.prank(OWNER);
        faucet.seedStake(address(staking), 2, 1_000e18);
        (,, uint128 totalStakedDexy, uint128 boosted,,) = staking.users(address(faucet));
        assertEq(totalStakedDexy, 1_000e18);
        assertEq(boosted, 1_000e18, "level 2 is 1.0x");
        assertEq(dexy.balanceOf(address(staking)), 1_000e18);

        // The seed is the faucet's: nobody else can unstake it, and the faucet has no function that does
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(DexynthStakingV2_2.StakeNotFound.selector);
        vm.prank(OWNER);
        staking.unstake(0);
    }

    function test_SeedStakeRejectsAContractThatStakesAnotherToken() public {
        DeployTestnet script = new DeployTestnet();
        TestnetToken other = new TestnetToken("Other", "OTH", 18);
        DexynthStakingV2_2 staking = new DexynthStakingV2_2(address(other), address(usdc), script.demoLevels(), 1 days);

        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.WrongStakingToken.selector, address(staking)));
        vm.prank(OWNER);
        faucet.seedStake(address(staking), 0, 1e18);
    }
}
