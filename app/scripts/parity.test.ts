// Checks the app's math against the deployed contracts on a local anvil chain, to the wei.
// Run after ./scripts/local-chain.sh:  LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/parity.test.ts
// The suite moves the chain forward and reverts it to a snapshot at the end, so it can run again.
import { readFileSync } from 'node:fs'
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  http,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
} from 'viem'
import { foundry } from 'viem/chains'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createConfig } from 'wagmi'
import { withGasMargin } from '../src/hooks/useTx'
import { waitForOutcome } from '../src/lib/receipt'
import { faucetAbi, stakingAbi, tokenAbi } from '../src/lib/abi'
import {
  PRECISION,
  applyDeposit,
  applyHarvest,
  applyStake,
  applyUnstake,
  boostedAmount,
  pendingRewards,
  unlockTimeFor,
  unstreamedScaled,
  type Epochs,
  type Level,
  type Pool,
  type StakeInfo,
  type UserState,
} from '../src/lib/staking'

const rpc = process.env.LOCAL_RPC
// anvil's default accounts 0 (the deployer) and 1 to 4, unlocked on a local node
const deployer = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address
const alice = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
const bob = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address
const carol = '0x90F79bf6EB2c4f870365E785982E1f101E93b906' as Address
const dave = '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65' as Address
// anvil's account 5, the faucet's feeder in scripts/local-chain.sh
const feeder = '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc' as Address

interface LocalDeployment {
  staking: Address
  faucet: Address
  dexy: Address
  rewardToken: Address
}

