# Dexynth Multilevel Real Yield Staking

Original contract written at Dexynth (2023-2024). v2, v2.1 and v2.2 are a later independent rework (Dec 2025 - Sep 2026) that replaces the loop-based reward logic with reward accumulators (per level in v2 and v2.1, one accumulator per boosted unit in v2.2).

**Status:** Proof of concept. Not audited. Not deployed.

## Overview

`DexynthStakingV2_2` ([src/DexynthStaking.sol](./src/DexynthStaking.sol)) lets users stake DEXY in one of several lock levels and earn a reward token (`REWARD_TOKEN`, fixed at deployment) that the owner funds and the contract streams every second. Each level has a lock period and a reward multiplier. A stake's weight is its boosted amount, `amount * boostP / 1e10`, and every boosted unit earns the same reward per second.

## Reward accounting (v2.2)

- **Funding.** `addStakingReward(_amount, _duration)` is owner only. It transfers `_amount` in and sets `rewardRate = (unstreamed part of the current stream + unallocatedRewards + _amount * 1e36) / _duration` and `rewardEndTime = now + _duration`. With `_amount = 0` it only reschedules what is left.
- **Accumulator.** On every stake, unstake, harvest, funding and migration the pool is updated: the rewards streamed since the last update are added to `accRewardPerBoostedShare` as `elapsed * rewardRate / totalBoostedStake`. If `totalBoostedStake` is zero, the streamed amount goes to `unallocatedRewards` instead and is rolled into the next funding.
- **Per user.** Each user has a `boostedBalance`, `storedRewards` and `accRewardSnapshot`. Before a user's boosted balance changes, and on harvest, the contract settles `boostedBalance * (accumulator - snapshot) / 1e36`, rounded down, into `storedRewards`. Rounding down means a user can receive less than the exact share, never more.
- **Per stake.** Each stake stores its principal, level, creation time, `unlockTime` and `boostedAmount`. `unstake` subtracts exactly the stored `boostedAmount`, so `totalBoostedStake` is always the sum of the boosted amounts of the open stakes.
- **Cost.** `stake`, `unstake` and `harvest` do not loop over stakes, levels or epochs. `test/HarvestGasIndependence.t.sol` checks that the gas of `harvest` is identical with 1, 10, 100 and 500 stakes, after 1, 10, 52 and 100 epochs and with 1 or 5 levels touched.
- **Epochs.** `epochDuration` (at least one day) is only used for the lock: `unlockTime` is the start of the next epoch after staking plus the level's `lockingPeriod`. Rewards do not depend on epochs.

### Changes for users from v2.1 to v2.2

- Rewards accrue and can be claimed from the block of the stake. In v2.1 they also accrued from the stake, but could only be claimed from the start of the next epoch (`rewardStartTime`, now removed).
- `unstake` pays all the caller's accrued rewards, not only the rewards of the withdrawn stake.
- `addStakingReward` is owner only.
- A stake whose boosted amount rounds down to zero reverts (`ZeroBoostedStake`). With the example configuration the minimum is 2 wei at 0.65x.
- `unstake` on an index the caller never used reverts (`StakeNotFound`).
- Migration only moves the rewards that are not streamed yet. After it, `stake` and `addStakingReward` revert and `unstake` ignores the lock.
- The rewards funded over the life of the contract are capped at `MAX_TOTAL_FUNDING`, and at most `MAX_LEVELS = 10` levels are accepted.
- Events: `RewardAdded(amount, duration, rewardRate)` is new, `DEXYMigrationSuccess` is removed (DEXY is never migrated).
- The contract is renamed `DexynthStakingV2_2`. The `users` and `stakeInfo` getters return the new struct fields.

## Precision and bounds

