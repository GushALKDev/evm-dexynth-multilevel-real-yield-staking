// The staking contract's math, mirrored with the same scales and rounding (src/DexynthStaking.sol).
// scripts/parity.test.ts checks every function here against a local deployment, to the wei.

/** Scale of rewardRate, unallocatedRewards and accRewardPerBoostedShare */
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

/** The storage the reward accounting reads, as the contract holds it */
export interface Pool {
  rewardRate: bigint
  totalBoostedStake: bigint
  accRewardPerBoostedShare: bigint
  unallocatedRewards: bigint
  lastRewardTime: bigint
  rewardEndTime: bigint
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
 * _updatePool at time t: streams the rewards since lastRewardTime, capped at rewardEndTime, into the accumulator,
 * or into unallocatedRewards while nothing is staked. A time at or before lastRewardTime changes nothing.
 */
export function updatePool(pool: Pool, t: bigint): Pool {
  if (t <= pool.lastRewardTime) return pool
  const end = min(t, pool.rewardEndTime)
  let { accRewardPerBoostedShare: acc, unallocatedRewards: unallocated } = pool
  if (end > pool.lastRewardTime) {
    const reward = (end - pool.lastRewardTime) * pool.rewardRate
    if (pool.totalBoostedStake === 0n) unallocated += reward
    else acc += reward / pool.totalBoostedStake
  }
  return { ...pool, accRewardPerBoostedShare: acc, unallocatedRewards: unallocated, lastRewardTime: t }
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

export function epochIndex(e: Epochs, t: bigint): bigint {
  return (t - e.genesis) / e.duration
}

export function nextEpochStart(e: Epochs, t: bigint): bigint {
  return e.genesis + (epochIndex(e, t) + 1n) * e.duration
}

/** unlockTime of a stake created at time t: the next epoch start plus the level's lock */
export function unlockTimeFor(e: Epochs, lockingPeriod: bigint, t: bigint): bigint {
  return nextEpochStart(e, t) + lockingPeriod
}

export interface Outcome {
  pool: Pool
  user: UserState
}

/** stake(amount, level) landing at time t: the pool and the user afterwards, and the new stake */
export function applyStake(
  pool: Pool,
  user: UserState,
  e: Epochs,
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
    unlockTime: unlockTimeFor(e, level.lockingPeriod, t),
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

/** Rewards not streamed yet at time t, scaled by 1e36: what executeMigration would move. Not a payout */
export function unstreamedScaled(pool: Pool, t: bigint): bigint {
  const p = updatePool(pool, t)
  const ahead = p.rewardEndTime > t ? (p.rewardEndTime - t) * p.rewardRate : 0n
  return p.unallocatedRewards + ahead
}

/**
 * Rewards a boosted weight would earn over `seconds` from t if nobody else staked or left, rounded down: an estimate
 * for previews, not a contract figure. The weight is assumed to be part of totalBoostedStake already.
 */
export function rewardsOver(pool: Pool, boosted: bigint, t: bigint, seconds: bigint): bigint {
  if (pool.totalBoostedStake === 0n || boosted === 0n) return 0n
  const end = min(t + seconds, pool.rewardEndTime)
  if (end <= t) return 0n
  return mulDiv((end - t) * pool.rewardRate, boosted, pool.totalBoostedStake * PRECISION)
}

/**
 * addStakingReward(amount, duration) landing at time t: the unstreamed rewards plus `amount` spread over `duration`.
 * Owner only on the contract, which also reverts on a zero duration, after a migration and past MAX_TOTAL_FUNDING.
 */
export function applyFunding(pool: Pool, amount: bigint, duration: bigint, t: bigint): Pool {
  const leftover = unstreamedScaled(pool, t)
  const p = updatePool(pool, t)
  return {
    ...p,
    rewardRate: (leftover + amount * PRECISION) / duration,
    rewardEndTime: t + duration,
    unallocatedRewards: 0n,
  }
}

/** Reward token units the stream pays out over the day from t, rounded down, whoever is staked */
export function streamedOverDay(pool: Pool, t: bigint): bigint {
  if (t >= pool.rewardEndTime) return 0n
  return ((min(pool.rewardEndTime, t + 86_400n) - t) * pool.rewardRate) / PRECISION
}
