# Guide 3: Testing and Gas

**Previous:** [Guide 2: Security](./02-security.md)
**Next:** [Guide 4: Review Notes and Changelog](./04-review-notes.md)

---

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
| `test/Validation.t.sol` | 14 | Constructor and parameter checks not covered by a regression test (the rest are in `test/regression/` and `test/Bounds.t.sol`) |
| `test/regression/*.t.sol` | 26 | One file per review finding (see [Review notes](./04-review-notes.md)) |
| `test/Bounds.t.sol` | 7 | Precision and overflow bounds |
| `test/EdgeCases.t.sol` | 6 | Stake and harvest at `rewardEndTime`, funding while a stream runs, when it ends and long after |
| `test/Events.t.sol` | 6 | Full payload of every event with `vm.expectEmit` |
| `test/Reentrancy.t.sol` | 5 | A token that reenters stake, unstake, harvest, addStakingReward and executeMigration hits the guard |
| `test/Griefing.t.sol` | 4 | Forced updates, dust stake, just-in-time stake, epoch boundary lock |
| `test/HarvestGasIndependence.t.sol` | 4 | Identical harvest gas across stake counts, epochs, levels touched and 1 or 10 configured levels |
| `test/Ownership.t.sol` | 3 | Two-step ownership, renounce disabled, pending migration across an ownership change |
| `test/FeeOnTransfer.t.sol` | 2 | The shortfalls a fee-on-transfer DEXY or reward token produces (unsupported) |
| `test/differential/V1Shares.t.sol` | 2 | v1 and v2.2 give each user the same share of what they pay, with a constant set of stakes and with a user joining halfway (absolute payouts are not comparable, see the test) |
| `test/invariant/Invariant.t.sol` | 18 | 5 invariants in 4 suites (2 campaigns x 2 reward token decimals); the migration invariant runs only in the migration campaign |

In the unit, regression, bounds, edge case, event and griefing tests, reward checks compare a payout against the exact rational value: it may be below it by a stated number of wei, justified in each test, and never above it. The differential test compares shares between versions with two-sided bounds derived from each version's rounding.

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
| Normal operation | `InvariantNormalReward18`, `InvariantNormalReward6` | 256 | 128 | stake (small and regular amounts), unstake (an unlocked stake if there is one, otherwise warping to the unlock time), harvest, owner funding, non-owner funding (must revert), two time warps |
| Migration | `InvariantMigrationReward18`, `InvariantMigrationReward6` | 256 | 64 | the same plus migration request, cancel, execute and expiry; after a migration stake and funding must revert |

Runs and depth are set per suite with inline config and justified next to each suite in `test/invariant/Invariant.t.sol`.

| Invariant | What it checks |
|-----------|----------------|
| `invariant_dexyBalanceCoversPrincipal` | The DEXY balance equals the principal of the open stakes read from `stakeInfo`, and the level totals add up to the same value. |
| `invariant_rewardBalanceMatchesLiabilities` | The reward balance is at least the sum of `pendingRewards` of every actor plus the unstreamed and unallocated rewards, rounded up (no tolerance), and exceeds it by at most the rounding dust: 1 wei per settlement, per executed migration and per actor, plus 1 for all 1e36-scaled truncations. Lost or withheld rewards break the upper bound. |
| `invariant_rewardConservation` | Rewards added equal rewards paid to actors plus rewards migrated plus rewards held, exactly, and equal `totalRewardsFunded`. |
| `invariant_boostedAndUserAccounting` | `totalBoostedStake` equals the boosted amounts of the open stakes and the sum of the users' boosted balances. Each user's totals match their open stakes. |
| `invariant_migrationStopsStream` | After a migration the rate and unallocated rewards stay at zero and no request is pending. Only in the migration campaign. |

With these settings the four suites found no violations.

## Gas

Gas benchmarks live in `gas/` and run in their own profile. They compare the original v1 contract (a frozen copy in `bench/`, used only by the gas benchmarks and the differential test) with v2.2 under the same named scenarios, write the results to `snapshots/v1.json` and `snapshots/v2_2.json`, and `gas/gas_table.py` prints the table below from those files.

```bash
FOUNDRY_PROFILE=gas forge test
python3 gas/gas_table.py
```

The gas profile runs with `isolate = true`: each measured call is executed as its own transaction, so storage touched by the setup is cold again and the figure includes the 21,000 intrinsic gas and the calldata cost, as a transaction receipt does. The v1 copy (also used by the differential test) is compiled with the repo settings (solc 0.8.28, `via_ir = true`), not with its original bytecode (Hardhat, solc 0.8.19), see [bench/README.md](../bench/README.md).

Common setup: 15 day epochs, the example multipliers and locks except that level 0 has no lock (so unstake can be measured one epoch after staking), bob staked 1000 DEXY at level 2 and 1,000,000 reward tokens added. "After N epochs" means the call happens N + 1 epochs and 1 hour after alice's stake, which gives both versions N rewarded epochs. Every measured call is 1 hour into an epoch because v1 reverts in the first seconds of an epoch (see [bench/README.md](../bench/README.md)). The stake scenarios are alice's first and second 1000 DEXY stake at level 0; the harvest-with-stakes scenarios use 100 DEXY stakes at level 0 and one rewarded epoch; the levels-touched scenarios use 100 DEXY in 1 level or in each of the 5 levels.

| Scenario | v1 | v2.2 | Reduction |
|----------|---:|-----:|----------:|
| `stake_first` | 251,367 | 175,888 | 30.0% |
| `stake_subsequent` | 182,967 | 141,688 | 22.6% |
| `harvest_after_1_epoch` | 586,466 | 155,361 | 73.5% |
| `harvest_after_10_epochs` | 2,577,905 | 155,361 | 94.0% |
| `harvest_after_52_epochs` | 11,871,287 | 155,361 | 98.7% |
| `harvest_after_100_epochs` | 22,492,295 | 155,361 | 99.3% |
| `unstake_after_1_epoch` | 612,566 | 202,114 | 67.0% |
| `unstake_after_10_epochs` | 2,604,005 | 202,114 | 92.2% |
| `unstake_after_52_epochs` | 11,897,387 | 202,114 | 98.3% |
| `unstake_after_100_epochs` | 22,518,395 | 202,114 | 99.1% |
| `harvest_with_1_stake` | 586,466 | 155,361 | 73.5% |
| `harvest_with_10_stakes` | 586,466 | 155,361 | 73.5% |
| `harvest_with_100_stakes` | 586,466 | 155,361 | 73.5% |
| `harvest_with_500_stakes` | 586,466 | 155,361 | 73.5% |
| `harvest_levels_touched_1` | 586,466 | 155,361 | 73.5% |
| `harvest_levels_touched_5` | 725,766 | 155,361 | 78.6% |

In v1, `harvest` and `unstake` loop over every level for every epoch since the user's last harvest, and close any pending epochs first. v1 does not loop over stakes. v2.2 does not loop over stakes, levels or epochs.
