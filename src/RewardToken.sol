// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

contract RewardToken is ERC20, Ownable {
    constructor() ERC20("RewardToken Token", "RewardToken") {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}
