// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @notice Minimal ERC20 with configurable decimals and an open mint, used by the tests only
 */
contract MockERC20 is ERC20 {
    uint8 private immutable DECIMALS;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        DECIMALS = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}
