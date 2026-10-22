import { useEffect, useMemo, useState } from 'react'
import { useBlock, useConnection } from 'wagmi'
import { buildModel, projectionTimes, type StakingModel } from '../lib/model'
import { useStakingData } from './useStakingData'

/** Wall-clock seconds, ticking once a second so pending rewards move as they accrue. */
export function useNow(intervalMs = 1_000): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)))
  useEffect(() => {
    const id = window.setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
  return now
}

export function useModel(): { model: StakingModel | null; error: Error | null; isLoading: boolean } {
  const { address } = useConnection()
  const data = useStakingData(address)
  const now = useNow()
  // The latest block's timestamp: what the next call's simulation sees, and a floor for when it lands.
  const block = useBlock({ watch: true })
  const chainTime = block.data?.timestamp
  const model = useMemo(() => {
    if (!data.static || !data.live) return null
    const t = projectionTimes(now, chainTime, data.live.pool.lastRewardTime)
    return buildModel(data.deployment, data.static, data.live, data.account, t.now, t.chainTime)
  }, [data.deployment, data.static, data.live, data.account, now, chainTime])
  return { model, error: (data.error as Error | null) ?? null, isLoading: data.isLoading }
}
