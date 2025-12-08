// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/access/Ownable.sol";

contract DEXYToken is ERC20, Ownable {
    constructor() ERC20("Dexy Token", "DEXY") {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}