- `PRECISION = 1e36` scales `rewardRate`, `unallocatedRewards` and `accRewardPerBoostedShare`. Each pool update truncates the accumulator by less than `totalBoostedStake / 1e36` reward units, and the rate truncation loses less than `_duration / 1e36` units per funding. With a 6-decimal reward token, pool updates every 12 seconds over one day pay exactly the expected 33,333,333 units (`test/regression/RewardPrecision.t.sol`).
- `MAX_TOTAL_FUNDING = type(uint128).max` reward units (about 3.4e20 tokens with 18 decimals, 3.4e32 with 6). Funding above it reverts with `FundingCapExceeded`. Every reward amount the contract holds, streams or owes is then below 2^128, which the `uint128` per-user fields need.
- The smallest boosted stake is 1 unit, so over the life of the contract the accumulator stays below `MAX_TOTAL_FUNDING * 1e36`, about 3.4e74, far from `type(uint256).max` (about 1.16e77).
- A stake's amount and its boosted amount must each fit in `uint128`, otherwise `stake` reverts.

`test/Bounds.t.sol` covers these limits: the maximum funding streamed in full, the minimum boosted stake alone with the maximum funding, the maximum stake amount, and the reverts just above each limit.

```bash
forge test --match-path test/Bounds.t.sol
```

## Staking levels

Levels are passed to the constructor as a `Level[]` array and cannot be changed afterwards. The constructor enforces:

- between 1 and `MAX_LEVELS = 10` levels;
- `lockingPeriod` strictly increasing from one level to the next;
- `boostP` strictly increasing from one level to the next;
- the sum of all `boostP` values equals `numberOfLevels * 1e10`, so the average multiplier is 1.0x (`boostP = 1e10` means 1.0x).

The `totalStaked` field of the argument is ignored and every level starts at zero. No other bounds are checked: level 0 may have a `lockingPeriod` of 0, and a level with `boostP = 0` would reject every stake with `ZeroBoostedStake`.

**Example configuration.** This is the configuration used by the tests and by [script/DeployDexynthStaking.s.sol](./script/DeployDexynthStaking.s.sol), with a 15 day epoch (`1296000` seconds). It is an example, not a property of the contract.

| Level | `lockingPeriod` (s) | Lock | `boostP` | Multiplier |
|-------|---------------------|----------|-------------|------------|
| 0 | 2592000 | 30 days | 6500000000 | 0.65x |
| 1 | 7776000 | 90 days | 8500000000 | 0.85x |
| 2 | 15552000 | 180 days | 10000000000 | 1.00x |
| 3 | 31536000 | 365 days | 11500000000 | 1.15x |
| 4 | 62208000 | 720 days | 13500000000 | 1.35x |

## Tokens

- `DEXY` and `REWARD_TOKEN` are immutable addresses set at deployment and must be different. The deploy script reads them from the `DEXY_ADDRESS` and `REWARD_TOKEN_ADDRESS` environment variables.
- The contract never reads `decimals()`. The invariant suite runs with an 18-decimal and a 6-decimal reward token.
- Tokens are expected to transfer exactly the requested amount. Fee-on-transfer and rebasing tokens are not supported.

## Core functions

```solidity
function stake(uint256 _amount, uint8 _level) external;
function unstake(uint64 _stakeIndex) external;
function harvest() external;
function pendingRewards(address _user) external view returns (uint256);

// Owner only
function addStakingReward(uint256 _amount, uint256 _duration) external;
function requestMigration(address _newContract) external;
function cancelMigration() external;
function executeMigration() external;
```

- `stake`: `_amount` in DEXY units, `_level` from 0 to `getNumberOfLevels() - 1`. Every call creates a new stake with its own index.
- `unstake`: withdraws one stake and pays all the caller's accrued rewards. Reverts while the stake is locked, unless the contract has been migrated.
- `harvest`: pays all the caller's accrued rewards. Reverts if the caller has nothing staked or nothing to claim.
- Views: `getLevels()`, `getNumberOfLevels()`, `getCurrentEpochIndex()`, `pendingRewards(address)`.

## Migration

