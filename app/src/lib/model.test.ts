import { describe, expect, it } from 'vitest'
import type { Deployment } from '../config/deployment'
import type { LiveData } from '../hooks/useStakingData'
import { buildModel, projectionTimes } from './model'

describe('projection times', () => {
  it('never project ticking figures behind the latest block when the visitor clock runs slow', () => {
    // The visitor's clock is 2 days behind the chain: rewards accrued up to the latest block must still show
    const t = projectionTimes(1_000n, 1_000n + 172_800n, 1_000n + 172_790n)
    expect(t.now).toBe(1_000n + 172_800n)
    expect(t.chainTime).toBe(1_000n + 172_800n)
  })

  it('follow the visitor clock when it runs ahead of the latest block', () => {
    const t = projectionTimes(2_005n, 2_000n, 1_990n)
    expect(t.now).toBe(2_005n)
    expect(t.chainTime).toBe(2_000n)
  })

  it('never go behind the last pool update', () => {
    const t = projectionTimes(900n, undefined, 1_000n)
    expect(t.now).toBe(1_000n)
    expect(t.chainTime).toBe(1_000n)
  })
})

describe('the streamed figure', () => {
  const d = loadFixtureDeployment()
  const st = { epochDuration: 86_400n, genesis: 1_000n, drip: 10n ** 22n, usdcDrip: 5n * 10n ** 8n, cooldown: 86_400n, migrationDelay: 2_592_000n, migrationWindow: 604_800n }
  const live = (over: Partial<LiveData>): LiveData => ({
    pool: {
      rewardRate: 0n,
      totalBoostedStake: 10n ** 24n,
      accRewardPerBoostedShare: 0n,
      unallocatedRewards: 0n,
      lastRewardTime: 50_000n,
      nextEpochStart: 50_000n + 86_400n,
      queuedRewards: 0n,
      epochDuration: 86_400n,
    },
    levels: [{ lockingPeriod: 3_600n, boostP: 10n ** 10n, totalStaked: 10n ** 24n }],
    totalRewardsFunded: 100_000n * 10n ** 6n,
    migrated: false,
    migrationRequestTime: 0n,
    pendingMigrationAddress: '0x0000000000000000000000000000000000000000',
    owner: '0x0000000000000000000000000000000000000001',
    faucetStaked: 10n ** 24n,
    ...over,
  })

  it('is everything funded once the funded epochs have ended', () => {
    expect(buildModel(d, st, live({}), undefined, 60_000n, 60_000n).stream.streamed).toBe(100_000n * 10n ** 6n)
  })

  it('is unknown after a migration, which moved an amount the contract does not store', () => {
    expect(buildModel(d, st, live({ migrated: true }), undefined, 60_000n, 60_000n).stream.streamed).toBeNull()
  })
})

function loadFixtureDeployment(): Deployment {
  const token = (symbol: 'DEXY' | 'USDC', decimals: number) => ({ symbol, address: '0x0000000000000000000000000000000000000002' as const, decimals, shown: 2 })
  return {
    chainId: 31_337,
    deployBlock: 0n,
    staking: '0x0000000000000000000000000000000000000003',
    faucet: '0x0000000000000000000000000000000000000004',
    owner: '0x0000000000000000000000000000000000000001',
    dexy: token('DEXY', 18),
    reward: token('USDC', 6),
  }
}

describe('migration status', () => {
  const d = loadFixtureDeployment()
  const st = { epochDuration: 86_400n, genesis: 1_000n, drip: 10n ** 22n, usdcDrip: 5n * 10n ** 8n, cooldown: 86_400n, migrationDelay: 2_592_000n, migrationWindow: 604_800n }
  const base = (over: Partial<LiveData>): LiveData => ({
    pool: { rewardRate: 0n, totalBoostedStake: 1n, accRewardPerBoostedShare: 0n, unallocatedRewards: 0n, lastRewardTime: 10_000n, nextEpochStart: 86_401n, queuedRewards: 0n, epochDuration: 86_400n },
    levels: [{ lockingPeriod: 3_600n, boostP: 10n ** 10n, totalStaked: 1n }],
    totalRewardsFunded: 0n,
    migrated: false,
    migrationRequestTime: 10_000n,
    pendingMigrationAddress: '0x0000000000000000000000000000000000000005',
    owner: '0x0000000000000000000000000000000000000001',
    faucetStaked: 1n,
    ...over,
  })

  it('is pending until the execution window closes', () => {
    const end = 10_000n + st.migrationDelay + st.migrationWindow
    expect(buildModel(d, st, base({}), undefined, end, end).migrationPending).toBe(true)
  })

  it('is not pending once the request has expired', () => {
    const after = 10_000n + st.migrationDelay + st.migrationWindow + 1n
    expect(buildModel(d, st, base({}), undefined, after, after).migrationPending).toBe(false)
  })
})

