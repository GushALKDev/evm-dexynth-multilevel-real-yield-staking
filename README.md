# Dexynth Multilevel Real Yield Staking

[![CI](https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking/actions/workflows/ci.yml/badge.svg)](https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

A multi-level staking contract that pays real yield: users lock DEXY in one of several levels, each with its own lock period and reward multiplier, and earn a reward token that the owner funds and the contract streams every second.

The original contract was written at Dexynth (2023-2024). v2, v2.1 and v2.2 are a later independent rework (Dec 2025 - Sep 2026) that replaces the loop-based reward logic with a reward-per-share accumulator (one per level in v2 and v2.1, a single global one in v2.2).

> **Proof of concept. Not audited and not deployed on any mainnet.**

---

## Highlights

- **Constant cost.** `stake`, `unstake` and `harvest` never loop over stakes, levels or epochs. `harvest` costs 155,361 gas after 1 epoch or after 100, with 1 stake or with 500; the original contract needed 22,492,295 gas to harvest after 100 epochs.
- **Exact with low-decimal reward tokens.** Rates and the accumulator are scaled by 1e36: with a 6-decimal reward token and a pool update every 12 seconds, a day of rewards pays exactly the expected 33,333,333 units.
- **Rounding favours the contract.** The invariant suites bound the reward balance from both sides: never below what is owed, never above it by more than the rounding dust.
- **Bounded owner powers.** A migration waits 30 days, expires after a 7-day window and can only move rewards that are not streamed yet: never staked DEXY and never rewards already accrued to stakers.
- **Checked against the original.** A differential test shows v1 and v2.2 give every user the same share of what they pay, also when a user joins halfway.
- **Reviewed.** Three review rounds; the tests of each finding were run against the code before its fix.

---

## Demo app

[app/](./app) is a web app for this contract on Base Sepolia, with testnet DEXY from a faucet and a 6-decimal USDC
stand-in as the reward token. It draws the reward stream split by boosted weight, previews every stake and unstake
with the contract's own rounding (checked to the wei against a local deployment) and lets visitors stake, harvest
and unstake. The testnet deployment keeps the production multipliers but shortens epochs to 1 day and locks to 1 hour
to 14 days, so a stake can be unstaked within about a day. Its tooling lives in [script/testnet/](./script/testnet)
with its own tests. How it works, how to run it and how to deploy it: [app/README.md](./app/README.md).

Live demo: https://staking-poc.gushalk.workers.dev

---

## How it works

`DexynthStakingV2_2` ([src/DexynthStaking.sol](./src/DexynthStaking.sol)) keeps one global accumulator of reward per boosted unit:

1. A stake's weight is its boosted amount, `amount * boostP / 1e10`, where `boostP` is the level's multiplier. Every boosted unit earns the same reward per second.
2. The owner funds a stream with `addStakingReward(amount, duration)`, which sets `rewardRate` for the next `duration` seconds.
3. On every stake, unstake, harvest, funding and migration the pool adds `elapsed * rewardRate / totalBoostedStake` to `accRewardPerBoostedShare`. Time with nobody staked goes to `unallocatedRewards` and is rolled into the next funding.
4. Before a user's boosted balance changes, and on harvest, the contract settles `boostedBalance * (accumulator - snapshot) / 1e36` into the user's stored rewards, rounded down.

Epochs only anchor the lock: a stake unlocks at the start of the next epoch plus its level's `lockingPeriod`. Levels are fixed in the constructor (at most 10, lock and multiplier strictly increasing, average multiplier 1.0x). The configuration used by the tests and the deploy script, with 15-day epochs:

| Level | Lock | Multiplier |
|-------|------|------------|
| 0 | 30 days | 0.65x |
| 1 | 90 days | 0.85x |
| 2 | 180 days | 1.00x |
| 3 | 365 days | 1.15x |
| 4 | 720 days | 1.35x |

```solidity
function stake(uint256 _amount, uint8 _level) external;
function unstake(uint64 _stakeIndex) external;   // pays all accrued rewards; locked until unlockTime unless migrated
function harvest() external;
function pendingRewards(address _user) external view returns (uint256);

// Owner only
function addStakingReward(uint256 _amount, uint256 _duration) external;
function requestMigration(address _newContract) external;   // starts the 30-day delay
function cancelMigration() external;
function executeMigration() external;                       // 7-day window after the delay
```

The full accounting, the precision bounds, the token requirements, the migration rules and what changed for users from v2.1: [Guide 1: Design](./docs/01-design.md).

---

## Gas: v1 against v2.2

Each call measured as its own transaction (`isolate = true`) under the same scenarios, from `FOUNDRY_PROFILE=gas forge test` and `python3 gas/gas_table.py`:

| Scenario | v1 | v2.2 | Reduction |
|----------|---:|-----:|----------:|
| `stake_first` | 251,367 | 175,888 | 30.0% |
| `harvest_after_1_epoch` | 586,466 | 155,361 | 73.5% |
| `harvest_after_100_epochs` | 22,492,295 | 155,361 | 99.3% |
| `unstake_after_100_epochs` | 22,518,395 | 202,114 | 99.1% |
| `harvest_levels_touched_5` | 725,766 | 155,361 | 78.6% |

In v1, `harvest` and `unstake` loop over every level for every epoch since the user's last harvest. CI regenerates the snapshots and fails if they change. All 16 scenarios and the methodology: [Guide 3: Testing and Gas](./docs/03-testing.md#gas).

---

## Security and testing

| Area | Result |
|------|--------|
| Tests | 132: unit, regression, bounds, edge cases, events, griefing, reentrancy, differential and invariants |
| Invariants | 5 properties (principal backing, reward liabilities, reward conservation, boosted accounting, migration) in 4 suites: normal operation and migration, each with an 18-decimal and a 6-decimal reward token, `fail_on_revert = true` |
| Exact expectations | In the unit, regression, bounds, edge case, event and griefing tests, reward checks compare a payout against the exact rational value: below it by at most a stated number of wei, never above |
| Coverage of `src/DexynthStaking.sol` | 100% lines (163/163), 99.04% statements (207/209, a constant the compiler folds), 100% branches (38/38), 100% functions (18/18) |
| Static analysis | Slither 0.11.6 and Aderyn 0.6.8: every finding triaged; the three Aderyn High instances are false positives (the contract never transfers ETH) |

Owner powers are limited to funding the stream and migrating what is not streamed yet; there is no pause and no emergency withdrawal. The owner can still reschedule the remaining stream, and dust or just-in-time stakes around a funding have measured effects. Details: [Guide 2: Security](./docs/02-security.md). Every review finding, with its cause, fix, test and commit: [Guide 4: Review Notes and Changelog](./docs/04-review-notes.md).

---

## Getting started

Dependencies are git submodules pinned to release tags (forge-std v1.12.0, OpenZeppelin v4.9.3, also recorded in `foundry.lock`). Every figure in this README and the docs was measured with Foundry v1.7.1, solc 0.8.28 and `via_ir = true`.

```bash
git clone --recursive https://github.com/GushALKDev/evm-dexynth-multilevel-real-yield-staking.git
cd evm-dexynth-multilevel-real-yield-staking
forge build
forge test
```

```bash
forge test --match-path test/invariant/Invariant.t.sol          # invariant suites only
forge coverage --no-match-coverage "(bench|test|script)"        # coverage of src/
FOUNDRY_PROFILE=gas forge test && python3 gas/gas_table.py      # gas benchmarks, v1 against v2.2
```

---

## Repository layout

```
src/              the staking contract and the two test ERC20s
test/             unit, regression, bounds, edge case, griefing, reentrancy, differential and invariant tests
script/           the deploy script
script/testnet/   testnet faucet, demo deployment, stream top-up and their tests (FOUNDRY_PROFILE=testnet)
app/              the Base Sepolia demo app
bench/            the frozen v1 contract used by the benchmarks and the differential test
gas/              gas benchmarks against v1
snapshots/        the gas snapshots CI regenerates and compares
docs/             the four guides
images/           screenshots of the original spreadsheet model, used by the design guide
```

## Documentation

| Guide | Covers |
|-------|--------|
| [1. Design](./docs/01-design.md) | Reward accounting, precision and bounds, levels, tokens, functions, migration, the original spreadsheet model |
| [2. Security](./docs/02-security.md) | Owner powers, griefing and extraction measurements, limitations, security measures, static analysis |
| [3. Testing and Gas](./docs/03-testing.md) | Every test file, coverage, the invariant campaigns, the gas benchmarks against v1 |
| [4. Review Notes and Changelog](./docs/04-review-notes.md) | Every review finding with its cause, fix, test and commit; v2 to v2.2 changes |
| [bench/README.md](./bench/README.md) | The frozen v1 copy used by the benchmarks and the differential test |

## License

MIT, see [LICENSE](./LICENSE).

## Author

[@GushALKDev](https://github.com/GushALKDev), Gustavo Martín ([LinkedIn](https://www.linkedin.com/in/gustavomaral/)).