- `requestMigration(address)` stores a destination and starts a 30 day delay (`MIGRATION_DELAY`). Only one request can be live.
- `executeMigration()` can run from 30 days to 37 days after the request (`MIGRATION_WINDOW = 7 days`). After that the request has expired, execution reverts with `MigrationExpired` and a new request can be made.
- `executeMigration()` updates the pool, stops the stream and transfers only the rewards that are not streamed yet plus `unallocatedRewards`. Staked DEXY and the rewards already accrued to stakers stay in the contract.
- After a migration, `stake`, `addStakingReward` and `requestMigration` revert with `AlreadyMigrated`, `unstake` ignores the lock, and accrued rewards can still be harvested.
- `cancelMigration()` clears a pending request.

## Trust assumptions and limitations

### Owner powers

The owner is the deployer (OpenZeppelin `Ownable` v4.9.3, single-step `transferOwnership` and `renounceOwnership`).

| Function | What it can do to user funds or rewards |
|----------|------------------------------------------|
| `addStakingReward(amount, duration)` | Funds the stream and restarts it. With `amount = 0` it can stretch the remaining rewards over a very long duration (slowing the stream to almost nothing) or compress them into one second (paying them to the current stakers at once). |
| `requestMigration(address)` | Stores a destination and starts the 30 day delay. Nothing moves yet. |
| `cancelMigration()` | Clears the pending request. |
| `executeMigration()` | Within the 7 day window after the delay, moves the rewards that are not streamed yet and the unallocated rewards to the destination, and stops the stream for good. It cannot move staked DEXY or rewards already accrued to stakers. |
| `transferOwnership(address)` | Hands all of the above to another address. |
| `renounceOwnership()` | Removes the owner: no more funding and no migration. |

There is no pause and no emergency withdrawal. After a migration users can withdraw their principal at any time.

### Other limitations

- Rewards streamed while nobody is staked are kept in `unallocatedRewards` and only reach stakers after the owner calls `addStakingReward` again (or leave with a migration).
- Rounding always favours the contract. The dust that no user can claim stays in the contract.
- `harvest` reverts for a user with no open stake. Nothing is lost: `unstake` pays all accrued rewards when the last stake is withdrawn.

## Setup

Dependencies are git submodules pinned to release tags (forge-std v1.12.0, OpenZeppelin v4.9.3, also recorded in `foundry.lock`).

```bash
git clone --recursive https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking.git
cd evm-dexynth-multilevel-real-yield-staking
forge build
```

## Testing

```bash
# Unit, regression, bounds, reentrancy, differential and invariant tests
forge test

# Invariant suites only
forge test --match-path test/invariant/Invariant.t.sol

# Coverage of src/ (bench/, test/ and script/ excluded)
forge coverage --no-match-coverage "(bench|test|script)"
```

`forge test` runs 101 tests. Fuzz tests use Foundry's default of 256 runs.

| File | Tests | What they check |
|------|-------|-----------------|
| `test/DexynthStaking.t.sol` | 35 | Stake, unstake, harvest, epochs, migration basics and fuzz tests, with exact expected amounts |
| `test/Validation.t.sol` | 14 | Every constructor and parameter check |
| `test/regression/*.t.sol` | 26 | One file per review finding (see Review notes) |
| `test/Bounds.t.sol` | 7 | Precision and overflow bounds |
| `test/Reentrancy.t.sol` | 5 | A token that reenters stake, unstake, harvest, addStakingReward and executeMigration hits the guard |
| `test/HarvestGasIndependence.t.sol` | 3 | Identical harvest gas across stake counts, epochs and levels touched |
| `test/differential/V1Shares.t.sol` | 1 | v1 and v2.2 split rewards by boosted stake in the same way (absolute payouts are not comparable, see the test) |
| `test/invariant/Invariant.t.sol` | 10 | 5 invariants, run with an 18-decimal and a 6-decimal reward token |

Reward checks compare against the exact rational value: a payout may be below it by a stated number of wei, justified in each test, and never above it.

`forge coverage --no-match-coverage "(bench|test|script)"` reports for `src/DexynthStaking.sol`: 100% lines (159/159), 99.03% statements (204/206), 100% branches (38/38) and 100% functions (17/17). The two statements reported as uncovered are the constant expression `MIGRATION_DELAY + MIGRATION_WINDOW`, which the compiler folds.

