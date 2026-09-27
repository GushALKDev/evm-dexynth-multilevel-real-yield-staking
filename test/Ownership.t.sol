// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StakingFixture} from "./utils/StakingFixture.sol";

interface IOwnable2Step {
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

/**
 * @notice Ownership changes need two steps and ownership cannot be renounced
 */
contract OwnershipTest is StakingFixture {
    bytes4 internal constant RENOUNCE_DISABLED = bytes4(keccak256("RenounceOwnershipDisabled()"));
    address internal newOwner = address(0x0E1);

    function setUp() public {
        _deploy(18);
    }

    function test_TransferNeedsAcceptance() public {
        staking.transferOwnership(newOwner);
        assertEq(staking.owner(), owner);
        assertEq(IOwnable2Step(address(staking)).pendingOwner(), newOwner);

        vm.prank(alice);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        IOwnable2Step(address(staking)).acceptOwnership();

        vm.prank(newOwner);
        IOwnable2Step(address(staking)).acceptOwnership();
        assertEq(staking.owner(), newOwner);
        assertEq(IOwnable2Step(address(staking)).pendingOwner(), address(0));
    }

    function test_RevertWhen_RenounceOwnership() public {
        vm.expectRevert(RENOUNCE_DISABLED);
        staking.renounceOwnership();
        assertEq(staking.owner(), owner);
    }

    /**
     * @notice A pending migration request survives an ownership change and the new owner can execute it
     */
    function test_PendingMigrationSurvivesOwnershipChange() public {
        _fund(1000 ether, 60 days);
        staking.requestMigration(address(0xDEAD));
        staking.transferOwnership(newOwner);
        vm.prank(newOwner);
        IOwnable2Step(address(staking)).acceptOwnership();

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert("Ownable: caller is not the owner");
        staking.executeMigration();
        vm.prank(newOwner);
        staking.executeMigration();
        assertTrue(staking.migrated());
    }
}
