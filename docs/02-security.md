# Guide 2: Security

**Previous:** [Guide 1: Design](./01-design.md)
**Next:** [Guide 3: Testing and Gas](./03-testing.md)

---

## Trust assumptions and limitations

### Owner powers

The owner is the deployer. Ownership uses OpenZeppelin `Ownable2Step` v4.9.3.

| Function | What it can do to user funds or rewards |
|----------|------------------------------------------|
| `requestMigration(address)` | Stores a destination and starts the 30 day delay. Nothing moves yet. |
| `cancelMigration()` | Clears the pending request. |
| `executeMigration()` | Within the 7 day window after the delay, moves the rewards that are not streamed yet (the rest of the current epoch and the queued deposits) and the unallocated rewards to the destination, and stops the stream for good. It cannot move staked DEXY or rewards already accrued to stakers. |
| `transferOwnership(address)` | Nominates a new owner, who takes over only after calling `acceptOwnership`. |
| `renounceOwnership()` | Disabled, reverts with `RenounceOwnershipDisabled`. |

There is no pause and no emergency withdrawal. After a migration users can withdraw their principal at any time.

`addStakingReward(amount)` is not an owner function since v2.3: anyone can deposit. A deposit only adds to the next epoch to start, so the epoch already running keeps its rate and its end.

### Griefing and extraction

Measured in `test/Griefing.t.sol` with the example configuration:

- **Forced pool updates.** Each update truncates the accumulator by less than `totalBoostedStake / 1e36` reward units. With 1e26 boosted units and a 6-decimal token that is below 1e-10 units per update, below 2.7e-4 units over a year of updates every 12 seconds. A day of forced updates every 12 seconds pays exactly the same whole units as no updates. Each forced update costs the attacker a transaction; a follow-up stake costs 139,784 gas (`snapshots/v2_3.json`, `stake_subsequent`, measured as a whole transaction), about 3.7e11 gas for a year of updates every 12 seconds.
- **Dust stake alone at the start of a funded epoch.** A 2 wei stake at 0.65x (1 boosted unit) that is the only stake when a funded epoch starts receives the whole epoch until someone else stakes, instead of those rewards going to `unallocatedRewards`. Over one day of a 10,000 token, 15 day epoch that is 10,000 / 15 tokens. Funding an epoch while the contract has no real stakers exposes it to this.
- **Just-in-time staking before a funded epoch.** Deposits are public before their epoch starts (`queuedRewards` and the `RewardAdded` event), so anyone can stake right before it. Such a stake earns its exact pro-rata share of the epoch from its start. The principal stays locked for the level's lock, 30 days at level 0 in the example configuration, two 15 day epochs, so the stake also shares the epoch after. Epochs short against the lock make this less attractive.
- **Deposits by anyone.** A deposit cannot change the rate of a running epoch and does not loop, so a deposit of any size, dust included, cannot block stakers or other deposits. The only shared limit is `MAX_TOTAL_FUNDING = type(uint128).max` reward units over the life of the contract: with a reward token whose supply exceeds it, a holder could fill the cap and make further deposits revert with `FundingCapExceeded`. USDC, with 6 decimals, would need 3.4e32 tokens.

### Other limitations

- A deposit waits for the next epoch to start, up to one full epoch, and an epoch nobody deposited for streams nothing.
- Rewards streamed while nobody is staked are kept in `unallocatedRewards` and only reach stakers after the next deposit (or leave with a migration).
- Rounding always favours the contract. The dust that no user can claim (the floor of each settlement and of each accumulator update) stays in the contract with no function to recover it, except that a migration moves the unstreamed and unallocated part.
- `harvest` reverts for a user with no open stake. Nothing is lost: `unstake` pays all accrued rewards when the last stake is withdrawn.

## Security measures

- **Reentrancy:** OpenZeppelin `ReentrancyGuard` on every function that transfers tokens. `test/Reentrancy.t.sol` reenters each of them through a token callback.
- **Checks-Effects-Interactions:** state is updated before every token transfer.
- **Token transfers:** OpenZeppelin `SafeERC20`.
- **Casts:** OpenZeppelin `SafeCast` for every narrowing conversion, except three commented casts that are bounded by a previous check.
- **Access control:** OpenZeppelin `Ownable2Step` on migration. Deposits are open by design.

## Static analysis

Slither 0.11.6 and Aderyn 0.6.8 on `src/`:

```bash
slither . --filter-paths "lib|test|script|bench|gas"
aderyn . --path-excludes test,script,bench,gas,lib
```

| Tool | Finding | Location | Status |
|------|---------|----------|--------|
| Slither | `timestamp` (Low), 9 functions | `constructor`, `unstake`, `requestMigration`, `cancelMigration`, `executeMigration`, `getCurrentEpochIndex`, `_updatePool`, `_streamedSinceUpdate`, `_settle` | Accepted: epochs, locks and the migration window are time based by design, and a few seconds of validator drift are negligible against periods of days |
| Slither | `naming-convention` (Informational), 10 items | parameters with a leading underscore, `DEXY`, `REWARD_TOKEN`, `I_GENESIS_EPOCH_TIMESTAMP`, `DexynthStakingV2_3` | Accepted: repo naming convention; `I_GENESIS_EPOCH_TIMESTAMP` is kept to preserve the getter name |
| Slither | `divide-before-multiply` | `_streamedSinceUpdate`, the queued rate times the epoch length | Suppressed inline with its justification: the rate keeps 36 extra decimals, so the loss is below `epochDuration / 1e36` units per epoch |
| Slither | `incorrect-equality` | `_settle`, `acc == snapshot` | Suppressed inline with its justification: an early return when nothing accrued, not a balance check |
| Aderyn | ETH transferred without address checks (High), 4 instances | `stake`, `unstake`, `harvest`, `addStakingReward` | False positive: the contract never transfers ETH, only ERC20 tokens to and from `msg.sender` through SafeERC20 |
| Aderyn | Centralization risk (Low), 7 instances | migration functions, `Ownable2Step` inheritance, the test tokens | Accepted: owner powers are listed under Trust assumptions |
| Aderyn | Large numeric literal (Low), 2 instances | `src/DEXY.sol`, `src/RewardToken.sol` | Accepted: test token supplies, written with digit separators |
