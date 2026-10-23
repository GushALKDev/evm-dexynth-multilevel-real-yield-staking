// The demo's scheduled depositor, a Cloudflare Worker with an hourly cron trigger. It plays the platform that earns the
// yield: once a day it deposits that day's planned USDC through TestnetFaucet.fundRewards, streamed over the next
// epoch. Setup and local rehearsal: app/README.md.
import { createPublicClient, createWalletClient, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import deployment from '../src/config/deployments/84532.json'
import { faucetAbi, stakingAbi } from '../src/lib/abi'
import { dueDeposit } from './plan'

interface Env {
  /** The feeder's key, a Worker secret */
  FEEDER_PRIVATE_KEY: Hex
  RPC_URL: string
  /** Overrides of the deployment file, for a rehearsal on a local chain */
  STAKING_ADDRESS?: Address
  FAUCET_ADDRESS?: Address
}

export default {
  async scheduled(_controller: unknown, env: Env): Promise<void> {
    const staking = env.STAKING_ADDRESS ?? (deployment.staking as Address)
    const faucet = env.FAUCET_ADDRESS ?? (deployment.faucet as Address)
    const transport = http(env.RPC_URL)
    const pub = createPublicClient({ transport })

    const [genesis, duration, lastFundedAt, block] = await Promise.all([
      pub.readContract({ address: staking, abi: stakingAbi, functionName: 'I_GENESIS_EPOCH_TIMESTAMP' }),
      pub.readContract({ address: staking, abi: stakingAbi, functionName: 'epochDuration' }),
      pub.readContract({ address: faucet, abi: faucetAbi, functionName: 'lastFundedAt' }),
      pub.getBlock(),
    ])
    // Chain time, the clock lastFundedAt was recorded with
    const due = dueDeposit(BigInt(genesis), BigInt(duration), block.timestamp, BigInt(lastFundedAt))
    if (!due) {
      console.log(`Nothing due at ${block.timestamp}`)
      return
    }

    const wallet = createWalletClient({ account: privateKeyToAccount(env.FEEDER_PRIVATE_KEY), transport })
    // chain: null takes the chain id from the RPC, so the same Worker runs against a local rehearsal
    const hash = await wallet.writeContract({
      chain: null,
      address: faucet,
      abi: faucetAbi,
      functionName: 'fundRewards',
      args: [staking, due.amount],
    })
    const receipt = await pub.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error(`fundRewards reverted in ${hash}`)
    console.log(`Epoch ${due.epoch}, day ${due.day}: deposited ${due.amount} USDC units for the next epoch in ${hash}`)
  },
}
