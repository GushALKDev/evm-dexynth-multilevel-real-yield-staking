import type { Deployment } from '../config/deployment'
import type { AccountData, LiveData, StaticData } from '../hooks/useStakingData'
import {
  PRECISION,
  boostedAmount,
  epochIndex,
  nextEpochStart,
  pendingRewards,
  rewardsOver,
  streamedOverDay,
  unstreamedScaled,
  type Epochs,
  type Level,
  type Pool,
  type StakeInfo,
  type UserState,
} from './staking'

/** Fractions are scaled by 1e18 */
export const ONE = 10n ** 18n
export const DAY = 86_400n
/** The amount the level table quotes daily rewards for */
export const QUOTE_DEXY = 1_000n * 10n ** 18n
/** How far past the latest block ticking figures may project: blocks arrive far more often, so only a fast clock gets here */
const MAX_AHEAD = 30n

export interface LevelView extends Level {
  index: number
  /** totalStaked * boostP / 1e10. Within a few wei of the sum of the stakes' rounded-down boosted amounts */
  weight: bigint
  /** weight / totalBoostedStake, 1e18 scale */
  share: bigint
  /** USDC units a day that QUOTE_DEXY staked now at this level would earn at today's pool, rounded down */
  perDayQuote: bigint
}

export interface AccountView {
  user: UserState
  /** The pool read together with the user, which every account figure and preview uses */
  pool: Pool
  /** Rewards accrued at the projected time, ticking every second */
  pending: bigint
  /** Rewards accrued at the latest block's timestamp, about what a harvest landing next pays */
  pendingAtChain: bigint
  open: StakeInfo[]
  closed: StakeInfo[]
  dexyByLevel: bigint[]
  boostedByLevel: bigint[]
  /** boostedBalance / totalBoostedStake, 1e18 scale */
  share: bigint
  /** USDC units a day at today's pool, rounded down */
  perDay: bigint
  data: AccountData
}

export interface StakingModel {
  deployment: Deployment
  static: StaticData
  live: LiveData
  pool: Pool
  epochs: Epochs
  /** Projected time: the visitor's clock, never behind the last pool update */
  now: bigint
  /** The latest block's timestamp: what the next call's simulation sees, and a floor for when it lands */
  chainTime: bigint
  epoch: bigint
  nextEpochAt: bigint
  levels: LevelView[]
  totalStaked: bigint
  stream: {
    perDay: bigint
    endTime: bigint
    active: boolean
    funded: bigint
    /** Rewards not streamed yet at `now`, in USDC units, rounded down */
    unstreamed: bigint
    /**
     * funded - unstreamed: streamed to stakers so far, ticking every second. Null after a migration, which moved an
     * amount the contract does not store
     */
    streamed: bigint | null
  }
  migrationPending: boolean
  account: AccountView | null
}

/**
 * The times the model projects to. `now` drives the figures that tick; `chainTime` is the latest block's timestamp,
 * which the next call's simulation sees and its landing cannot precede.
 */
export function projectionTimes(wallClock: bigint, latestBlock: bigint | undefined, lastRewardTime: bigint) {
  const chainTime = latestBlock && latestBlock > lastRewardTime ? latestBlock : lastRewardTime
  // Never project behind the chain if the visitor's clock runs slow: the figures would freeze until it caught up.
  // Nor far ahead of it if the clock runs fast: rewards would show what has not accrued yet
  const now = wallClock < chainTime ? chainTime : wallClock > chainTime + MAX_AHEAD ? chainTime + MAX_AHEAD : wallClock
  return { now, chainTime }
}

export function buildModel(
  d: Deployment,
  st: StaticData,
  live: LiveData,
  account: AccountData | undefined,
  now: bigint,
  chainTime: bigint,
): StakingModel {
  const pool = live.pool
  const epochs: Epochs = { genesis: st.genesis, duration: st.epochDuration }
  const total = pool.totalBoostedStake

  const levels: LevelView[] = live.levels.map((l, index) => {
    const weight = boostedAmount(l.totalStaked, l.boostP)
    const quoteWeight = boostedAmount(QUOTE_DEXY, l.boostP)
    const withQuote = { ...pool, totalBoostedStake: total + quoteWeight }
    return {
      ...l,
      index,
      weight,
      share: total > 0n ? (weight * ONE) / total : 0n,
      perDayQuote: rewardsOver(withQuote, quoteWeight, now, DAY),
    }
  })

  const unstreamed = unstreamedScaled(pool, now) / PRECISION
  const funded = live.totalRewardsFunded

  let accountView: AccountView | null = null
  if (account) {
    const u = account.user
    const own = account.pool
    const ownTotal = own.totalBoostedStake
    const dexyByLevel = levels.map(() => 0n)
    const boostedByLevel = levels.map(() => 0n)
    for (const s of account.stakes) {
      if (s.unstaked) continue
      dexyByLevel[s.level] += s.stakedDexy
      boostedByLevel[s.level] += s.boostedAmount
    }
    accountView = {
      user: u,
      pool: own,
      pending: pendingRewards(u, own, now),
      pendingAtChain: pendingRewards(u, own, chainTime),
      // Newest first: the stake just made is the one a visitor looks for
      open: account.stakes.filter((s) => !s.unstaked).reverse(),
      closed: account.stakes.filter((s) => s.unstaked).reverse(),
      dexyByLevel,
      boostedByLevel,
      share: ownTotal > 0n ? (u.boostedBalance * ONE) / ownTotal : 0n,
      perDay: rewardsOver(own, u.boostedBalance, now, DAY),
      data: account,
    }
  }

  return {
    deployment: d,
    static: st,
    live,
    pool,
    epochs,
    now,
    chainTime,
    epoch: epochIndex(epochs, now),
    nextEpochAt: nextEpochStart(epochs, now),
    levels,
    totalStaked: live.levels.reduce((sum, l) => sum + l.totalStaked, 0n),
    stream: {
      perDay: streamedOverDay(pool, now),
      endTime: pool.rewardEndTime,
      active: now < pool.rewardEndTime,
      funded,
      unstreamed,
      streamed: live.migrated ? null : funded > unstreamed ? funded - unstreamed : 0n,
    },
    // A request past its window can no longer be executed (MigrationExpired) and does not block a new one
    migrationPending:
      live.migrationRequestTime > 0n &&
      !live.migrated &&
      now <= live.migrationRequestTime + st.migrationDelay + st.migrationWindow,
    account: accountView,
  }
}
