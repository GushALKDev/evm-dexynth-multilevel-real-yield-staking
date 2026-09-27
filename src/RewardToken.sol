// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/**
 * @notice Test ERC20 used as the reward token by test/DexynthStaking.t.sol, not part of the staking system
 * @dev Mints 1,000,000,000 tokens with 18 decimals to the deployer
 */
contract RewardToken is ERC20, Ownable {
    constructor() ERC20("RewardToken Token", "RewardToken") {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }
}
