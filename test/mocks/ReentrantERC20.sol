// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @notice ERC20 that, once armed, calls back into a target during its next transfer and records the result
 */
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public callData;
    bool public armed;
    bool public attempted;
    bool public succeeded;
    bytes public returnData;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function arm(address _target, bytes calldata _callData) external {
        target = _target;
        callData = _callData;
        armed = true;
    }

    function _afterTokenTransfer(address _from, address, uint256) internal override {
        // Mints have from == address(0) and are not attack points
        if (!armed || _from == address(0)) return;
        armed = false;
        attempted = true;
        (succeeded, returnData) = target.call(callData);
    }
}
