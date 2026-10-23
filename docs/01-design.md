# Guide 1: Design

**Previous:** [README](../README.md)
**Next:** [Guide 2: Security](./02-security.md)

---

How `DexynthStakingV2_3` accounts for rewards, the bounds that keep that accounting exact, and the parts of the contract a user interacts with.

## Reward accounting (v2.3)

- **Epochs.** Epoch 0 starts at `I_GENESIS_EPOCH_TIMESTAMP`, a timestamp after the deployment passed to the constructor, and every epoch lasts `epochDuration` (at least one day). Epochs set when deposited rewards stream; they do not affect locks.
- **Deposits.** Anyone can call `addStakingReward(_amount)`. It transfers `_amount` in and adds `_amount * 1e36` plus `unallocatedRewards` to `queuedRewards`, the rewards of the next epoch to start (`nextEpochStart`). What is deposited during epoch N streams during epoch N + 1, and what is deposited before epoch 0 starts streams during epoch 0. A deposit never changes the rate or the end of the epoch already running, and it has no duration to choose.
- **Epoch rate.** When an epoch starts, its rate is everything queued for it divided by its length: `rewardRate = queuedRewards / epochDuration`, and the queue empties. An epoch nobody deposited for streams nothing. The pool state is written lazily, on the first update after the epoch starts, but the update streams the end of the previous epoch at the previous rate and the new epoch from its exact start.
- **Accumulator.** On every stake, unstake, harvest, deposit and migration the pool is updated: the rewards streamed since the last update are added to `accRewardPerBoostedShare` as `elapsed * rewardRate / totalBoostedStake`, moving to the next epoch first when one has started. Every deposit updates the pool before queueing, so only the epoch at `nextEpochStart` can have anything queued and an update streams at most two epochs. If `totalBoostedStake` is zero, the streamed amount goes to `unallocatedRewards` instead and is rolled into the next deposit.
- **Per user.** Each user has a `boostedBalance`, `storedRewards` and `accRewardSnapshot`. Before a user's boosted balance changes, and on harvest, the contract settles `boostedBalance * (accumulator - snapshot) / 1e36`, rounded down, into `storedRewards`. Rounding down means a user can receive less than the exact share, never more.
- **Per stake.** Each stake stores its principal, level, creation time, `unlockTime` and `boostedAmount`. `unstake` subtracts exactly the stored `boostedAmount`, so `totalBoostedStake` is always the sum of the boosted amounts of the open stakes.
- **Locks.** `unlockTime` is the stake's timestamp plus the level's `lockingPeriod`, wherever the stake falls in its epoch.
- **Cost.** `stake`, `unstake` and `harvest` do not loop over stakes, levels or epochs. `test/HarvestGasIndependence.t.sol` checks that the gas of `harvest` is identical with 1, 10, 100 and 500 stakes, after 2, 10, 52 and 100 epochs and with 1 or 5 levels touched.

### Why epochs (v2.3)

v2.2 let the owner restart the stream with any amount and duration: `addStakingReward(amount, duration)` spread the new amount plus everything not streamed yet over the new duration. Topping up 5,000 tokens over 10 days in the middle of a 100,000 token, 365 day stream paid the remaining 100,000 in 10 days too, and a zero amount over one second paid everything left at once. v2.3 was made together with the demo app, to make the contract more educational: a platform that earns rewards over time deposits them as they come, and each deposit is paid out over one epoch without touching the others. With epochs as long as the deposit interval, every epoch pays what the previous one collected, so the payout is regular even when deposits are not. The cost is a delay: a deposit waits for the next epoch to start, up to one full epoch.

### Changes for users from v2.2 to v2.3

- `addStakingReward(_amount)` has no duration and anyone can call it. A deposit streams over the next epoch to start; it cannot reschedule what is already streaming. A zero amount reverts with `WrongParams`.
- The constructor takes the start of epoch 0 (`_firstEpochStart`), which must be after the deployment (`StartNotInFuture`). What is deposited before it streams during epoch 0.
- The lock counts from the stake: `unlockTime` is the stake's timestamp plus the level's `lockingPeriod`, no longer rounded up to the next epoch start.
- `rewardEndTime` is replaced by `nextEpochStart` and `queuedRewards` is new. `getCurrentEpochIndex()` reverts with `EpochsNotStarted` before epoch 0 starts.
- `RewardAdded(funder, epoch, amount)` replaces `RewardAdded(amount, duration, rewardRate)`. `ZeroDuration` is removed.
- Migration also moves the queued rewards. The owner's only remaining power over rewards is the migration.
- The contract is renamed `DexynthStakingV2_3`.

