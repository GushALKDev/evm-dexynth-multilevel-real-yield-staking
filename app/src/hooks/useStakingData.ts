import { useMemo } from 'react'
import type { Abi, Address } from 'viem'
import { useBalance, useReadContracts } from 'wagmi'
import { deployment } from '../config/chain'
import type { Deployment } from '../config/deployment'
import { faucetAbi, stakingAbi, tokenAbi } from '../lib/abi'
import type { Level, Pool, StakeInfo, UserState } from '../lib/staking'

export interface StaticData {
  epochDuration: bigint
  genesis: bigint
  drip: bigint
  /** USDC a claim hands out to the owner only */
  ownerDrip: bigint
  cooldown: bigint
  migrationDelay: bigint
  migrationWindow: bigint
}

export interface LiveData {
  pool: Pool
  levels: Level[]
  totalRewardsFunded: bigint
  migrated: boolean
  migrationRequestTime: bigint
  pendingMigrationAddress: Address
  owner: Address
  /** DEXY the faucet contract staked to seed the pool, which it cannot unstake */
  faucetStaked: bigint
}

export interface AccountData {
  user: UserState
  /** The pool as of the same block as the user, read in the same call: the account's figures need both together */
  pool: Pool
  stakes: StakeInfo[]
  wallet: { dexy: bigint; reward: bigint; eth: bigint | undefined }
  allowance: bigint
  /** USDC the staking contract may pull from the account, which a funding by the owner needs */
  rewardAllowance: bigint
  nextClaimAt: bigint
}

const REFRESH_MS = 6_000

interface Read {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
}

const asReads = (reads: unknown[]) => reads as Read[]

interface ReadQuery {
  enabled?: boolean
  staleTime?: number
  refetchInterval?: number
  placeholderData?: <T>(previous: T) => T
}

function useReads(contracts: Read[], query: ReadQuery) {
  const res = useReadContracts({ allowFailure: false, contracts: contracts as never, query })
  return { ...res, data: res.data as unknown as readonly unknown[] | undefined }
}

function useStatic(d: Deployment) {
  const res = useReads(
    asReads([
      { address: d.staking, abi: stakingAbi, functionName: 'epochDuration' },
      { address: d.staking, abi: stakingAbi, functionName: 'I_GENESIS_EPOCH_TIMESTAMP' },
      { address: d.faucet, abi: faucetAbi, functionName: 'DEXY_DRIP' },
      { address: d.faucet, abi: faucetAbi, functionName: 'COOLDOWN' },
      { address: d.staking, abi: stakingAbi, functionName: 'MIGRATION_DELAY' },
      { address: d.staking, abi: stakingAbi, functionName: 'MIGRATION_WINDOW' },
      { address: d.faucet, abi: faucetAbi, functionName: 'OWNER_USDC_DRIP' },
    ]),
    { staleTime: Infinity },
  )
  const data = useMemo((): StaticData | undefined => {
    const r = res.data
    if (!r) return undefined
    return {
      epochDuration: BigInt(r[0] as number),
      genesis: BigInt(r[1] as number),
      drip: r[2] as bigint,
      cooldown: r[3] as bigint,
      migrationDelay: BigInt(r[4] as number),
      migrationWindow: BigInt(r[5] as number),
      ownerDrip: r[6] as bigint,
    }
  }, [res.data])
  return { ...res, data }
}

const POOL_READS = [
  'rewardRate',
  'totalBoostedStake',
  'accRewardPerBoostedShare',
  'unallocatedRewards',
  'lastRewardTime',
  'rewardEndTime',
] as const

function toPool(r: readonly unknown[]): Pool {
  return {
    rewardRate: r[0] as bigint,
    totalBoostedStake: r[1] as bigint,
    accRewardPerBoostedShare: r[2] as bigint,
    unallocatedRewards: r[3] as bigint,
    lastRewardTime: BigInt(r[4] as number),
    rewardEndTime: BigInt(r[5] as number),
  }
}

