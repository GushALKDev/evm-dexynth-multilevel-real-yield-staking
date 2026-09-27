# Dexynth Multilevel Real Yield Staking

[![CI](https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking/actions/workflows/ci.yml/badge.svg)](https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Original contract written at Dexynth (2023-2024). v2, v2.1 and v2.2 are a later independent rework (Dec 2025 - Sep 2026) that replaces the loop-based reward logic with a reward-per-share accumulator (one per level in v2 and v2.1, a single global one in v2.2).

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
- Ownership changes take two steps (`transferOwnership` then `acceptOwnership`) and `renounceOwnership` reverts.
- Events: `DEXYStaked` and `DEXYUnstaked` carry the stake index and the level, indexed together with the user. `RewardAdded(amount, duration, rewardRate)` is new. `DEXYMigrationSuccess` is removed (DEXY is never migrated).
- The contract is renamed `DexynthStakingV2_2`. The `users` and `stakeInfo` getters return the new struct fields.

## Precision and bounds

- `PRECISION = 1e36` scales `rewardRate`, `unallocatedRewards` and `accRewardPerBoostedShare`. Each pool update truncates the accumulator by less than `totalBoostedStake / 1e36` reward units, and the rate truncation loses less than `_duration / 1e36` units per funding. With a 6-decimal reward token, pool updates every 12 seconds over one day pay exactly the expected 33,333,333 units (`test/regression/RewardPrecision.t.sol`).
- `MAX_TOTAL_FUNDING = type(uint128).max` reward units (about 3.4e20 tokens with 18 decimals, 3.4e32 with 6). Funding above it reverts with `FundingCapExceeded`. Every reward amount the contract holds, streams or owes is then below 2^128, which the `uint128` per-user fields need.
- The smallest boosted stake is 1 unit, so over the life of the contract the accumulator stays below `MAX_TOTAL_FUNDING * 1e36`, about 3.4e74, far from `type(uint256).max` (about 1.16e77).
- A stake's amount and its boosted amount must each fit in `uint128`, otherwise `stake` reverts.

`test/Bounds.t.sol` covers these limits: the maximum funding streamed in full, the minimum boosted stake alone with the maximum funding, the maximum stake amount, and the reverts just above each limit.

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
- All six token calls go through OpenZeppelin `SafeERC20`. The contract never reads `decimals()` or `balanceOf`; the invariant suites run with an 18-decimal and a 6-decimal reward token.
- Fee-on-transfer and rebasing tokens are not supported: the contract records the amount requested, not the amount received. `test/FeeOnTransfer.t.sol` shows that with a 1% fee DEXY the last unstake reverts, and with a 1% fee reward token the stream promises more than the balance and harvest reverts.

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
- `cancelMigration()` clears a pending request. A pending request survives an ownership change and the new owner can execute it.

## Trust assumptions and limitations

### Owner powers

The owner is the deployer. Ownership uses OpenZeppelin `Ownable2Step` v4.9.3.

| Function | What it can do to user funds or rewards |
|----------|------------------------------------------|
| `addStakingReward(amount, duration)` | Funds the stream and restarts it. With `amount = 0` it can stretch the remaining rewards over a very long duration (slowing the stream to almost nothing) or compress them into one second (paying them to the current stakers at once). |
| `requestMigration(address)` | Stores a destination and starts the 30 day delay. Nothing moves yet. |
| `cancelMigration()` | Clears the pending request. |
| `executeMigration()` | Within the 7 day window after the delay, moves the rewards that are not streamed yet and the unallocated rewards to the destination, and stops the stream for good. It cannot move staked DEXY or rewards already accrued to stakers. |
| `transferOwnership(address)` | Nominates a new owner, who takes over only after calling `acceptOwnership`. |
| `renounceOwnership()` | Disabled, reverts with `RenounceOwnershipDisabled`. |

There is no pause and no emergency withdrawal. After a migration users can withdraw their principal at any time.

### Griefing and extraction

Measured in `test/Griefing.t.sol` with the example configuration:

- **Forced pool updates.** Each update truncates the accumulator by less than `totalBoostedStake / 1e36` reward units. With 1e26 boosted units and a 6-decimal token that is below 1e-10 units per update, below 2.7e-4 units over a year of updates every 12 seconds. A day of forced updates every 12 seconds pays exactly the same whole units as no updates. Each forced update costs the attacker a transaction; a follow-up stake costs 79,784 gas (`snapshots/v2_2.json`, `stake_subsequent`) plus the 21,000 intrinsic gas.
- **Dust stake alone at the start of a stream.** A 2 wei stake at 0.65x (1 boosted unit) that is the only stake when a stream starts receives the whole stream until someone else stakes, instead of those rewards going to `unallocatedRewards`. Over one day of a 10,000 token, 30 day stream that is 10,000 / 30 tokens. Funding a stream while the contract has no real stakers exposes it to this.
- **Just-in-time staking before a funding.** A stake made right before `addStakingReward` earns its exact pro-rata share of the stream from that block, claimable at once. The principal stays locked until the next epoch start plus the level's lock: 30 to 45 days at level 0 in the example configuration. Staking one second before an epoch boundary gives the shortest lock, `lockingPeriod` plus one second. Short streams make this more attractive relative to the lock.

### Other limitations

- Rewards streamed while nobody is staked are kept in `unallocatedRewards` and only reach stakers after the owner calls `addStakingReward` again (or leave with a migration).
- Rounding always favours the contract. The dust that no user can claim (the floor of each settlement and of each accumulator update) stays in the contract with no function to recover it, except that a migration moves the unstreamed and unallocated part.
- `harvest` reverts for a user with no open stake. Nothing is lost: `unstake` pays all accrued rewards when the last stake is withdrawn.

## Setup

Dependencies are git submodules pinned to release tags (forge-std v1.12.0, OpenZeppelin v4.9.3, also recorded in `foundry.lock`). The toolchain used for every figure in this README is Foundry v1.7.1 with solc 0.8.28 and `via_ir = true`.

```bash
git clone --recursive https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking.git
cd evm-dexynth-multilevel-real-yield-staking
forge build
```

## Testing

```bash
# All correctness tests: unit, regression, bounds, edge cases, events, griefing, reentrancy, differential, invariants
forge test

# Number of tests
forge test --list | grep -cE '^    [a-zA-Z]'

# Invariant suites only
forge test --match-path test/invariant/Invariant.t.sol

# Coverage of src/ (bench/, test/ and script/ excluded)
forge coverage --no-match-coverage "(bench|test|script)"
```

`forge test` runs 132 tests. Fuzz tests use Foundry's default of 256 runs.

| File | Tests | What they check |
|------|-------|-----------------|
| `test/DexynthStaking.t.sol` | 35 | Stake, unstake, harvest, epochs, migration basics and fuzz tests, with exact expected amounts |
| `test/Validation.t.sol` | 14 | Every constructor and parameter check |
| `test/regression/*.t.sol` | 26 | One file per review finding (see Review notes) |
| `test/Bounds.t.sol` | 7 | Precision and overflow bounds |
| `test/EdgeCases.t.sol` | 6 | Stake and harvest at `rewardEndTime`, funding while a stream runs, when it ends and long after |
| `test/Events.t.sol` | 6 | Full payload of every event with `vm.expectEmit` |
| `test/Reentrancy.t.sol` | 5 | A token that reenters stake, unstake, harvest, addStakingReward and executeMigration hits the guard |
| `test/Griefing.t.sol` | 4 | Forced updates, dust stake, just-in-time stake, epoch boundary lock |
| `test/HarvestGasIndependence.t.sol` | 3 | Identical harvest gas across stake counts, epochs and levels touched |
| `test/Ownership.t.sol` | 3 | Two-step ownership, renounce disabled, pending migration across an ownership change |
| `test/FeeOnTransfer.t.sol` | 2 | The shortfalls a fee-on-transfer DEXY or reward token produces (unsupported) |
| `test/differential/V1Shares.t.sol` | 1 | v1 and v2.2 split rewards by boosted stake in the same way (absolute payouts are not comparable, see the test) |
| `test/invariant/Invariant.t.sol` | 20 | 5 invariants in 4 suites (2 campaigns x 2 reward token decimals) |

Reward checks compare against the exact rational value: a payout may be below it by a stated number of wei, justified in each test, and never above it.

Coverage, from `forge coverage --no-match-coverage "(bench|test|script)"`:

| Contract | Lines | Statements | Branches | Functions |
|----------|-------|------------|----------|-----------|
| `src/DexynthStaking.sol` | 100% (163/163) | 99.04% (207/209) | 100% (38/38) | 100% (18/18) |
| `src/DEXY.sol` | 100% (2/2) | 100% (1/1) | 100% (0/0) | 100% (1/1) |
| `src/RewardToken.sol` | 100% (2/2) | 100% (1/1) | 100% (0/0) | 100% (1/1) |

The two statements reported as uncovered are the constant expression `MIGRATION_DELAY + MIGRATION_WINDOW`, which the compiler folds.

### Invariant tests

The handler asserts every revert the contract should raise with `vm.expectRevert`, and the suites run with `fail_on_revert = true`, so any other revert fails the run. Calls that have nothing to do in the current state are discarded with `vm.assume`. Effective calls per action are appended to `cache/invariant-stats-<campaign>-<decimals>.txt` at the end of each run.

| Campaign | Suites | Runs | Depth | Handler actions |
|----------|--------|------|-------|-----------------|
| Normal operation | `InvariantNormalReward18`, `InvariantNormalReward6` | 256 | 128 | stake (small and regular amounts), unstake (warping to the unlock time if needed), harvest, owner funding, non-owner funding (must revert), two time warps |
| Migration | `InvariantMigrationReward18`, `InvariantMigrationReward6` | 256 | 64 | the same plus migration request, cancel, execute and expiry; after a migration stake and funding must revert |

Runs and depth are set per suite with inline config and justified next to each suite in `test/invariant/Invariant.t.sol`.

| Invariant | What it checks |
|-----------|----------------|
| `invariant_dexyBalanceCoversPrincipal` | The DEXY balance equals the principal of the open stakes read from `stakeInfo`, and the level totals add up to the same value. |
| `invariant_rewardBalanceCoversLiabilities` | The reward balance is at least the sum of `pendingRewards` of every actor plus the unstreamed and unallocated rewards, rounded up. No tolerance. |
| `invariant_rewardConservation` | Rewards added equal rewards paid to actors plus rewards migrated plus rewards held, exactly, and equal `totalRewardsFunded`. |
| `invariant_boostedAndUserAccounting` | `totalBoostedStake` equals the boosted amounts of the open stakes and the sum of the users' boosted balances. Each user's totals match their open stakes. |
| `invariant_migrationStopsStream` | After a migration the rate and unallocated rewards stay at zero and no request is pending. In the normal campaign no migration happens, so it only checks the migration campaign. |

With these settings the four suites found no violations.

## Gas

Gas benchmarks live in `gas/` and run in their own profile. They compare the original v1 contract (a frozen copy in `bench/`, used only for benchmarks) with v2.2 under the same named scenarios, write the results to `snapshots/v1.json` and `snapshots/v2_2.json`, and `gas/gas_table.py` prints the table below from those files.

```bash
FOUNDRY_PROFILE=gas forge test
python3 gas/gas_table.py
```

Figures are the gas of the measured call, without the 21,000 intrinsic transaction gas. The v1 copy is compiled with the repo settings (solc 0.8.28, `via_ir = true`), not with its original bytecode (Hardhat, solc 0.8.19), see [bench/README.md](./bench/README.md).

Common setup: 15 day epochs, the example multipliers and locks except that level 0 has no lock (so unstake can be measured one epoch after staking), bob staked 1000 DEXY at level 2 and 1,000,000 reward tokens added. "After N epochs" means the call happens N + 1 epochs and 1 hour after alice's stake, which gives both versions N rewarded epochs. Every measured call is 1 hour into an epoch because v1 reverts in the first seconds of an epoch (see [bench/README.md](./bench/README.md)). The stake scenarios are alice's first and second 1000 DEXY stake at level 0; the harvest-with-stakes scenarios use 100 DEXY stakes at level 0 and one rewarded epoch; the levels-touched scenarios use 100 DEXY in 1 level or in each of the 5 levels.

| Scenario | v1 | v2.2 | Reduction |
|----------|---:|-----:|----------:|
| `stake_first` | 229,963 | 157,284 | 31.6% |
| `stake_subsequent` | 122,263 | 79,784 | 34.7% |
| `harvest_after_1_epoch` | 555,402 | 123,097 | 77.8% |
| `harvest_after_10_epochs` | 2,546,841 | 123,097 | 95.2% |
| `harvest_after_52_epochs` | 11,840,223 | 123,097 | 99.0% |
| `harvest_after_100_epochs` | 22,461,231 | 123,097 | 99.5% |
| `unstake_after_1_epoch` | 605,074 | 143,222 | 76.3% |
| `unstake_after_10_epochs` | 2,596,513 | 143,222 | 94.5% |
| `unstake_after_52_epochs` | 11,889,895 | 143,222 | 98.8% |
| `unstake_after_100_epochs` | 22,510,903 | 143,222 | 99.4% |
| `harvest_with_1_stake` | 555,402 | 123,097 | 77.8% |
| `harvest_with_10_stakes` | 555,402 | 123,097 | 77.8% |
| `harvest_with_100_stakes` | 555,402 | 123,097 | 77.8% |
| `harvest_with_500_stakes` | 555,402 | 123,097 | 77.8% |
| `harvest_levels_touched_1` | 555,402 | 123,097 | 77.8% |
| `harvest_levels_touched_5` | 678,702 | 123,097 | 81.9% |

In v1, `harvest` and `unstake` loop over every level for every epoch since the user's last harvest, and close any pending epochs first. v1 does not loop over stakes. v2.2 does not loop over stakes, levels or epochs.

## Static analysis

Slither 0.11.6 and Aderyn 0.6.8 on `src/`:

```bash
slither . --filter-paths "lib|test|script|bench|gas"
aderyn . --path-excludes test,script,bench,gas,lib
```

| Tool | Finding | Location | Status |
|------|---------|----------|--------|
| Slither | `timestamp` (Low), 8 functions | `unstake`, `addStakingReward`, `requestMigration`, `cancelMigration`, `executeMigration`, `pendingRewards`, `_updatePool`, `_settle` | Accepted: the stream, locks and migration window are time based by design, and a few seconds of validator drift are negligible against periods of days |
| Slither | `naming-convention` (Informational), 11 items | parameters with a leading underscore, `DEXY`, `REWARD_TOKEN`, `I_GENESIS_EPOCH_TIMESTAMP`, `DexynthStakingV2_2` | Accepted: repo naming convention; `I_GENESIS_EPOCH_TIMESTAMP` is kept to preserve the getter name |
| Slither | `divide-before-multiply` | `addStakingReward`, rebuilding the unstreamed amount from `rewardRate` | Suppressed inline with its justification: the rate keeps 36 extra decimals, so the loss is below `(rewardEndTime - now) / 1e36` units |
| Slither | `incorrect-equality` | `_settle`, `acc == snapshot` | Suppressed inline with its justification: an early return when nothing accrued, not a balance check |
| Aderyn | ETH transferred without address checks (High), 3 instances | `stake`, `unstake`, `harvest` | False positive: the contract never transfers ETH, only ERC20 tokens to `msg.sender` through SafeERC20 |
| Aderyn | Centralization risk (Low), 8 instances | owner functions, `Ownable2Step` inheritance, the test tokens | Accepted: owner powers are listed under Trust assumptions |
| Aderyn | Large numeric literal (Low), 2 instances | `src/DEXY.sol`, `src/RewardToken.sol` | Accepted: test token supplies, written with digit separators |

## Security measures

- **Reentrancy:** OpenZeppelin `ReentrancyGuard` on every function that transfers tokens. `test/Reentrancy.t.sol` reenters each of them through a token callback.
- **Checks-Effects-Interactions:** state is updated before every token transfer.
- **Token transfers:** OpenZeppelin `SafeERC20`.
- **Casts:** OpenZeppelin `SafeCast` for every narrowing conversion, except three commented casts that are bounded by a previous check.
- **Access control:** OpenZeppelin `Ownable2Step` on funding and migration.

## Review notes

One entry per finding of the three review rounds. The tests of each finding were run against the code before its fix, and the ones that encode the fixed behaviour failed there.

### Round 1 findings, fixed in round 2

#### Permissionless `addStakingReward`

- **Cause.** The function had no access control, so anyone could reschedule the remaining stream for free, stretching it or compressing it into one second.
- **Fix.** `onlyOwner`.
- **Test.** `test/regression/AddRewardAccess.t.sol`, plus the handler's non-owner funding action.
- **Commit.** `9f44894`.

#### Precision loss with low-decimal reward tokens

- **Cause.** `rewardRate` was truncated to whole units per second and the per-level accumulator had 1e18 precision per DEXY. With 6 decimals and 10M DEXY in a level, pool updates every 12 seconds rounded the accumulator increment to zero.
- **Fix.** `rewardRate` and the accumulator are scaled by 1e36, products use `Math.mulDiv`, and the funding cap bounds every value.
- **Test.** `test/regression/RewardPrecision.t.sol`, `test/Bounds.t.sol`, and the invariant suites with a 6-decimal token.
- **Commits.** `be001bc`, cap in `d02eb37`.

#### Rewards streamed with no stakers

- **Cause.** When `totalBoostedStake` was zero the pool skipped the elapsed time, and those rewards stayed in the contract with no claimant. A 1 wei stake at 0.65x had a boosted amount of zero and caused the same.
- **Fix.** The skipped amount goes to `unallocatedRewards` and is rolled into the next funding; stakes with a zero boosted amount revert.
- **Test.** `test/regression/UnallocatedRewards.t.sol`.
- **Commit.** `668897a`.

#### Migration could move locked principal and requests never expired

- **Cause.** `executeMigration` transferred the whole DEXY and reward balances, including locked principal and accrued rewards, and a request stayed executable forever.
- **Fix.** Migration moves only unstreamed and unallocated rewards, stops the stream, expires 7 days after the delay, and unlocks principal afterwards.
- **Test.** `test/regression/Migration.t.sol`, the migration campaign and `invariant_migrationStopsStream`.
- **Commit.** `6997f6d`.

#### Rewards accrued before `rewardStartTime`

- **Cause.** v2.1 documented `rewardStartTime` as the start of accrual, but stakes accrued from creation and the field only delayed claiming.
- **Fix.** `rewardStartTime` is removed. Rewards accrue and are claimable from the stake's block; the next epoch start only anchors `unlockTime`.
- **Test.** `testRewardsAccrueFromStakeTime` in `test/DexynthStaking.t.sol`.
- **Commit.** `d02eb37`.

#### `harvest` cost grew with the number of stakes

- **Cause.** v2.1 settled rewards per stake, so `harvest` looped over every stake the user had ever created. Against v2.1 the regression test measured 391,631 gas with 10 stakes against 165,470 with one.
- **Fix.** Per-user accounting with one accumulator per boosted unit (v2.2).
- **Test.** `test/HarvestGasIndependence.t.sol`.
- **Commit.** `d02eb37`.

#### Small findings

- `unstake` on a never used index succeeded and emitted an event with amount 0. It now reverts with `StakeNotFound`. Test in `test/regression/InfoFindings.t.sol`, commit `73a24ed`.
- The constructor accepted `DEXY == REWARD_TOKEN`. It now reverts with `SameToken`. Commit `046e2d7`.
- The number of levels had no cap and the constructor loop used a `uint8` counter. The cap is `MAX_LEVELS = 10` and the counter is `uint256`. Commit `42dec44`.
- `migrationRequestTime` was a `uint32`, truncated from February 2106. It is now `uint40`. Commit `d0c2395`.

#### v2.1 rounding fix in `totalBoostedStake`

- **Cause.** In v2, `stake` and `unstake` updated `totalBoostedStake` with per-stake rounded values, while the reward split used per-level rounded values, so the two drifted apart by a few wei.
- **Fix.** v2.1 (`d39e101`) recomputed the total from the level totals. v2.2 makes it structural: each stake stores its `boostedAmount`, `unstake` subtracts exactly that value, and the reward split uses the same total.
- **Test.** `invariant_boostedAndUserAccounting` checks that `totalBoostedStake` equals the sum of the open stakes' boosted amounts after every handler call.

### Round 2 finding

#### Constructor copied `Level.totalStaked`

- **Cause.** The constructor stored the `totalStaked` value it received, so a non-zero value created stake that nobody owned. With 1000 DEXY of such stake in level 0 and one real staker of 1000 DEXY, the staker received 5,000 of 10,000 funded tokens.
- **Fix.** Levels are stored with `totalStaked = 0`.
- **Test.** `test/regression/ConstructorLevels.t.sol`.
- **Commit.** `45458c5`.

#### v1 epoch timestamp drift (not fixed, frozen benchmark copy)

- **Cause.** The original v1 computes epoch start times with `(epochDuration + 1) * index`, and `checkForClosingEpochs` underflows in the first L + 1 seconds of an epoch once L epochs are closed.
- **Fix.** Fixed in the rework in `14b8f8f`. The copy in `bench/` keeps the original code, and the gas benchmarks measure every call 1 hour into an epoch.

### Round 3

#### Single-step ownership and `renounceOwnership`

- **Cause.** With `Ownable`, a mistyped `transferOwnership` address would lose funding and migration for good, and `renounceOwnership` would do the same on purpose. Users could still withdraw and claim in both cases.
- **Fix.** `Ownable2Step` and `renounceOwnership` disabled.
- **Test.** `test/Ownership.t.sol`.
- **Commit.** `75c3886`.

#### Stake events without index and level

- **Cause.** `DEXYStaked` and `DEXYUnstaked` only carried the user and the amount, so an indexer could not tell which stake or level they referred to.
- **Fix.** Both events carry the stake index and the level, indexed with the user.
- **Test.** `test/Events.t.sol`.
- **Commit.** `444a459`.

#### Fee-on-transfer tokens, dust stakes and just-in-time staking

- Documented as limitations with measurements, no code change: `test/FeeOnTransfer.t.sol` (commit `13a4e6f`) and `test/Griefing.t.sol` (commit `40a0633`). See Trust assumptions and limitations.

## Changelog

### v2.2 (Sep 2026)

Fixes for the round 1 review findings, per-user reward accounting with a single reward-per-share accumulator, migration redesign, precision and funding bounds, two-step ownership, stake events with index and level, a rewritten test suite (exact expectations, solvency and conservation invariants in two campaigns, reentrancy, bounds, edge case, griefing and event tests), a gas harness against v1, CI, dependencies as pinned submodules and an MIT license. See Review notes and the changes for users above.

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