describe.skipIf(!rpc)('parity with the contracts on a local chain', { timeout: 30_000 }, () => {
  // Read lazily: the local deployment file is not committed, and a skipped suite still gets collected.
  let d: LocalDeployment
  let epochs: Epochs
  let snapshot: Hex
  // viem polls every 4 seconds by default; anvil can return a hash just before it mines the block, so a receipt wait
  // could take that long and the tests with several transactions would run past their timeout
  const pub = createPublicClient({ chain: foundry, transport: http(rpc), pollingInterval: 100 })
  const wallet = createWalletClient({ chain: foundry, transport: http(rpc), pollingInterval: 100 })

  beforeAll(async () => {
    d = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
    snapshot = await pub.request({ method: 'evm_snapshot' as never })
    const [genesis, duration] = await Promise.all([
      pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'I_GENESIS_EPOCH_TIMESTAMP' }),
      pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'epochDuration' }),
    ])
    epochs = { genesis: BigInt(genesis), duration: BigInt(duration) }
    for (const account of [alice, bob]) {
      await send(account, d.faucet, faucetAbi, 'claim', [])
      await send(account, d.dexy, tokenAbi, 'approve', [d.staking, 2n ** 255n])
    }
  })

  afterAll(async () => {
    if (snapshot) await pub.request({ method: 'evm_revert' as never, params: [snapshot] as never })
  })

  const latestTime = async () => (await pub.getBlock()).timestamp
  const pinNext = (t: bigint) => pub.request({ method: 'evm_setNextBlockTimestamp' as never, params: [Number(t)] as never })

  /** Sends a call from an unlocked account, at a pinned timestamp if given, and returns its receipt. */
  async function send(from: Address, address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[], at?: bigint, gas = 3_000_000n) {
    if (at !== undefined) await pinNext(at)
    const hash = await wallet.writeContract({ account: from, address, abi: abi as Abi, functionName, args, gas } as never)
    const receipt = await pub.waitForTransactionReceipt({ hash })
    expect(receipt.status, `${functionName} from ${from}`).toBe('success')
    return receipt
  }

  /** Mines an empty block at t, so views run at that timestamp. */
  async function mineAt(t: bigint) {
    await pinNext(t)
    await pub.request({ method: 'evm_mine' as never })
  }

  async function readPool(): Promise<Pool> {
    const read = (functionName: string) => pub.readContract({ address: d.staking, abi: stakingAbi, functionName } as never) as Promise<bigint | number>
    const [rewardRate, total, acc, unallocated, last, next, queued, duration] = await Promise.all(
      [
        'rewardRate',
        'totalBoostedStake',
        'accRewardPerBoostedShare',
        'unallocatedRewards',
        'lastRewardTime',
        'nextEpochStart',
        'queuedRewards',
        'epochDuration',
      ].map(read),
    )
    return {
      rewardRate: BigInt(rewardRate),
      totalBoostedStake: BigInt(total),
      accRewardPerBoostedShare: BigInt(acc),
      unallocatedRewards: BigInt(unallocated),
      lastRewardTime: BigInt(last),
      nextEpochStart: BigInt(next),
      queuedRewards: BigInt(queued),
      epochDuration: BigInt(duration),
    }
  }

  async function readUser(account: Address): Promise<UserState> {
    const u = await pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'users', args: [account] })
    return {
      stakeCount: BigInt(u[0]),
      storedRewards: BigInt(u[1]),
      totalStakedDexy: BigInt(u[2]),
      boostedBalance: BigInt(u[3]),
      totalHarvestedRewards: BigInt(u[4]),
      accRewardSnapshot: BigInt(u[5]),
    }
  }

  async function readStake(account: Address, index: bigint): Promise<StakeInfo> {
    const s = await pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'stakeInfo', args: [account, index] })
    return {
      index,
      unstaked: s[0],
      level: Number(s[1]),
      timestamp: BigInt(s[2]),
      unlockTime: BigInt(s[3]),
      stakedDexy: BigInt(s[4]),
      boostedAmount: BigInt(s[5]),
    }
  }

  async function readLevel(i: number): Promise<Level> {
    const levels = await pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'getLevels' })
    const l = levels[i]
    return { lockingPeriod: BigInt(l.lockingPeriod), boostP: BigInt(l.boostP), totalStaked: BigInt(l.totalStaked) }
  }

  const usdcOf = (account: Address) => pub.readContract({ address: d.rewardToken, abi: tokenAbi, functionName: 'balanceOf', args: [account] })
  const dexyOf = (account: Address) => pub.readContract({ address: d.dexy, abi: tokenAbi, functionName: 'balanceOf', args: [account] })

  /** Stakes at a pinned time and checks the pool, the user and the new stake against applyStake. */
  async function stakeAndCheck(account: Address, amount: bigint, levelIndex: number, at: bigint) {
    const [pool, user, level] = await Promise.all([readPool(), readUser(account), readLevel(levelIndex)])
    const expected = applyStake(pool, user, level, amount, at)
    await send(account, d.staking, stakingAbi, 'stake', [amount, levelIndex], at)
    expect(await readPool()).toEqual(expected.pool)
    expect(await readUser(account)).toEqual(expected.user)
    const s = await readStake(account, user.stakeCount)
    expect(s.boostedAmount).toBe(expected.boosted)
    expect(s.unlockTime).toBe(expected.unlockTime)
    return s
  }

  it('stakes leave the state the app predicts, at every level', async () => {
    let t = (await latestTime()) + 37n
    const amounts = [1_234_567_890_123_456_789n, 3n, 999_999_999_999_999_999_999n, 7n * 10n ** 17n, 11n]
    for (let i = 0; i < amounts.length; i++) {
      await stakeAndCheck(i % 2 === 0 ? alice : bob, amounts[i], i, t)
      t += 13n + BigInt(i) * 101n
    }
  })

  it('a stake whose weight rounds to zero reverts, as the app predicts', async () => {
    const level = await readLevel(0)
    expect(boostedAmount(1n, level.boostP)).toBe(0n)
    try {
      await pub.simulateContract({ account: alice, address: d.staking, abi: stakingAbi, functionName: 'stake', args: [1n, 0] })
      expect.unreachable('stake of 1 wei at level 0 should revert')
    } catch (err) {
      const reverted = (err as BaseError).walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError
      expect(reverted.data?.errorName).toBe('ZeroBoostedStake')
    }
  })

  it('pending rewards match the view at many timestamps', async () => {
    let t = await latestTime()
    for (const step of [1n, 2n, 12n, 599n, 3_601n, 86_399n]) {
      t += step
      await mineAt(t)
      const [pool, a, b] = await Promise.all([readPool(), readUser(alice), readUser(bob)])
      for (const [account, user] of [[alice, a], [bob, b]] as const) {
        const view = await pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'pendingRewards', args: [account] })
        expect(pendingRewards(user, pool, t)).toBe(view)
      }
    }
  })

  it('harvest pays what the app predicts', async () => {
    const t = (await latestTime()) + 61n
    const [pool, user, before] = await Promise.all([readPool(), readUser(bob), usdcOf(bob)])
    const expected = applyHarvest(pool, user, t)
    await send(bob, d.staking, stakingAbi, 'harvest', [], t)
    expect((await usdcOf(bob)) - before).toBe(expected.rewards)
    expect(await readUser(bob)).toEqual(expected.user)
    expect(await readPool()).toEqual(expected.pool)
  })

  it('stakes on both sides of an epoch turn leave the state the app predicts, with locks counted from the stake', async () => {
    // A deposit for the next epoch first, so the turn has a queue to start streaming
    await depositAndCheck(bob, 100n * 10n ** 6n, (await latestTime()) + 5n)
    const level = await readLevel(1)
    const now = await latestTime()
    const next = now < epochs.genesis ? epochs.genesis : epochs.genesis + ((now - epochs.genesis) / epochs.duration + 1n) * epochs.duration
    const before = await stakeAndCheck(alice, 10n ** 18n, 1, next - 1n)
    expect(before.unlockTime).toBe(unlockTimeFor(level.lockingPeriod, next - 1n))
    const after = await stakeAndCheck(alice, 10n ** 18n, 1, next)
    expect(after.unlockTime).toBe(next + level.lockingPeriod)
  })

  it('unstake returns the principal and pays what the app predicts', async () => {
    const s = await readStake(alice, 0n)
    const t = s.unlockTime > (await latestTime()) ? s.unlockTime : (await latestTime()) + 1n
    const [pool, user, usdc, dexy] = await Promise.all([readPool(), readUser(alice), usdcOf(alice), dexyOf(alice)])
    const expected = applyUnstake(pool, user, s, t)
    await send(alice, d.staking, stakingAbi, 'unstake', [0n], t)
    expect((await usdcOf(alice)) - usdc).toBe(expected.rewards)
    expect((await dexyOf(alice)) - dexy).toBe(expected.principal)
    expect(await readUser(alice)).toEqual(expected.user)
    expect(await readPool()).toEqual(expected.pool)
  })

  it('the gas margin covers a call estimated right after another call updated the pool', async () => {
    // Bob's harvest updates the pool in the latest block; Alice's stake is estimated against that block
    const t = (await latestTime()) + 30n
    await send(bob, d.staking, stakingAbi, 'harvest', [], t)
    const data = encodeFunctionData({ abi: stakingAbi, functionName: 'stake', args: [10n ** 18n, 0] })
    const estimate = await pub.estimateGas({ account: alice, to: d.staking, data, blockTag: 'latest' })
    await pinNext(t + 2n)
    const hash = await wallet.sendTransaction({ account: alice, to: d.staking, data, gas: withGasMargin(estimate), chain: foundry })
    const receipt = await pub.waitForTransactionReceipt({ hash })
    expect(receipt.status).toBe('success')
    expect(receipt.gasUsed).toBeLessThanOrEqual(withGasMargin(estimate))
  })

  it('the gas margin covers an unstake estimated right after the caller harvested in the same block', async () => {
    // A fresh account with one stake. The estimate pays nothing, since the harvest emptied storedRewards; the
    // landing pays, transfers and emits
    let t = (await latestTime()) + 30n
    await send(carol, d.faucet, faucetAbi, 'claim', [], t)
    await send(carol, d.dexy, tokenAbi, 'approve', [d.staking, 1_000n * 10n ** 18n])
    await send(carol, d.staking, stakingAbi, 'stake', [1_000n * 10n ** 18n, 0])
    t = (await readStake(carol, 0n)).unlockTime + 5n
    await send(carol, d.staking, stakingAbi, 'harvest', [], t)
    const data = encodeFunctionData({ abi: stakingAbi, functionName: 'unstake', args: [0n] })
    // At the latest block, as a node that estimates there does: anvil's default estimate runs one second later
    const estimate = await pub.estimateGas({ account: carol, to: d.staking, data, blockTag: 'latest' })
    await pinNext(t + 2n)
    const hash = await wallet.sendTransaction({ account: carol, to: d.staking, data, gas: withGasMargin(estimate), chain: foundry })
    const receipt = await pub.waitForTransactionReceipt({ hash })
    expect(receipt.status, `estimate ${estimate}, limit ${withGasMargin(estimate)}, used ${receipt.gasUsed}`).toBe('success')
  })

  it('a transaction that reverts when it lands is reported as reverted, not as unknown', async () => {
    const config = createConfig({ chains: [foundry], transports: { [foundry.id]: http(rpc) }, pollingInterval: 100 })
    // Sent with a fixed gas limit, so the node does not refuse it: dave has no stake, so harvest reverts
    const data = encodeFunctionData({ abi: stakingAbi, functionName: 'harvest' })
    const hash = await wallet.sendTransaction({ account: dave, to: d.staking, data, gas: 200_000n, chain: foundry })
    expect(await waitForOutcome(config, hash)).toBe('reverted')
  })

  /** An account approves and deposits at a pinned time; the pool must be what applyDeposit predicts. */
  async function depositAndCheck(from: Address, amount: bigint, at: bigint) {
    await send(from, d.rewardToken, tokenAbi, 'approve', [d.staking, amount])
    const before = await readPool()
    await send(from, d.staking, stakingAbi, 'addStakingReward', [amount], at)
    expect(await readPool()).toEqual(applyDeposit(before, amount, at))
  }

  it('a deposit by any account leaves the pool the app predicts', async () => {
    await depositAndCheck(alice, 12_345_678n, (await latestTime()) + 41n)
  })

  it("the feeder's funding through the faucet leaves the pool the app predicts", async () => {
    const amount = 987_654_321n
    const at = (await latestTime()) + 23n
    const before = await readPool()
    await send(feeder, d.faucet, faucetAbi, 'fundRewards', [d.staking, amount], at)
    expect(await readPool()).toEqual(applyDeposit(before, amount, at))
    expect(await pub.readContract({ address: d.faucet, abi: faucetAbi, functionName: 'lastFundedAt' })).toBe(Number(at))
  })

  it('pending rewards match the view across the epochs that stream what is queued and the empty ones after', async () => {
    const pool = await readPool()
    const end = pool.nextEpochStart + pool.epochDuration
    for (const t of [pool.nextEpochStart + 1n, end - 1n, end + 1_000n, end + 3n * pool.epochDuration]) {
      await mineAt(t)
      const user = await readUser(bob)
      const view = await pub.readContract({ address: d.staking, abi: stakingAbi, functionName: 'pendingRewards', args: [bob] })
      expect(pendingRewards(user, pool, t)).toBe(view)
    }
  })

  it('the unstreamed figure is what a migration moves', async () => {
    const requested = (await latestTime()) + 5n
    await send(deployer, d.staking, stakingAbi, 'requestMigration', [deployer], requested)
    // A deposit a minute before the migration, checked against the app, so its rewards are still queued when it runs
    const t = requested + 30n * 86_400n + 7n
    await depositAndCheck(bob, 200n * 10n ** 6n, t - 60n)
    const pool = await readPool()
    expect(unstreamedScaled(pool, t)).toBeGreaterThanOrEqual(200n * 10n ** 6n * PRECISION)
    const receipt = await send(deployer, d.staking, stakingAbi, 'executeMigration', [], t)
    const [event] = parseEventLogs({ abi: stakingAbi, logs: receipt.logs, eventName: 'RewardTokenMigrationSuccess' })
    expect(event.args.amount).toBe(unstreamedScaled(pool, t) / PRECISION)
  })
})
