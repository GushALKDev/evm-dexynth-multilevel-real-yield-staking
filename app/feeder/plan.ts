// The feeder's plan: how much USDC it deposits on each day of an epoch, and from what hour. It is derived from the
// epoch index alone, so the Worker keeps no state: every hourly run recomputes the same plan and checks the faucet's
// lastFundedAt to know whether today's deposit is already done.
import { keccak256, toHex } from 'viem'

/** USDC units the feeder deposits over one epoch, at least: 500 USDC */
export const EPOCH_MIN = 500_000_000n
/** USDC units the feeder deposits over one epoch, at most: 2,000 USDC */
export const EPOCH_MAX = 2_000_000_000n

const DAY = 86_400n
const HOUR = 3_600n

export interface DayPlan {
  /** USDC units to deposit that day */
  amount: bigint
  /** Hours into the day from which the deposit is due, 0 to 23 */
  hour: number
}

export interface Due {
  epoch: bigint
  day: number
  amount: bigint
}

/** Uniform in [0, 1), the same for the same epoch and draw on every run */
function draw(epoch: bigint, n: number): number {
  return Number(BigInt(keccak256(toHex(`dexynth-feeder:${epoch}:${n}`))) >> 203n) / 2 ** 53
}

/**
 * The deposits of one epoch: a total drawn between EPOCH_MIN and EPOCH_MAX, split over its days with weights between
 * 0.5 and 1.5 so that every day deposits something, each at an hour drawn between 0 and 23.
 */
export function epochPlan(epoch: bigint, days: number): DayPlan[] {
  const total = EPOCH_MIN + BigInt(Math.floor(draw(epoch, 0) * Number(EPOCH_MAX - EPOCH_MIN)))
  const weights = Array.from({ length: days }, (_, d) => 500_000n + BigInt(Math.floor(draw(epoch, 1 + d) * 1_000_000)))
  const sum = weights.reduce((a, b) => a + b, 0n)
  const amounts = weights.map((w) => (total * w) / sum)
  // The last day takes the rounding, so the days add up to the total exactly
  amounts[days - 1] = total - amounts.slice(0, -1).reduce((a, b) => a + b, 0n)
  return amounts.map((amount, d) => ({ amount, hour: Math.floor(draw(epoch, 1 + days + d) * 24) }))
}

/**
 * The deposit due at chain time `now`, or null: the day's planned amount once its hour has come, unless the faucet
 * recorded a funding since the day began. Days count from the start of each epoch. A missed day is not made up.
 */
export function dueDeposit(genesis: bigint, duration: bigint, now: bigint, lastFundedAt: bigint): Due | null {
  if (now < genesis) return null
  const epoch = (now - genesis) / duration
  const day = (now - genesis - epoch * duration) / DAY
  const days = Number(duration / DAY)
  if (Number(day) >= days) return null
  const dayStart = genesis + epoch * duration + day * DAY
  const plan = epochPlan(epoch, days)[Number(day)]
  if ((now - dayStart) / HOUR < BigInt(plan.hour) || lastFundedAt >= dayStart) return null
  return { epoch, day: Number(day), amount: plan.amount }
}