function useLive(d: Deployment) {
  const read = (functionName: string) => ({ address: d.staking, abi: stakingAbi, functionName })
  const res = useReads(
    asReads([
      ...POOL_READS.map(read),
      read('getLevels'),
      read('totalRewardsFunded'),
      read('migrated'),
      read('migrationRequestTime'),
      read('pendingMigrationAddress'),
      read('owner'),
      { address: d.staking, abi: stakingAbi, functionName: 'users', args: [d.faucet] },
    ]),
    { refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): LiveData | undefined => {
    const r = res.data
    if (!r) return undefined
    const levels = r[6] as readonly { lockingPeriod: number; boostP: bigint; totalStaked: bigint }[]
    return {
      pool: toPool(r),
      levels: levels.map((l) => ({ lockingPeriod: BigInt(l.lockingPeriod), boostP: BigInt(l.boostP), totalStaked: BigInt(l.totalStaked) })),
      totalRewardsFunded: BigInt(r[7] as bigint),
      migrated: r[8] as boolean,
      migrationRequestTime: BigInt(r[9] as number),
      pendingMigrationAddress: r[10] as Address,
      owner: r[11] as Address,
      faucetStaked: BigInt((r[12] as readonly bigint[])[2]),
    }
  }, [res.data])
  return { ...res, data }
}

function useAccount(d: Deployment, account: Address | undefined) {
  const user = account ?? '0x0000000000000000000000000000000000000000'
  const eth = useBalance({ address: account, query: { enabled: !!account, refetchInterval: REFRESH_MS } })
  const reads = useReads(
    asReads([
      { address: d.staking, abi: stakingAbi, functionName: 'users', args: [user] },
      { address: d.dexy.address, abi: tokenAbi, functionName: 'balanceOf', args: [user] },
      { address: d.reward.address, abi: tokenAbi, functionName: 'balanceOf', args: [user] },
      { address: d.dexy.address, abi: tokenAbi, functionName: 'allowance', args: [user, d.staking] },
      { address: d.faucet, abi: faucetAbi, functionName: 'nextClaimAt', args: [user] },
      ...POOL_READS.map((functionName) => ({ address: d.staking, abi: stakingAbi, functionName })),
      { address: d.reward.address, abi: tokenAbi, functionName: 'allowance', args: [user, d.staking] },
    ]),
    { enabled: !!account, refetchInterval: REFRESH_MS },
  )
  const stakeCount = reads.data ? BigInt((reads.data[0] as readonly unknown[])[0] as bigint) : 0n
  // One read per stake the user ever made, open or not: stakes are indexed from 0 to stakeCount - 1
  const stakeReads = useReads(
    asReads(
      Array.from({ length: Number(stakeCount) }, (_, i) => ({
        address: d.staking,
        abi: stakingAbi,
        functionName: 'stakeInfo',
        args: [user, BigInt(i)],
      })),
    ),
    // A new stake changes the query, so keep the previous list on screen until the longer one arrives
    { enabled: !!account && stakeCount > 0n, refetchInterval: REFRESH_MS, placeholderData: (previous) => previous },
  )
  const data = useMemo((): AccountData | undefined => {
    const r = reads.data
    if (!r || !account) return undefined
    const stakesData = stakeReads.data
    if (stakeCount > 0n && !stakesData) return undefined
    const u = r[0] as readonly [bigint, bigint, bigint, bigint, bigint, bigint]
    const stakes = (stakesData ?? []).map((s, i) => {
      const [unstaked, level, timestamp, unlockTime, stakedDexy, boosted] = s as readonly [boolean, number, number, number, bigint, bigint]
      return {
        index: BigInt(i),
        unstaked,
        level: Number(level),
        timestamp: BigInt(timestamp),
        unlockTime: BigInt(unlockTime),
        stakedDexy: BigInt(stakedDexy),
        boostedAmount: BigInt(boosted),
      }
    })
    return {
      user: {
        stakeCount: BigInt(u[0]),
        storedRewards: BigInt(u[1]),
        totalStakedDexy: BigInt(u[2]),
        boostedBalance: BigInt(u[3]),
        totalHarvestedRewards: BigInt(u[4]),
        accRewardSnapshot: BigInt(u[5]),
      },
      stakes,
      // Unknown while loading, so the interface does not flash a no-gas warning
      wallet: { dexy: r[1] as bigint, reward: r[2] as bigint, eth: eth.data?.value },
      allowance: r[3] as bigint,
      nextClaimAt: r[4] as bigint,
      pool: toPool(r.slice(5, 5 + POOL_READS.length)),
      rewardAllowance: r[5 + POOL_READS.length] as bigint,
    }
  }, [reads.data, stakeReads.data, stakeCount, account, eth.data?.value])
  return { data, isLoading: reads.isLoading, error: reads.error ?? stakeReads.error }
}

export function useStakingData(account: Address | undefined) {
  const d = deployment as Deployment
  const st = useStatic(d)
  const live = useLive(d)
  const acc = useAccount(d, account)
  return {
    deployment: d,
    static: st.data,
    live: live.data,
    account: acc.data,
    error: st.error ?? live.error ?? acc.error,
    isLoading: st.isLoading || live.isLoading,
  }
}