### Invariant tests

Settings in `foundry.toml`: `runs = 256`, `depth = 64`, `fail_on_revert = true`. The handler asserts every revert the contract should raise with `vm.expectRevert`, so any other revert fails the run. Calls that have nothing to do in the current state are discarded with `vm.assume`.

The handler has 10 actors and 11 actions: stake (small and regular amounts), unstake (warping to the unlock time if needed), harvest, owner funding (small and regular amounts), non-owner funding (must revert), migration request, cancel, execute and expiry, and two time warps. After a migration, stake and funding must revert. Effective calls per action are appended to `cache/invariant-stats-18.txt` and `cache/invariant-stats-6.txt` at the end of each run.

| Invariant | What it checks |
|-----------|----------------|
| `invariant_dexyBalanceCoversPrincipal` | The DEXY balance equals the principal of the open stakes read from `stakeInfo`, and the level totals add up to the same value. |
| `invariant_rewardBalanceCoversLiabilities` | The reward balance is at least the sum of `pendingRewards` of every actor plus the unstreamed and unallocated rewards, rounded up. No tolerance. |
| `invariant_rewardConservation` | Rewards added equal rewards paid to actors plus rewards migrated plus rewards held, exactly, and equal `totalRewardsFunded`. |
| `invariant_boostedAndUserAccounting` | `totalBoostedStake` equals the boosted amounts of the open stakes and the sum of the users' boosted balances. Each user's totals match their open stakes. |
| `invariant_migrationStopsStream` | After a migration the rate and unallocated rewards stay at zero and no request is pending. |

With these settings both suites found no violations in 256 runs of depth 64 for each invariant.

## Gas

Gas benchmarks live in `gas/` and run in their own profile. They compare the original v1 contract (a frozen copy in `bench/`, used only for benchmarks) with v2.2 under the same named scenarios and write the results to `snapshots/v1.json` and `snapshots/v2_2.json`.

```bash
FOUNDRY_PROFILE=gas forge test
cat snapshots/v1.json snapshots/v2_2.json
```

Figures are the gas of the measured call, without the 21,000 intrinsic transaction gas. Common setup: 15 day epochs, the example multipliers and locks except that level 0 has no lock (so unstake can be measured one epoch after staking), bob staked 1000 DEXY at level 2 and 1,000,000 reward tokens added. "After N epochs" means the call happens N + 1 epochs and 1 hour after alice's stake, which gives both versions N rewarded epochs. Every call is 1 hour into an epoch because v1 reverts in the first seconds of an epoch (see Review notes).

| Scenario | v1 | v2.2 |
|----------|---:|-----:|
| `stake_first`: alice's first stake, 1000 DEXY at level 0 | 229,963 | 156,223 |
| `stake_subsequent`: alice's second stake in the same block | 122,263 | 78,723 |
| `harvest_after_1_epoch` | 555,402 | 123,097 |
| `harvest_after_10_epochs` | 2,546,841 | 123,097 |
| `harvest_after_52_epochs` | 11,840,223 | 123,097 |
| `harvest_after_100_epochs` | 22,461,231 | 123,097 |
| `unstake_after_1_epoch` (level 0 stake, rewards included) | 605,074 | 142,193 |
| `unstake_after_10_epochs` | 2,596,513 | 142,193 |
| `unstake_after_52_epochs` | 11,889,895 | 142,193 |
| `unstake_after_100_epochs` | 22,510,903 | 142,193 |
| `harvest_with_1_stake`: 100 DEXY stakes at level 0, after 1 rewarded epoch | 555,402 | 123,097 |
| `harvest_with_10_stakes` | 555,402 | 123,097 |
| `harvest_with_100_stakes` | 555,402 | 123,097 |
| `harvest_with_500_stakes` | 555,402 | 123,097 |
| `harvest_levels_touched_1`: 100 DEXY in 1 level, after 1 rewarded epoch | 555,402 | 123,097 |
| `harvest_levels_touched_5`: 100 DEXY in each of the 5 levels | 678,702 | 123,097 |