### Changes for users from v2.1 to v2.2

- Rewards accrue and can be claimed from the block of the stake. In v2.1 they also accrued from the stake, but could only be claimed from the start of the next epoch (`rewardStartTime`, now removed).
- `unstake` pays all the caller's accrued rewards, not only the rewards of the withdrawn stake.
- `addStakingReward` is owner only.
- A stake whose boosted amount rounds down to zero reverts (`ZeroBoostedStake`). With the example configuration the minimum is 2 wei at 0.65x.
- `unstake` on an index the caller never used reverts (`StakeNotFound`).
- Migration only moves the rewards that are not streamed yet. After it, `stake` and `addStakingReward` revert and `unstake` ignores the lock.
- The rewards funded over the life of the contract are capped at `MAX_TOTAL_FUNDING`, and at most `MAX_LEVELS = 10` levels are accepted.
- Ownership changes take two steps (`transferOwnership` then `acceptOwnership`) and `renounceOwnership` reverts.
- Events: `DEXYStaked` and `DEXYUnstaked` carry the stake index and the level, indexed together with the user. `RewardAdded(amount, duration, rewardRate)` is new. `DEXYMigrationSuccess` is removed (DEXY is never migrated).
- The contract is renamed `DexynthStakingV2_2`. The `users` and `stakeInfo` getters return the new struct fields.

## Precision and bounds

- `PRECISION = 1e36` scales `rewardRate`, `queuedRewards`, `unallocatedRewards` and `accRewardPerBoostedShare`. Each pool update truncates the accumulator by less than `totalBoostedStake / 1e36` reward units, and the rate truncation loses less than `epochDuration / 1e36` units per epoch. With a 6-decimal reward token, pool updates every 12 seconds over one day of a 1,000 token, 15 day epoch pay exactly the expected 66,666,666 units (`test/regression/RewardPrecision.t.sol`).
- `MAX_TOTAL_FUNDING = type(uint128).max` reward units (about 3.4e20 tokens with 18 decimals, 3.4e32 with 6). Funding above it reverts with `FundingCapExceeded`. Every reward amount the contract holds, streams or owes is then below 2^128, which the `uint128` per-user fields need.
- The smallest boosted stake is 1 unit, so over the life of the contract the accumulator stays below `MAX_TOTAL_FUNDING * 1e36`, about 3.4e74, far from `type(uint256).max` (about 1.16e77).
- A stake's amount and its boosted amount must each fit in `uint128`, otherwise `stake` reverts.

`test/Bounds.t.sol` covers these limits: the maximum funding streamed in full, the minimum boosted stake alone with the maximum funding, the maximum stake amount, and the reverts one unit above the funding cap, the stake amount limit and the boosted amount limit.

## Staking levels

Levels are passed to the constructor as a `Level[]` array and cannot be changed afterwards. The constructor enforces:

- between 1 and `MAX_LEVELS = 10` levels;
- `lockingPeriod` strictly increasing from one level to the next;
- `boostP` strictly increasing from one level to the next;
- the sum of all `boostP` values equals `numberOfLevels * 1e10`, so the average multiplier is 1.0x (`boostP = 1e10` means 1.0x).

The `totalStaked` field of the argument is ignored and every level starts at zero. No other bounds are checked: level 0 may have a `lockingPeriod` of 0, and a level with `boostP = 0` would reject every stake with `ZeroBoostedStake`.

**Example configuration.** This is the configuration used by the tests and by [script/DeployDexynthStaking.s.sol](../script/DeployDexynthStaking.s.sol), with a 15 day epoch (`1296000` seconds). It is an example, not a property of the contract: epochs work best as long as the interval between deposits.

