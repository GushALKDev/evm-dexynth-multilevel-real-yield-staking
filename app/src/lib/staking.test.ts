import { ContractFunctionRevertedError, encodeErrorResult, parseAbi } from 'viem'
import { describe, expect, it } from 'vitest'
import { withGasMargin } from '../hooks/useTx'
import { stakingAbi } from './abi'
import { describeError } from './errors'
import { countdown, formatDuration } from './format'
import {
  PRECISION,
  applyHarvest,
  applyStake,
  applyUnstake,
  boostedAmount,
  pendingRewards,
  rewardsOver,
  settle,
  unlockTimeFor,
  unstreamedScaled,
  updatePool,
  type Pool,
  type UserState,
} from './staking'

const T0 = 1_800_000_000n
const pool = (over: Partial<Pool> = {}): Pool => ({
  rewardRate: (100_000n * 10n ** 6n * PRECISION) / (365n * 86_400n),
  totalBoostedStake: 1_000n * 10n ** 18n,
  accRewardPerBoostedShare: 0n,
  unallocatedRewards: 0n,
  lastRewardTime: T0,
  rewardEndTime: T0 + 365n * 86_400n,
  ...over,
})
const user = (over: Partial<UserState> = {}): UserState => ({
  stakeCount: 0n,
  storedRewards: 0n,
  totalStakedDexy: 0n,
  boostedBalance: 0n,
  totalHarvestedRewards: 0n,
  accRewardSnapshot: 0n,
  ...over,
})

describe('boosted amounts', () => {
  it('rounds down like amount * boostP / 1e10', () => {
    expect(boostedAmount(1n, 6_500_000_000n)).toBe(0n)
    expect(boostedAmount(3n, 6_500_000_000n)).toBe(1n)
    expect(boostedAmount(10n ** 18n, 13_500_000_000n)).toBe(1_350_000_000_000_000_000n)
  })
})

describe('pool updates', () => {
  it('change nothing at or before the last update', () => {
    const p = pool()
    expect(updatePool(p, T0)).toBe(p)
    expect(updatePool(p, T0 - 5n)).toBe(p)
  })

  it('add elapsed * rate / total to the accumulator, rounded down', () => {
    const p = pool()
    const next = updatePool(p, T0 + 12n)
    expect(next.accRewardPerBoostedShare).toBe((12n * p.rewardRate) / p.totalBoostedStake)
    expect(next.lastRewardTime).toBe(T0 + 12n)
  })

  it('stream into unallocatedRewards while nothing is staked', () => {
    const next = updatePool(pool({ totalBoostedStake: 0n }), T0 + 10n)
    expect(next.accRewardPerBoostedShare).toBe(0n)
    expect(next.unallocatedRewards).toBe(10n * pool().rewardRate)
  })

  it('stop at the end of the stream but still move lastRewardTime', () => {
    const p = pool({ rewardEndTime: T0 + 5n })
    const next = updatePool(p, T0 + 100n)
    expect(next.accRewardPerBoostedShare).toBe((5n * p.rewardRate) / p.totalBoostedStake)
    expect(next.lastRewardTime).toBe(T0 + 100n)
    expect(updatePool(next, T0 + 200n).accRewardPerBoostedShare).toBe(next.accRewardPerBoostedShare)
  })
})

describe('settlement and pending rewards', () => {
  it('settle rounds down and moves the snapshot', () => {
    const u = settle(user({ boostedBalance: 3n, accRewardSnapshot: 0n }), PRECISION / 2n)
    expect(u.storedRewards).toBe(1n)
    expect(u.accRewardSnapshot).toBe(PRECISION / 2n)
  })

  it('settle with no weight only moves the snapshot', () => {
    const u = settle(user({ accRewardSnapshot: 5n }), 9n)
    expect(u.storedRewards).toBe(0n)
    expect(u.accRewardSnapshot).toBe(9n)
  })

  it('pending is what a harvest at the same time pays', () => {
    const p = pool()
    const u = user({ boostedBalance: 250n * 10n ** 18n, storedRewards: 7n })
    const t = T0 + 3_600n
    expect(applyHarvest(p, u, t).rewards).toBe(pendingRewards(u, p, t))
  })
})

