import { describe, expect, it } from 'vitest'
import { EPOCH_MAX, EPOCH_MIN, dueDeposit, epochPlan } from './plan'

const DAY = 86_400n
const WEEK = 7n * DAY
const GENESIS = 1_800_000_000n

describe('the epoch plan', () => {
  it('deposits between 500 and 2,000 USDC an epoch, something every day, at an hour of the day', () => {
    for (let e = 0n; e < 1_000n; e++) {
      const plan = epochPlan(e, 7)
      const total = plan.reduce((sum, d) => sum + d.amount, 0n)
      expect(total).toBeGreaterThanOrEqual(EPOCH_MIN)
      expect(total).toBeLessThan(EPOCH_MAX)
      for (const d of plan) {
        expect(d.amount).toBeGreaterThan(0n)
        expect(d.hour).toBeGreaterThanOrEqual(0)
        expect(d.hour).toBeLessThan(24)
      }
    }
  })

  it('is the same on every run and differs between epochs', () => {
    expect(epochPlan(42n, 7)).toEqual(epochPlan(42n, 7))
    expect(epochPlan(42n, 7)).not.toEqual(epochPlan(43n, 7))
  })
})

describe('the deposit due', () => {
  const plan = epochPlan(3n, 7)[2]
  const dayStart = GENESIS + 3n * WEEK + 2n * DAY
  const at = dayStart + BigInt(plan.hour) * 3_600n

  it('is nothing before epoch 0 starts', () => {
    expect(dueDeposit(GENESIS, WEEK, GENESIS - 1n, 0n)).toBeNull()
  })

  it("is the day's amount from its hour on, until something is funded that day", () => {
    if (plan.hour > 0) expect(dueDeposit(GENESIS, WEEK, at - 1n, 0n)).toBeNull()
    expect(dueDeposit(GENESIS, WEEK, at, dayStart - 1n)).toEqual({ epoch: 3n, day: 2, amount: plan.amount })
    expect(dueDeposit(GENESIS, WEEK, dayStart + DAY - 1n, dayStart - 1n)).toEqual({ epoch: 3n, day: 2, amount: plan.amount })
    expect(dueDeposit(GENESIS, WEEK, at + 60n, at + 30n)).toBeNull()
  })

  it('is the next day as soon as that day begins and its hour comes', () => {
    const next = epochPlan(3n, 7)[3]
    const nextAt = dayStart + DAY + BigInt(next.hour) * 3_600n
    expect(dueDeposit(GENESIS, WEEK, nextAt, at)).toEqual({ epoch: 3n, day: 3, amount: next.amount })
  })
})
