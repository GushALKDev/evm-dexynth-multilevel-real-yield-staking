# bench

`DexynthStakingV1.sol` is the original Dexynth staking contract (v1, 2023-2024), taken from commit `ff28790` and used, with permission, only by the gas benchmarks in `gas/` and by the differential test `test/differential/V1Shares.t.sol`. Its header comment says the same: "included only for gas benchmarks and the differential test, used with permission". It is not imported by `src/`, it is excluded from `forge fmt` and from the coverage command in the README, and apart from a header comment and its import paths it is unchanged.

It is compiled with the repo settings (solc 0.8.28, `via_ir = true`), not with the Hardhat setup and solc 0.8.19 of the original project, so its gas figures are not those of the originally deployed bytecode.

## Epoch timestamp drift

v1 locates epochs in two different ways. `getEpochIndexByTimestamp` uses `(timestamp - GENESIS_EPOCH_TIMESTAMP) / epochDuration`, while `getEpochTimestamps` uses `GENESIS_EPOCH_TIMESTAMP + (epochDuration + 1) * index`, one second more per epoch. Once L epochs are closed, `checkForClosingEpochs` measures the seconds since an epoch start that lies L + 1 seconds after the real one, computes a per-second rate from that shorter span, and the rewards of the epochs it closes add up to more than `accRewards`. `accRewards -= _epochRewards` then underflows, so any call that closes epochs in the first L + 1 seconds of an epoch reverts. The rework fixed this in commit `14b8f8f`.

The copy is kept as it was, so the benchmarks make every measured call 1 hour into an epoch, outside that window, for both v1 and v2.3.
