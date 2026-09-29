# Guide 2: Security

**Previous:** [Guide 1: Design](./01-design.md)
**Next:** [Guide 3: Testing and Gas](./03-testing.md)

---

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

- **Forced pool updates.** Each update truncates the accumulator by less than `totalBoostedStake / 1e36` reward units. With 1e26 boosted units and a 6-decimal token that is below 1e-10 units per update, below 2.7e-4 units over a year of updates every 12 seconds. A day of forced updates every 12 seconds pays exactly the same whole units as no updates. Each forced update costs the attacker a transaction; a follow-up stake costs 141,688 gas (`snapshots/v2_2.json`, `stake_subsequent`, measured as a whole transaction), about 3.7e11 gas for a year of updates every 12 seconds.
- **Dust stake alone at the start of a stream.** A 2 wei stake at 0.65x (1 boosted unit) that is the only stake when a stream starts receives the whole stream until someone else stakes, instead of those rewards going to `unallocatedRewards`. Over one day of a 10,000 token, 30 day stream that is 10,000 / 30 tokens. Funding a stream while the contract has no real stakers exposes it to this.
- **Just-in-time staking before a funding.** A stake made right before `addStakingReward` earns its exact pro-rata share of the stream from that block, claimable at once. The principal stays locked until the next epoch start plus the level's lock: 30 to 45 days at level 0 in the example configuration. Staking one second before an epoch boundary gives the shortest lock, `lockingPeriod` plus one second. Short streams make this more attractive relative to the lock.

### Other limitations

- Rewards streamed while nobody is staked are kept in `unallocatedRewards` and only reach stakers after the owner calls `addStakingReward` again (or leave with a migration).
- Rounding always favours the contract. The dust that no user can claim (the floor of each settlement and of each accumulator update) stays in the contract with no function to recover it, except that a migration moves the unstreamed and unallocated part.
- `harvest` reverts for a user with no open stake. Nothing is lost: `unstake` pays all accrued rewards when the last stake is withdrawn.

## Security measures

- **Reentrancy:** OpenZeppelin `ReentrancyGuard` on every function that transfers tokens. `test/Reentrancy.t.sol` reenters each of them through a token callback.
- **Checks-Effects-Interactions:** state is updated before every token transfer.
- **Token transfers:** OpenZeppelin `SafeERC20`.
- **Casts:** OpenZeppelin `SafeCast` for every narrowing conversion, except three commented casts that are bounded by a previous check.
- **Access control:** OpenZeppelin `Ownable2Step` on funding and migration.

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