| Level | `lockingPeriod` (s) | Lock | `boostP` | Multiplier |
|-------|---------------------|----------|-------------|------------|
| 0 | 2592000 | 30 days | 6500000000 | 0.65x |
| 1 | 7776000 | 90 days | 8500000000 | 0.85x |
| 2 | 15552000 | 180 days | 10000000000 | 1.00x |
| 3 | 31536000 | 365 days | 11500000000 | 1.15x |
| 4 | 62208000 | 720 days | 13500000000 | 1.35x |

## Tokens

- `DEXY` and `REWARD_TOKEN` are immutable addresses set at deployment and must be different. The deploy script reads them from the `DEXY_ADDRESS` and `REWARD_TOKEN_ADDRESS` environment variables, and the start of epoch 0 from `FIRST_EPOCH_START`.
- All six token calls go through OpenZeppelin `SafeERC20`. The contract never reads `decimals()` or `balanceOf`; the invariant suites run with an 18-decimal and a 6-decimal reward token.
- Fee-on-transfer and rebasing tokens are not supported: the contract records the amount requested, not the amount received. `test/FeeOnTransfer.t.sol` shows that with a 1% fee DEXY the last unstake reverts, and with a 1% fee reward token the epoch promises more than the balance and harvest reverts.

## Core functions

```solidity
function stake(uint256 _amount, uint8 _level) external;
function unstake(uint64 _stakeIndex) external;
function harvest() external;
function pendingRewards(address _user) external view returns (uint256);

// Anyone
function addStakingReward(uint256 _amount) external;

// Owner only
function requestMigration(address _newContract) external;
function cancelMigration() external;
function executeMigration() external;
```

- `stake`: `_amount` in DEXY units, `_level` from 0 to `getNumberOfLevels() - 1`. Every call creates a new stake with its own index.
- `unstake`: withdraws one stake and pays all the caller's accrued rewards. Reverts while the stake is locked, unless the contract has been migrated.
- `harvest`: pays all the caller's accrued rewards. Reverts if the caller has nothing staked or nothing to claim.
- `addStakingReward`: deposits `_amount` of `REWARD_TOKEN` for the next epoch to start, from any account. Reverts with `WrongParams` on zero and with `AlreadyMigrated` after a migration.
- Views: `getLevels()`, `getNumberOfLevels()`, `getCurrentEpochIndex()` (reverts before epoch 0 starts), `pendingRewards(address)`, and the epoch state `nextEpochStart()`, `rewardRate()` and `queuedRewards()`, as of the last pool update.

## Migration

- `requestMigration(address)` stores a destination and starts a 30 day delay (`MIGRATION_DELAY`). Only one request can be live.
- `executeMigration()` can run from 30 days to 37 days after the request (`MIGRATION_WINDOW = 7 days`). After that the request has expired, execution reverts with `MigrationExpired` and a new request can be made.
- `executeMigration()` updates the pool, stops the stream and transfers only the rewards that are not streamed yet: the rest of the current epoch, the queued deposits and `unallocatedRewards`. Staked DEXY and the rewards already accrued to stakers stay in the contract.
- After a migration, `stake`, `addStakingReward` and `requestMigration` revert with `AlreadyMigrated`, `unstake` ignores the lock, and accrued rewards can still be harvested.
- `cancelMigration()` clears a pending request. A pending request survives an ownership change and the new owner can execute it.

## Original design model (Excel)

The original Dexynth design was modelled in a spreadsheet before it was implemented. The spreadsheet models the original epoch-based reward logic: the rewards of each epoch are split across levels by boosted stake, with a per-user breakdown for three users.

The spreadsheet file is not part of this repository (it is listed in `.gitignore`). No test compares contract results against spreadsheet values. Since v2.2 rewards stream per second instead of being split per closed epoch, and v2.3 only uses epochs to schedule deposits: the spreadsheet describes the v1 distribution. `test/differential/V1Shares.t.sol` checks that v1 and v2.3 split rewards between users in the same proportions.

![Excel model 1](../images/staking_excel_1.png)

![Excel model 2](../images/staking_excel_2.png)

![Excel model 3](../images/staking_excel_3.png)
