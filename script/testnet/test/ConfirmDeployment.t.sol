// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ConfirmDeployment} from "../ConfirmDeployment.s.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";
import {TestnetFaucet} from "../TestnetFaucet.sol";
import {DexynthStakingV2_2} from "../../../src/DexynthStaking.sol";

/**
 * @dev Writes the pending file the way a --broadcast run of DeployTestnet does
 */
contract PendingWriter is DeployTestnet {
    function writePending(string memory _json, string memory _path) external {
        vm.writeJson(_json, _path);
    }
}

/**
 * @title ConfirmDeploymentTest
 * @notice The app's deployment file is written only for contracts that exist on the chain and are set up as
 *         DeployTestnet sets them up
 * @dev Run with FOUNDRY_PROFILE=testnet. Tests run in parallel, so each one uses its own files
 */
contract ConfirmDeploymentTest is Test {
    PendingWriter internal script;
    ConfirmDeployment internal confirm;

    function setUp() public {
        vm.warp(1_800_000_000);
        script = new PendingWriter();
        script.run();
        confirm = new ConfirmDeployment();
    }

    function _paths(string memory _name) internal returns (string memory pending, string memory app) {
        pending = string.concat("cache/testnet-confirm-", _name, ".json");
        app = string.concat("app/src/config/deployments/confirm-", _name, ".json");
        _cleanUp(pending, app);
    }

    function test_WritesTheAppFileForTheRecordedDeployment() public {
        (string memory pending, string memory app) = _paths("ok");
        script.writePending(script.deploymentJson(), pending);
        confirm.confirm(pending, app);

        string memory written = vm.readFile(app);
        assertEq(vm.parseJsonAddress(written, ".staking"), _staking());
        assertEq(vm.parseJsonUint(written, ".chainId"), block.chainid);
        _cleanUp(pending, app);
    }

    /**
     * @dev What a failed broadcast leaves behind: addresses with no code
     */
    function test_RefusesAddressesWithoutCode() public {
        (string memory pending, string memory app) = _paths("no-code");
        string memory json = vm.replace(script.deploymentJson(), vm.toString(_staking()), vm.toString(address(0xDEAD)));
        script.writePending(json, pending);

        vm.expectRevert(abi.encodeWithSelector(ConfirmDeployment.NotDeployed.selector, "staking", address(0xDEAD)));
        confirm.confirm(pending, app);
        assertFalse(vm.exists(app));
        _cleanUp(pending, app);
    }

    function test_RefusesAStakingContractConfiguredOtherwise() public {
        (string memory pending, string memory app) = _paths("other-levels");
        (TestnetFaucet faucet,, address owner,) = script.deployment();
        DexynthStakingV2_2.Level[] memory levels = script.demoLevels();
        levels[0].lockingPeriod = 2 hours;
        address dexy = address(faucet.DEXY());
        address usdc = address(faucet.USDC());
        uint256 epoch = script.DEMO_EPOCH();
        vm.prank(owner);
        DexynthStakingV2_2 other = new DexynthStakingV2_2(dexy, usdc, levels, epoch);
        string memory json = vm.replace(script.deploymentJson(), vm.toString(_staking()), vm.toString(address(other)));
        script.writePending(json, pending);

        vm.expectRevert(abi.encodeWithSelector(ConfirmDeployment.Mismatch.selector, "levels"));
        confirm.confirm(pending, app);
        assertFalse(vm.exists(app));
        _cleanUp(pending, app);
    }

    function _staking() internal view returns (address) {
        (, DexynthStakingV2_2 staking,,) = script.deployment();
        return address(staking);
    }

    function _cleanUp(string memory _pending, string memory _app) internal {
        if (vm.exists(_pending)) vm.removeFile(_pending);
        if (vm.exists(_app)) vm.removeFile(_app);
    }
}