In v1, `harvest` and `unstake` loop over every level for every epoch since the user's last harvest, and close any pending epochs first. v1 does not loop over stakes. v2.2 does not loop over stakes, levels or epochs.

## Security measures

- **Reentrancy:** OpenZeppelin `ReentrancyGuard` on every function that transfers tokens. `test/Reentrancy.t.sol` reenters each of them through a token callback.
- **Checks-Effects-Interactions:** state is updated before every token transfer.
- **Token transfers:** OpenZeppelin `SafeERC20`.
- **Casts:** OpenZeppelin `SafeCast` for every narrowing conversion, except three commented casts that are bounded by a previous check.
- **Access control:** OpenZeppelin `Ownable` on funding and migration.

## Review notes

One entry per finding of the round 1 review and of this round. The tests of each finding were run against the code before its fix, and the ones that encode the fixed behaviour failed there.

### Permissionless `addStakingReward`

- **Cause.** The function had no access control, so anyone could reschedule the remaining stream for free, stretching it or compressing it into one second.
- **Fix.** `onlyOwner`.
- **Test.** `test/regression/AddRewardAccess.t.sol` (stretch and compress attempts by a non-owner revert), plus the handler's non-owner funding action.
- **Commit.** `9f44894`.

### Precision loss with low-decimal reward tokens

- **Cause.** `rewardRate` was truncated to whole units per second and the per-level accumulator had 1e18 precision per DEXY. With 6 decimals and 10M DEXY in a level, pool updates every 12 seconds rounded the accumulator increment to zero.
- **Fix.** `rewardRate` and the accumulator are scaled by 1e36, products use `Math.mulDiv`, and the funding cap bounds every value (see Precision and bounds).
- **Test.** `test/regression/RewardPrecision.t.sol`, `test/Bounds.t.sol`, and the invariant suite with a 6-decimal token.
- **Commits.** `be001bc`, cap in `d02eb37`.

### Rewards streamed with no stakers

- **Cause.** When `totalBoostedStake` was zero the pool skipped the elapsed time, and those rewards stayed in the contract with no claimant. A 1 wei stake at 0.65x had a boosted amount of zero and caused the same.
- **Fix.** The skipped amount goes to `unallocatedRewards` and is rolled into the next funding; stakes with a zero boosted amount revert.
- **Test.** `test/regression/UnallocatedRewards.t.sol`.
- **Commit.** `668897a`.

### Migration could move locked principal and requests never expired

- **Cause.** `executeMigration` transferred the whole DEXY and reward balances, including locked principal and accrued rewards, and a request stayed executable forever.
- **Fix.** Migration moves only unstreamed and unallocated rewards, stops the stream, expires 7 days after the delay, and unlocks principal afterwards.
- **Test.** `test/regression/Migration.t.sol`, plus the handler's migration actions and `invariant_migrationStopsStream`.
- **Commit.** `6997f6d`.

### Rewards accrued before `rewardStartTime`

- **Cause.** v2.1 documented `rewardStartTime` as the start of accrual, but stakes accrued from creation and the field only delayed claiming.
- **Fix.** `rewardStartTime` is removed. Rewards accrue and are claimable from the stake's block; the next epoch start only anchors `unlockTime`.
- **Test.** `testRewardsAccrueFromStakeTime` in `test/DexynthStaking.t.sol`.
- **Commit.** `d02eb37`.

### `harvest` cost grew with the number of stakes

- **Cause.** v2.1 settled rewards per stake, so `harvest` looped over every stake the user had ever created. Against v2.1 the regression test measured 391,631 gas with 10 stakes against 165,470 with one.
- **Fix.** Per-user accounting with one accumulator per boosted unit (v2.2).
- **Test.** `test/HarvestGasIndependence.t.sol`.
- **Commit.** `d02eb37`.

### Small findings

