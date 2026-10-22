# Guide 4: Review Notes and Changelog

**Previous:** [Guide 3: Testing and Gas](./03-testing.md)
**Next:** [README](../README.md)

---

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

- Documented as limitations with measurements, no code change: `test/FeeOnTransfer.t.sol` (commit `13a4e6f`) and `test/Griefing.t.sol` (commit `40a0633`). See [Guide 2: trust assumptions and limitations](./02-security.md#trust-assumptions-and-limitations).

#### Independent review of the test suite and the README

An independent review of the full diff found no contract bug and raised these points about the tests and the documentation:

- **Invariants could not detect lost rewards.** Cause: the reward invariant only had a lower bound, and conservation holds for any ERC20. Fix: an upper bound of rounding dust on `balance - liabilities`. Test: a mutant that drops unallocated rewards and one that halves the accumulator pass the old suite and fail the new one. Commit `36866ec`.
- **Gas figures measured with warm storage.** Cause: the gas profile ran without isolation. Fix: `isolate = true` and regenerated snapshots, which match a transaction receipt for `stake_subsequent`. Commit `0e28477`.
- **Unstakes in the handler happened mostly after streams ended.** Fix: prefer unlocked stakes, and count unstakes during a running stream. Commit `e9ec4e2`.
- **Weak or one-sided test checks.** Fix: migration amounts against the rational value, one-sided bounds in the minimum boosted stake test, the boosted amount limit tested one unit above it, harvest gas compared between 1 and 10 configured levels, one assertion that could not fail removed. Commit `5e47b10`.
- **Differential test limited to a constant set of stakes.** Fix: a scenario with a user joining halfway; a mutant that skips the settlement in `stake` fails it. Commit `453e130`.
- **README and comment wording.** The v1 copy scope, the test token comments, the Validation test description and the scope of the "never above" statement were corrected in the README update.

## Changelog

### Demo app (22 Oct 2026)

A Base Sepolia demo app in `app/` and its testnet tooling in `script/testnet/`: a faucet with DEXY and USDC stand-ins, a deployment with 1-day epochs and 1 hour to 14 day locks that keeps the production multipliers, a seed staked by the faucet, a funded stream and a top-up script, with their own test suite under `FOUNDRY_PROFILE=testnet`. `script/DeployDexynthStaking.s.sol` now exposes its levels and epoch length for reuse, with the same values. The staking contract is unchanged. See [app/README.md](../app/README.md).

### v2.2 (Sep 2026)

Fixes for the round 1 review findings, per-user reward accounting with a single reward-per-share accumulator, migration redesign, precision and funding bounds, two-step ownership, stake events with index and level, a rewritten test suite (exact expectations, solvency and conservation invariants in two campaigns, reentrancy, bounds, edge case, griefing and event tests), a gas harness against v1, CI, dependencies as pinned submodules and an MIT license. See the review notes above and the [changes for users](./01-design.md#changes-for-users-from-v21-to-v22).

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