describe('account figures', () => {
  it('come from the pool read in the same call as the account, not from a staler pool read', () => {
    const d = loadFixtureDeployment()
    const st = { epochDuration: 86_400n, genesis: 1_000n, drip: 10n ** 22n, usdcDrip: 5n * 10n ** 8n, cooldown: 86_400n, migrationDelay: 1n, migrationWindow: 1n }
    const stale = { rewardRate: 10n ** 36n, totalBoostedStake: 10n ** 18n, accRewardPerBoostedShare: 5n * 10n ** 18n, unallocatedRewards: 0n, lastRewardTime: 1_000n, nextEpochStart: 10n ** 9n, queuedRewards: 0n, epochDuration: 86_400n }
    const fresh = { ...stale, accRewardPerBoostedShare: 9n * 10n ** 18n, lastRewardTime: 1_100n }
    const live: LiveData = {
      pool: stale,
      levels: [{ lockingPeriod: 3_600n, boostP: 10n ** 10n, totalStaked: 10n ** 18n }],
      totalRewardsFunded: 0n,
      migrated: false,
      migrationRequestTime: 0n,
      pendingMigrationAddress: '0x0000000000000000000000000000000000000000',
      owner: '0x0000000000000000000000000000000000000001',
      faucetStaked: 0n,
    }
    const user = { stakeCount: 1n, storedRewards: 0n, totalStakedDexy: 10n ** 18n, boostedBalance: 10n ** 18n, totalHarvestedRewards: 0n, accRewardSnapshot: fresh.accRewardPerBoostedShare }
    const account = { user, pool: fresh, stakes: [], wallet: { dexy: 0n, reward: 0n, eth: 1n }, allowance: 0n, nextClaimAt: 0n }
    const m = buildModel(d, st, live, account as never, 1_100n, 1_100n)
    expect(m.account!.pending).toBe(0n)
    expect(m.account!.pendingAtChain).toBe(0n)
  })
})

describe('epoch figures', () => {
  const d = loadFixtureDeployment()
  const st = { epochDuration: 86_400n, genesis: 100_000n, drip: 10n ** 22n, usdcDrip: 5n * 10n ** 8n, cooldown: 86_400n, migrationDelay: 1n, migrationWindow: 1n }
  // Deployed at 90,000 with 1,000 USDC queued for epoch 0, which starts at 100,000; no call since
  const live: LiveData = {
    pool: { rewardRate: 0n, totalBoostedStake: 10n ** 18n, accRewardPerBoostedShare: 0n, unallocatedRewards: 0n, lastRewardTime: 90_000n, nextEpochStart: 100_000n, queuedRewards: 10n ** 9n * 10n ** 36n, epochDuration: 86_400n },
    levels: [{ lockingPeriod: 3_600n, boostP: 10n ** 10n, totalStaked: 10n ** 18n }],
    totalRewardsFunded: 10n ** 9n,
    migrated: false,
    migrationRequestTime: 0n,
    pendingMigrationAddress: '0x0000000000000000000000000000000000000000',
    owner: '0x0000000000000000000000000000000000000001',
    faucetStaked: 10n ** 18n,
  }

  it('show epoch 0 ahead, with its deposit queued and nothing streaming yet', () => {
    const m = buildModel(d, st, live, undefined, 95_000n, 95_000n)
    expect(m.epoch).toBe(-1n)
    expect(m.nextEpochAt).toBe(100_000n)
    expect(m.stream.active).toBe(false)
    expect(m.stream.perDay).toBe(0n)
    expect(m.stream.queued).toBe(10n ** 9n)
    expect(m.stream.nextPerDay).toBe(((10n ** 45n / 86_400n) * 86_400n) / 10n ** 36n)
  })

  it('stream epoch 0 once it starts, before any call writes it', () => {
    const m = buildModel(d, st, live, undefined, 100_000n + 3_600n, 100_000n + 3_600n)
    expect(m.epoch).toBe(0n)
    expect(m.nextEpochAt).toBe(186_400n)
    expect(m.stream.active).toBe(true)
    expect(m.stream.perDay).toBe(((10n ** 45n / 86_400n) * 86_400n) / 10n ** 36n)
    expect(m.stream.queued).toBe(0n)
  })
})

describe('projection times with a fast clock', () => {
  it('tick at most 30 seconds past the latest block', () => {
    const t = projectionTimes(5_000n, 1_000n, 900n)
    expect(t.now).toBe(1_030n)
    expect(t.chainTime).toBe(1_000n)
  })
})