- `unstake` on a never used index succeeded and emitted an event with amount 0. It now reverts with `StakeNotFound`. Test in `test/regression/InfoFindings.t.sol`, commit `73a24ed`.
- The constructor accepted `DEXY == REWARD_TOKEN`. It now reverts with `SameToken`. Commit `046e2d7`.
- The number of levels had no cap and the constructor loop used a `uint8` counter. The cap is `MAX_LEVELS = 10` and the counter is `uint256`. Commit `42dec44`.
- `migrationRequestTime` was a `uint32`, truncated from February 2106. It is now `uint40`. Commit `d0c2395`.

### Constructor copied `Level.totalStaked`

- **Cause.** Found in round 2. The constructor stored the `totalStaked` value it received, so a non-zero value created stake that nobody owned. With 1000 DEXY of such stake in level 0 and one real staker of 1000 DEXY, the staker received 5,000 of 10,000 funded tokens.
- **Fix.** Levels are stored with `totalStaked = 0`.
- **Test.** `test/regression/ConstructorLevels.t.sol`.
- **Commit.** `45458c5`.

### v2.1 rounding fix in `totalBoostedStake`

- **Cause.** In v2, `stake` and `unstake` updated `totalBoostedStake` with per-stake rounded values, while the reward split used per-level rounded values, so the two drifted apart by a few wei.
- **Fix.** v2.1 (`d39e101`) recomputed the total from the level totals. v2.2 makes it structural: each stake stores its `boostedAmount`, `unstake` subtracts exactly that value, and the reward split uses the same total.
- **Test.** `invariant_boostedAndUserAccounting` checks that `totalBoostedStake` equals the sum of the open stakes' boosted amounts after every handler call.

### v1 epoch timestamp drift (not fixed, frozen benchmark copy)

The original v1 computes epoch start times with `(epochDuration + 1) * index`, one second per epoch more than the index calculation, and `checkForClosingEpochs` underflows in the first L + 1 seconds of an epoch once L epochs are closed. The rework fixed it in `14b8f8f`. The copy in `bench/` keeps the original code, so the gas benchmarks measure every call 1 hour into an epoch.

## Changelog

### v2.2 (Sep 2026)

Fixes for the round 1 review findings, per-user reward accounting with one accumulator per boosted unit, migration redesign, precision and funding bounds, a rewritten test suite (exact expectations, solvency and conservation invariants, reentrancy and bounds tests), a gas harness against v1, dependencies as pinned submodules and an MIT license. See Review notes and the changes for users above.

### v2.1 (Jan 2026): internal review

- Added a stateful fuzzing suite based on a `Handler` contract.
- `totalBoostedStake` recomputed from the level totals on every stake and unstake.
- `stake`, `unstake`, `addStakingReward` and `executeMigration` update state before any token transfer, and `executeMigration` got `nonReentrant`.
- `ACC_PRECISION` and `BOOST_PRECISION` constants, indexed migration event addresses, cached loop lengths.

### v2 (Dec 2025): accumulator and cleanup

- The loop over epochs was replaced with a MasterChef-style accumulator per level, so gas no longer depended on the number of elapsed epochs.
- Variable packing, custom errors, explicit `uint256`, `external` visibility, unchecked loop increments.
- `USDT` renamed to `REWARD_TOKEN`, OpenZeppelin `SafeCast` for amount conversions.
- 30 day migration timelock, levels set in the constructor, `onlyGov` replaced with `onlyOwner`.
- Migrated from Hardhat to Foundry.

## Original design model (Excel)

The original Dexynth design was modelled in a spreadsheet before it was implemented. The spreadsheet models the original epoch-based reward logic: the rewards of each epoch are split across levels by boosted stake, with a per-user breakdown for three users.

The spreadsheet file is not part of this repository (it is listed in `.gitignore`). No test compares contract results against spreadsheet values. v2.2 streams rewards per second instead of per epoch, so the spreadsheet describes the v1 distribution. `test/differential/V1Shares.t.sol` checks that v1 and v2.2 split rewards between users in the same proportions.

![Excel model 1](./images/staking_excel_1.png)

![Excel model 2](./images/staking_excel_2.png)

![Excel model 3](./images/staking_excel_3.png)
