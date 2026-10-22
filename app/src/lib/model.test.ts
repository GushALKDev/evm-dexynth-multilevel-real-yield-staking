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
  const st = { epochDuration: 86_400n, genesis: 1_000n, drip: 10n ** 22n, cooldown: 86_400n, migrationDelay: 2_592_000n, migrationWindow: 604_800n }
  const live = (over: Partial<LiveData>): LiveData => ({
    pool: {
      rewardRate: 0n,
      totalBoostedStake: 10n ** 24n,
      accRewardPerBoostedShare: 0n,
      unallocatedRewards: 0n,
      lastRewardTime: 50_000n,
      rewardEndTime: 50_000n,
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

  it('is everything funded once a stream has ended on its own', () => {
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
