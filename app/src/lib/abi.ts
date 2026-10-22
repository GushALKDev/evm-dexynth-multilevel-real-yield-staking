import { erc20Abi } from 'viem'
import { faucetAbi as rawFaucetAbi, stakingAbi as rawStakingAbi, testnetTokenAbi } from '../abi'

const errorsOf = <T extends readonly { type: string }[]>(abi: T) =>
  abi.filter((item): item is Extract<T[number], { type: 'error' }> => item.type === 'error')

// A staking call reaches the two tokens (TestnetToken, OpenZeppelin 4.9 ERC20, which reverts with strings), and a
// seed stake reaches the staking contract from the faucet. Each ABI carries the errors of every contract its calls
// reach, so viem decodes any revert into a named error with its arguments.
export const stakingAbi = [...rawStakingAbi, ...errorsOf(testnetTokenAbi)] as const

export const faucetAbi = [...rawFaucetAbi, ...errorsOf(testnetTokenAbi), ...errorsOf(rawStakingAbi)] as const

export const tokenAbi = [...erc20Abi, ...errorsOf(testnetTokenAbi)] as const
