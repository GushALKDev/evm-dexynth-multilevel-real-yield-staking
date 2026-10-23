// The staking contract's math, mirrored with the same scales and rounding (src/DexynthStaking.sol).
// scripts/parity.test.ts checks every function here against a local deployment, to the wei.

/** Scale of rewardRate, queuedRewards, unallocatedRewards and accRewardPerBoostedShare */
export const PRECISION = 10n ** 36n
/** Precision of a level's boostP: 1e10 is 1.0x */
export const BOOST_PRECISION = 10n ** 10n
/** Cap on the rewards funded over the life of the contract, type(uint128).max */
export const MAX_TOTAL_FUNDING = 2n ** 128n - 1n

export interface Level {
  lockingPeriod: bigint
  boostP: bigint
  totalStaked: bigint
}

/** The storage the reward accounting reads, as the contract holds it, plus its immutable epoch length */
export interface Pool {
  /** Rate until nextEpochStart, scaled by 1e36 */
  rewardRate: bigint
  totalBoostedStake: bigint
  accRewardPerBoostedShare: bigint
  unallocatedRewards: bigint
  lastRewardTime: bigint
  /** Start of the epoch after lastRewardTime, or of epoch 0 until it starts */
  nextEpochStart: bigint
  /** Rewards deposited for the epoch starting at nextEpochStart, scaled by 1e36 */
  queuedRewards: bigint
  epochDuration: bigint
}

export interface UserState {
  stakeCount: bigint
  storedRewards: bigint
  totalStakedDexy: bigint
  boostedBalance: bigint
  totalHarvestedRewards: bigint
  accRewardSnapshot: bigint
}

export interface StakeInfo {
  index: bigint
  unstaked: boolean
  level: number
  timestamp: bigint
  unlockTime: bigint
  stakedDexy: bigint
  boostedAmount: bigint
}

export interface Epochs {
  genesis: bigint
  duration: bigint
}

export const min = (a: bigint, b: bigint) => (a < b ? a : b)

/** a * b / d rounded down, as OpenZeppelin's Math.mulDiv for non-negative values */
export const mulDiv = (a: bigint, b: bigint, d: bigint) => (a * b) / d

/** A stake's weight: amount * boostP / 1e10, rounded down. stake() reverts with ZeroBoostedStake when it is 0 */
export function boostedAmount(amount: bigint, boostP: bigint): bigint {
  return (amount * boostP) / BOOST_PRECISION
}

/**
 * _streamedSinceUpdate at time t: the rewards streamed from lastRewardTime to t, scaled by 1e36, and the rate and next
 * epoch start that apply from t. The stored rate runs until nextEpochStart, then the queued rewards over the epoch
 * after it; nothing is queued past that.
 */
export function streamedSince(pool: Pool, t: bigint): { reward: bigint; rate: bigint; nextStart: bigint } {
  const last = pool.lastRewardTime
  if (t <= last) return { reward: 0n, rate: pool.rewardRate, nextStart: pool.nextEpochStart }
  if (t < pool.nextEpochStart) return { reward: (t - last) * pool.rewardRate, rate: pool.rewardRate, nextStart: pool.nextEpochStart }
  const duration = pool.epochDuration
  const rate = pool.queuedRewards / duration
  const end = pool.nextEpochStart + duration
  const reward = (pool.nextEpochStart - last) * pool.rewardRate
  if (t < end) return { reward: reward + (t - pool.nextEpochStart) * rate, rate, nextStart: end }
  return { reward: reward + duration * rate, rate: 0n, nextStart: end + ((t - end) / duration + 1n) * duration }
}

/**
 * _updatePool at time t: streams the rewards since lastRewardTime into the accumulator, or into unallocatedRewards
 * while nothing is staked, and moves to the next epoch when one has started. A time at or before lastRewardTime
 * changes nothing.
 */
export function updatePool(pool: Pool, t: bigint): Pool {
  if (t <= pool.lastRewardTime) return pool
  const { reward, rate, nextStart } = streamedSince(pool, t)
  let { accRewardPerBoostedShare: acc, unallocatedRewards: unallocated } = pool
  if (reward > 0n) {
    if (pool.totalBoostedStake === 0n) unallocated += reward
    else acc += reward / pool.totalBoostedStake
  }
  const moved = nextStart !== pool.nextEpochStart ? { rewardRate: rate, nextEpochStart: nextStart, queuedRewards: 0n } : {}
  return { ...pool, ...moved, accRewardPerBoostedShare: acc, unallocatedRewards: unallocated, lastRewardTime: t }
}

/** _settle: moves the rewards accrued since the user's snapshot into storedRewards, rounded down */
export function settle(user: UserState, acc: bigint): UserState {
  if (acc === user.accRewardSnapshot) return user
  const stored =
    user.boostedBalance > 0n
      ? user.storedRewards + mulDiv(user.boostedBalance, acc - user.accRewardSnapshot, PRECISION)
      : user.storedRewards
  return { ...user, storedRewards: stored, accRewardSnapshot: acc }
}

/** pendingRewards(user) as the view returns it at time t */
export function pendingRewards(user: UserState, pool: Pool, t: bigint): bigint {
  const acc = updatePool(pool, t).accRewardPerBoostedShare
  return user.storedRewards + mulDiv(user.boostedBalance, acc - user.accRewardSnapshot, PRECISION)
}