describe('stake, unstake and unlock times', () => {
  const epochs = { genesis: T0, duration: 86_400n }

  it('unlock at the next epoch start plus the lock', () => {
    expect(unlockTimeFor(epochs, 3_600n, T0)).toBe(T0 + 86_400n + 3_600n)
    expect(unlockTimeFor(epochs, 3_600n, T0 + 86_399n)).toBe(T0 + 86_400n + 3_600n)
    expect(unlockTimeFor(epochs, 3_600n, T0 + 86_400n)).toBe(T0 + 2n * 86_400n + 3_600n)
  })

  it('a stake settles first, then adds its boosted weight', () => {
    const p = pool()
    const u = user({ boostedBalance: 100n * 10n ** 18n, totalStakedDexy: 100n * 10n ** 18n, stakeCount: 1n })
    const level = { lockingPeriod: 86_400n, boostP: 8_500_000_000n, totalStaked: 0n }
    const t = T0 + 600n
    const out = applyStake(p, u, epochs, level, 10n ** 18n, t)
    expect(out.boosted).toBe(850_000_000_000_000_000n)
    expect(out.user.storedRewards).toBe(pendingRewards(u, p, t))
    expect(out.user.boostedBalance).toBe(u.boostedBalance + out.boosted)
    expect(out.pool.totalBoostedStake).toBe(p.totalBoostedStake + out.boosted)
    expect(out.unlockTime).toBe(T0 + 2n * 86_400n)
  })

  it('an unstake pays every accrued reward and removes the stake', () => {
    const p = pool()
    const u = user({ boostedBalance: 650n, totalStakedDexy: 1_000n, stakeCount: 1n, storedRewards: 3n })
    const s = { index: 0n, unstaked: false, level: 0, timestamp: T0, unlockTime: T0, stakedDexy: 1_000n, boostedAmount: 650n }
    const out = applyUnstake(p, u, s, T0 + 100n)
    expect(out.rewards).toBe(pendingRewards(u, p, T0 + 100n))
    expect(out.principal).toBe(1_000n)
    expect(out.user.boostedBalance).toBe(0n)
    expect(out.user.storedRewards).toBe(0n)
    expect(out.user.totalHarvestedRewards).toBe(out.rewards)
  })
})

describe('stream estimates', () => {
  it('rewardsOver is the weight share of the stream, cut at its end', () => {
    const p = pool()
    expect(rewardsOver(p, p.totalBoostedStake, T0, 86_400n)).toBe((86_400n * p.rewardRate) / PRECISION)
    expect(rewardsOver(p, p.totalBoostedStake / 2n, p.rewardEndTime - 10n, 86_400n)).toBe(
      (10n * p.rewardRate) / (2n * PRECISION),
    )
    expect(rewardsOver(p, 1n, p.rewardEndTime, 86_400n)).toBe(0n)
  })

  it('unstreamed counts unallocated rewards and what is left of the stream', () => {
    const p = pool({ unallocatedRewards: 5n })
    expect(unstreamedScaled(p, p.rewardEndTime - 100n)).toBe(5n + 100n * p.rewardRate)
    expect(unstreamedScaled(p, p.rewardEndTime + 100n)).toBe(5n)
  })
})

describe('gas margin', () => {
  it('covers with its fixed part alone the 64,476 gas the estimate can miss', () => {
    expect(withGasMargin(0n)).toBeGreaterThan(64_476n)
    expect(withGasMargin(100_000n)).toBe(205_000n)
  })
})

describe('formatting', () => {
  it('names lock lengths', () => {
    expect(formatDuration(3_600n)).toBe('1 hour')
    expect(formatDuration(86_400n)).toBe('1 day')
    expect(formatDuration(14n * 86_400n)).toBe('14 days')
    expect(formatDuration(30n * 86_400n)).toBe('30 days')
  })

  it('counts down', () => {
    expect(countdown(90_061n)).toBe('1 d 1 h')
    expect(countdown(-5n)).toBe('0 s')
  })
})

describe('error messages', () => {
  const revert = (data: `0x${string}`, functionName = 'stake') =>
    new ContractFunctionRevertedError({ abi: stakingAbi, data, functionName })

  it('decode the staking errors by name', () => {
    const data = encodeErrorResult({ abi: stakingAbi, errorName: 'StakeStillLocked' })
    expect(describeError(revert(data, 'unstake'))).toMatch(/still locked/)
  })

  it('decode the string reverts of OpenZeppelin 4.9', () => {
    const errorString = parseAbi(['error Error(string)'])
    const data = encodeErrorResult({ abi: errorString, errorName: 'Error', args: ['ERC20: insufficient allowance'] })
    expect(describeError(revert(data))).toBe('The staking contract is not approved to move this much DEXY yet. Approve it first.')
  })
})
