// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/access/Ownable.sol";

contract USDTToken is ERC20, Ownable {
    constructor() ERC20("USDT Token", "USDT") {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}