/** Index of the epoch t falls in, -1 before epoch 0 starts */
export function epochIndex(e: Epochs, t: bigint): bigint {
  return t < e.genesis ? -1n : (t - e.genesis) / e.duration
}

/** Start of the next epoch after t, or of epoch 0 before it starts */
export function nextEpochStart(e: Epochs, t: bigint): bigint {
  return e.genesis + (epochIndex(e, t) + 1n) * e.duration
}

/** unlockTime of a stake created at time t: the level's lock, counted from the stake */
export function unlockTimeFor(lockingPeriod: bigint, t: bigint): bigint {
  return t + lockingPeriod
}

export interface Outcome {
  pool: Pool
  user: UserState
}

/** stake(amount, level) landing at time t: the pool and the user afterwards, and the new stake */
export function applyStake(
  pool: Pool,
  user: UserState,
  level: Level,
  amount: bigint,
  t: bigint,
): Outcome & { boosted: bigint; unlockTime: bigint } {
  const boosted = boostedAmount(amount, level.boostP)
  const p = updatePool(pool, t)
  const u = settle(user, p.accRewardPerBoostedShare)
  return {
    pool: { ...p, totalBoostedStake: p.totalBoostedStake + boosted },
    user: {
      ...u,
      stakeCount: u.stakeCount + 1n,
      totalStakedDexy: u.totalStakedDexy + amount,
      boostedBalance: u.boostedBalance + boosted,
    },
    boosted,
    unlockTime: unlockTimeFor(level.lockingPeriod, t),
  }
}

/** unstake(index) landing at time t: the principal returned and every reward the user has accrued */
export function applyUnstake(pool: Pool, user: UserState, s: StakeInfo, t: bigint): Outcome & { rewards: bigint; principal: bigint } {
  const p = updatePool(pool, t)
  const u = settle(user, p.accRewardPerBoostedShare)
  return {
    pool: { ...p, totalBoostedStake: p.totalBoostedStake - s.boostedAmount },
    user: {
      ...u,
      storedRewards: 0n,
      totalStakedDexy: u.totalStakedDexy - s.stakedDexy,
      boostedBalance: u.boostedBalance - s.boostedAmount,
      totalHarvestedRewards: u.totalHarvestedRewards + u.storedRewards,
    },
    rewards: u.storedRewards,
    principal: s.stakedDexy,
  }
}

/** harvest() landing at time t: every reward the user has accrued */
export function applyHarvest(pool: Pool, user: UserState, t: bigint): Outcome & { rewards: bigint } {
  const p = updatePool(pool, t)
  const u = settle(user, p.accRewardPerBoostedShare)
  return {
    pool: p,
    user: { ...u, storedRewards: 0n, totalHarvestedRewards: u.totalHarvestedRewards + u.storedRewards },
    rewards: u.storedRewards,
  }
}

/**
 * Rewards not streamed yet at time t, scaled by 1e36: the rest of the current epoch, the queued deposits and the
 * unallocated rewards, what executeMigration would move. Not a payout
 */
export function unstreamedScaled(pool: Pool, t: bigint): bigint {
  const p = updatePool(pool, t)
  const ahead = p.nextEpochStart > t ? (p.nextEpochStart - t) * p.rewardRate : 0n
  return p.unallocatedRewards + p.queuedRewards + ahead
}

/** Rewards the pool streams between `from` and `to`, scaled by 1e36, from what is funded so far. `from` >= lastRewardTime */
export function streamedBetween(pool: Pool, from: bigint, to: bigint): bigint {
  if (to <= from) return 0n
  return streamedSince(pool, to).reward - streamedSince(pool, from).reward
}

/**
 * Rewards a boosted weight would earn over `seconds` from t if nobody else staked, left or deposited, rounded down: an
 * estimate for previews, not a contract figure. The weight is assumed to be part of totalBoostedStake already.
 */
export function rewardsOver(pool: Pool, boosted: bigint, t: bigint, seconds: bigint): bigint {
  if (pool.totalBoostedStake === 0n || boosted === 0n) return 0n
  return mulDiv(streamedBetween(pool, t, t + seconds), boosted, pool.totalBoostedStake * PRECISION)
}

/**
 * addStakingReward(amount) landing at time t: the pool moves to t, then the amount and the unallocated rewards join
 * the queue of the next epoch to start. The contract reverts on a zero amount, after a migration and past
 * MAX_TOTAL_FUNDING.
 */
export function applyDeposit(pool: Pool, amount: bigint, t: bigint): Pool {
  const p = updatePool(pool, t)
  return { ...p, queuedRewards: p.queuedRewards + p.unallocatedRewards + amount * PRECISION, unallocatedRewards: 0n }
}

/** Reward token units the pool pays out over the day from t, rounded down, whoever is staked */
export function streamedOverDay(pool: Pool, t: bigint): bigint {
  return streamedBetween(pool, t, t + 86_400n) / PRECISION
}

/** Reward token units a day the epoch running at t streams, rounded down. 0 before epoch 0 and in an unfunded epoch */
export function ratePerDayAt(pool: Pool, t: bigint): bigint {
  return (updatePool(pool, t).rewardRate * 86_400n) / PRECISION
}
