import { ContractFunctionRevertedError, encodeErrorResult, parseAbi } from 'viem'
import { describe, expect, it } from 'vitest'
import { withGasMargin } from '../hooks/useTx'
import { stakingAbi } from './abi'
import { describeError } from './errors'
import { countdown, formatDuration } from './format'
import {
  PRECISION,
  applyDeposit,
  applyHarvest,
  applyStake,
  applyUnstake,
  boostedAmount,
  pendingRewards,
  ratePerDayAt,
  rewardsOver,
  settle,
  streamedOverDay,
  unlockTimeFor,
  unstreamedScaled,
  updatePool,
  type Pool,
  type UserState,
} from './staking'

const T0 = 1_800_000_000n
const DAY = 86_400n
const EPOCH = 7n * DAY
// The epoch running at T0 ends in 3 days and streams 1,000 USDC over its 7; 2,000 USDC are queued for the next one
const NEXT = T0 + 3n * DAY
const RATE = (1_000n * 10n ** 6n * PRECISION) / EPOCH
const QUEUED = 2_000n * 10n ** 6n * PRECISION
const pool = (over: Partial<Pool> = {}): Pool => ({
  rewardRate: RATE,
  totalBoostedStake: 1_000n * 10n ** 18n,
  accRewardPerBoostedShare: 0n,
  unallocatedRewards: 0n,
  lastRewardTime: T0,
  nextEpochStart: NEXT,
  queuedRewards: QUEUED,
  epochDuration: EPOCH,
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

  it('add elapsed * rate / total to the accumulator within the epoch, rounded down', () => {
    const p = pool()
    const next = updatePool(p, T0 + 12n)
    expect(next.accRewardPerBoostedShare).toBe((12n * RATE) / p.totalBoostedStake)
    expect(next.lastRewardTime).toBe(T0 + 12n)
    expect(next.nextEpochStart).toBe(NEXT)
    expect(next.queuedRewards).toBe(QUEUED)
  })

  it('stream into unallocatedRewards while nothing is staked', () => {
    const next = updatePool(pool({ totalBoostedStake: 0n }), T0 + 10n)
    expect(next.accRewardPerBoostedShare).toBe(0n)
    expect(next.unallocatedRewards).toBe(10n * RATE)
  })

  it('move into the next epoch, which streams what was queued for it', () => {
    const p = pool()
    const next = updatePool(p, NEXT + 10n)
    const queuedRate = QUEUED / EPOCH
    expect(next.accRewardPerBoostedShare).toBe((3n * DAY * RATE + 10n * queuedRate) / p.totalBoostedStake)
    expect(next.rewardRate).toBe(queuedRate)
    expect(next.nextEpochStart).toBe(NEXT + EPOCH)
    expect(next.queuedRewards).toBe(0n)
  })

  it('stream the queued epoch in full and nothing after it when no update came in between', () => {
    const p = pool()
    const next = updatePool(p, NEXT + EPOCH + 5n * DAY)
    expect(next.accRewardPerBoostedShare).toBe((3n * DAY * RATE + EPOCH * (QUEUED / EPOCH)) / p.totalBoostedStake)
    expect(next.rewardRate).toBe(0n)
    expect(next.nextEpochStart).toBe(NEXT + 2n * EPOCH)
    expect(updatePool(next, NEXT + 5n * EPOCH).accRewardPerBoostedShare).toBe(next.accRewardPerBoostedShare)
  })

  it('stream nothing before epoch 0 starts, then its queued rewards', () => {
    const p = pool({ rewardRate: 0n, nextEpochStart: T0 + 600n })
    expect(updatePool(p, T0 + 599n).accRewardPerBoostedShare).toBe(0n)
    expect(updatePool(p, T0 + 610n).accRewardPerBoostedShare).toBe((10n * (QUEUED / EPOCH)) / p.totalBoostedStake)
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

  it('pending is what a harvest at the same time pays, across an epoch turn too', () => {
    const p = pool()
    const u = user({ boostedBalance: 250n * 10n ** 18n, storedRewards: 7n })
    for (const t of [T0 + 3_600n, NEXT + 3_600n]) expect(applyHarvest(p, u, t).rewards).toBe(pendingRewards(u, p, t))
  })
})

describe('stake, unstake and unlock times', () => {
  it('unlock the level lock after the stake, wherever it falls in its epoch', () => {
    expect(unlockTimeFor(3_600n, T0)).toBe(T0 + 3_600n)
    expect(unlockTimeFor(3_600n, NEXT - 1n)).toBe(NEXT - 1n + 3_600n)
  })

  it('a stake settles first, then adds its boosted weight', () => {
    const p = pool()
    const u = user({ boostedBalance: 100n * 10n ** 18n, totalStakedDexy: 100n * 10n ** 18n, stakeCount: 1n })
    const level = { lockingPeriod: DAY, boostP: 8_500_000_000n, totalStaked: 0n }
    const t = T0 + 600n
    const out = applyStake(p, u, level, 10n ** 18n, t)
    expect(out.boosted).toBe(850_000_000_000_000_000n)
    expect(out.user.storedRewards).toBe(pendingRewards(u, p, t))
    expect(out.user.boostedBalance).toBe(u.boostedBalance + out.boosted)
    expect(out.pool.totalBoostedStake).toBe(p.totalBoostedStake + out.boosted)
    expect(out.unlockTime).toBe(t + DAY)
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
  it('rewardsOver is the weight share of what the epochs stream, across a turn too', () => {
    const p = pool()
    expect(rewardsOver(p, p.totalBoostedStake, T0, DAY)).toBe((DAY * RATE) / PRECISION)
    expect(rewardsOver(p, p.totalBoostedStake / 2n, NEXT - 10n, DAY)).toBe(
      (10n * RATE + (DAY - 10n) * (QUEUED / EPOCH)) / (2n * PRECISION),
    )
    expect(rewardsOver(p, 1n, NEXT + EPOCH, DAY)).toBe(0n)
  })

  it('unstreamed counts unallocated rewards, the rest of the epoch and the queue', () => {
    const p = pool({ unallocatedRewards: 5n })
    expect(unstreamedScaled(p, NEXT - 100n)).toBe(5n + 100n * RATE + QUEUED)
    expect(unstreamedScaled(p, NEXT + 100n)).toBe(5n + (EPOCH - 100n) * (QUEUED / EPOCH))
    expect(unstreamedScaled(p, NEXT + EPOCH + 100n)).toBe(5n)
  })

  it('the day rate is that of the running epoch, 0 once nothing is queued', () => {
    const p = pool()
    expect(ratePerDayAt(p, T0 + 1n)).toBe((RATE * DAY) / PRECISION)
    expect(ratePerDayAt(p, NEXT + 1n)).toBe(((QUEUED / EPOCH) * DAY) / PRECISION)
    expect(ratePerDayAt(p, NEXT + EPOCH)).toBe(0n)
    expect(streamedOverDay(p, T0)).toBe((DAY * RATE) / PRECISION)
  })
})

describe('deposits', () => {
  it('join the queue of the next epoch with the unallocated rewards and leave the running epoch alone', () => {
    const p = pool({ unallocatedRewards: 7n })
    const t = T0 + 1_000n
    const out = applyDeposit(p, 5_000n * 10n ** 6n, t)
    expect(out.queuedRewards).toBe(QUEUED + 7n + 5_000n * 10n ** 6n * PRECISION)
    expect(out.unallocatedRewards).toBe(0n)
    expect(out.rewardRate).toBe(RATE)
    expect(out.nextEpochStart).toBe(NEXT)
    expect(out.accRewardPerBoostedShare).toBe(updatePool(p, t).accRewardPerBoostedShare)
    expect(out.lastRewardTime).toBe(t)
  })

  it('made once the next epoch has started, go to the one after it', () => {
    const out = applyDeposit(pool(), 10n ** 6n, NEXT)
    expect(out.rewardRate).toBe(QUEUED / EPOCH)
    expect(out.nextEpochStart).toBe(NEXT + EPOCH)
    expect(out.queuedRewards).toBe(10n ** 6n * PRECISION)
  })
})

describe('gas margin', () => {
  it('covers with its fixed part alone the 65,606 gas the estimate can miss', () => {
    expect(withGasMargin(0n)).toBeGreaterThan(65_606n)
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
    expect(describeError(revert(data))).toBe('The staking contract is not approved to move this amount yet. Approve it first.')
  })
})
