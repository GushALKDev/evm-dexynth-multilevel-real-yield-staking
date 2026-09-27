// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @notice ERC20 that burns 1% of every transfer, so the receiver gets 99% of the amount sent
 */
contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 100;

    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function _transfer(address _from, address _to, uint256 _amount) internal override {
        uint256 fee = _amount * FEE_BPS / 10_000;
        _burn(_from, fee);
        super._transfer(_from, _to, _amount - fee);
    }
}
