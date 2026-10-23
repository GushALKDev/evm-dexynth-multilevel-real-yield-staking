// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/**
 * @title TestnetToken
 * @notice Testnet stand-in for DEXY or for the reward token, mintable only by the faucet that deployed it.
 *         It has no value and is not the real DEXY
 */
contract TestnetToken is ERC20 {
    /**
     * @notice The caller is not the faucet
     */
    error OnlyMinter(address caller);

    /**
     * @notice The faucet, the only account that can mint
     */
    address public immutable MINTER;

    uint8 private immutable DECIMALS;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        MINTER = msg.sender;
        DECIMALS = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Mints new tokens. Faucet only
     */
    function mint(address _to, uint256 _amount) external {
        if (msg.sender != MINTER) revert OnlyMinter(msg.sender);
        _mint(_to, _amount);
    }
}

/**
 * @dev The staking functions the faucet calls to seed the demo pool and to fund its rewards
 */
interface IStakingTarget {
    function DEXY() external view returns (address);
    function REWARD_TOKEN() external view returns (address);
    function stake(uint256 _amount, uint8 _level) external;
    function addStakingReward(uint256 _amount) external;
}

/**
 * @title TestnetFaucet
 * @notice Deploys the two testnet tokens of the demo, DEXY (18 decimals) and USDC (6 decimals, the reward token),
 *         and hands out DEXY_DRIP DEXY and USDC_DRIP USDC once a day per address, so a visitor can stake and also
 *         deposit rewards. The feeder, the demo's scheduled depositor, funds the reward stream through fundRewards.
 *         Testnet only
 * @dev What it checks: one claim per address per COOLDOWN, claims only from externally owned accounts (so one
 *      transaction cannot claim through many fresh contracts), only the feeder can fund rewards, and only the owner
 *      can mint freely, seed stakes or replace the feeder. What it does not check: the limit is per account, so
 *      someone funding many accounts can claim many times. Smart contract wallets cannot claim. Stakes made through
 *      seedStake belong to this contract, which has no function to unstake or harvest them, so the seeded DEXY stays
 *      staked for good and the rewards it earns stay in the staking contract
 */
contract TestnetFaucet is Ownable {
    /**
     * @notice The caller claimed less than COOLDOWN ago
     */
    error ClaimTooSoon(address account, uint256 nextClaimAt);

    /**
     * @notice The caller is a contract: claims come straight from an externally owned account
     */
    error ClaimFromContract(address caller);

    /**
     * @notice The token is not one of the two this faucet deployed
     */
    error UnknownToken(address token);

    /**
     * @notice The staking contract does not stake this faucet's DEXY
     */
    error WrongStakingToken(address staking);

    /**
     * @notice The staking contract does not pay this faucet's USDC as rewards
     */
    error WrongRewardToken(address staking);

    /**
     * @notice The caller is not the feeder
     */
    error OnlyFeeder(address caller);

    /**
     * @notice Emitted on every claim
     */
    event Claimed(address indexed account);

    /**
     * @notice Emitted when the feeder is set, at deployment and on every change
     */
    event FeederSet(address indexed feeder);

    /**
     * @notice Emitted when the feeder funds the reward stream
     */
    event RewardsFunded(address indexed staking, uint256 amount);

    /**
     * @notice Minimum time between two claims from the same address
     */
    uint256 public constant COOLDOWN = 1 days;

    /**
     * @notice DEXY handed out per claim
     */
    uint256 public constant DEXY_DRIP = 10_000e18;

    /**
     * @notice USDC handed out per claim, enough for a visitor to deposit rewards and watch the next epoch's rate rise
     */
    uint256 public constant USDC_DRIP = 500e6;

    /**
     * @notice Testnet stand-in for DEXY, the staked token
     */
    TestnetToken public immutable DEXY;

    /**
     * @notice Testnet stand-in for USDC, the reward token
     */
    TestnetToken public immutable USDC;

    // Slot 0 is Ownable._owner
    /**
     * @notice Account allowed to call fundRewards, the demo's scheduled depositor
     */
    address public feeder; //     20 bytes -┐  Slot 1 (25/32)
    /**
     * @notice Timestamp of the last fundRewards call, so the depositor can tell whether it already funded today
     */
    uint40 public lastFundedAt; // 5 bytes -┘

    /**
     * @notice Timestamp of each address's last claim
     */
    mapping(address account => uint256 timestamp) public lastClaim;

    constructor(address _owner, address _feeder) {
        DEXY = new TestnetToken("Testnet DEXY", "DEXY", 18);
        USDC = new TestnetToken("Testnet USD Coin", "USDC", 6);
        _transferOwnership(_owner);
        feeder = _feeder;
        emit FeederSet(_feeder);
    }

    /**
     * @notice Sends DEXY_DRIP DEXY and USDC_DRIP USDC to the caller, at most once per COOLDOWN, if the caller is not a
     *         contract
     */
    function claim() external {
        // One claim needs one funded account: a contract could otherwise claim from many fresh addresses at once
        if (msg.sender != tx.origin) revert ClaimFromContract(msg.sender);
        uint256 next = nextClaimAt(msg.sender);
        if (block.timestamp < next) revert ClaimTooSoon(msg.sender, next);
        lastClaim[msg.sender] = block.timestamp;

        DEXY.mint(msg.sender, DEXY_DRIP);
        USDC.mint(msg.sender, USDC_DRIP);

        emit Claimed(msg.sender);
    }

    /**
     * @notice Mints _amount USDC to this contract and deposits it as rewards in _staking, streamed over its next epoch.
     *         Feeder only
     */
    function fundRewards(address _staking, uint256 _amount) external {
        if (msg.sender != feeder) revert OnlyFeeder(msg.sender);
        if (IStakingTarget(_staking).REWARD_TOKEN() != address(USDC)) revert WrongRewardToken(_staking);
        lastFundedAt = uint40(block.timestamp);

        USDC.mint(address(this), _amount);
        USDC.approve(_staking, _amount);
        IStakingTarget(_staking).addStakingReward(_amount);

        emit RewardsFunded(_staking, _amount);
    }

    /**
     * @notice Replaces the feeder, for instance when its key is rotated. Owner only
     */
    function setFeeder(address _feeder) external onlyOwner {
        feeder = _feeder;
        emit FeederSet(_feeder);
    }

    /**
     * @notice Mints any amount of one of the two tokens. Owner only, used to fund the reward stream
     */
    function mint(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_token != address(DEXY) && _token != address(USDC)) revert UnknownToken(_token);
        TestnetToken(_token).mint(_to, _amount);
    }

    /**
     * @notice Mints DEXY to this contract and stakes it in _level of _staking. Owner only, used to seed the pool
     * @dev The stake belongs to this contract, which cannot unstake it
     */
    function seedStake(address _staking, uint8 _level, uint256 _amount) external onlyOwner {
        if (IStakingTarget(_staking).DEXY() != address(DEXY)) revert WrongStakingToken(_staking);
        DEXY.mint(address(this), _amount);
        DEXY.approve(_staking, _amount);
        IStakingTarget(_staking).stake(_amount, _level);
    }

    /**
     * @notice Earliest timestamp at which an address can claim again, 0 if it never claimed
     */
    function nextClaimAt(address _account) public view returns (uint256) {
        uint256 last = lastClaim[_account];
        return last == 0 ? 0 : last + COOLDOWN;
    }
}
