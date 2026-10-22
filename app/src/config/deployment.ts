import type { Address } from 'viem'

// Deployment files are written by script/testnet/DeployTestnet.s.sol, one per chain id, only on a broadcast.
interface RawDeployment {
  chainId: number
  deployBlock: number
  staking: Address
  faucet: Address
  dexy: Address
  rewardToken: Address
  owner: Address
}

export interface TokenInfo {
  symbol: 'DEXY' | 'USDC'
  address: Address
  decimals: number
  /** Decimals shown for amounts of this token in the interface */
  shown: number
}

export interface Deployment {
  chainId: number
  deployBlock: bigint
  staking: Address
  faucet: Address
  owner: Address
  dexy: TokenInfo
  reward: TokenInfo
}

const files = import.meta.glob<RawDeployment>('./deployments/*.json', { eager: true, import: 'default' })

export function loadDeployment(chainId: number): Deployment | null {
  const raw = files[`./deployments/${chainId}.json`]
  if (!raw) return null
  return {
    chainId: raw.chainId,
    deployBlock: BigInt(raw.deployBlock),
    staking: raw.staking,
    faucet: raw.faucet,
    owner: raw.owner,
    // Both are TestnetFaucet stand-ins with these decimals (script/testnet/TestnetFaucet.sol)
    dexy: { symbol: 'DEXY', address: raw.dexy, decimals: 18, shown: 2 },
    reward: { symbol: 'USDC', address: raw.rewardToken, decimals: 6, shown: 2 },
  }
}
