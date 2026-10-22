import { BaseError, ContractFunctionRevertedError, InsufficientFundsError, UserRejectedRequestError } from 'viem'
import { chain } from '../config/chain'
import { formatTime } from './format'

/** OpenZeppelin 4.9 reverts with strings: the tokens' ERC20 checks, Ownable and SafeCast */
const reasons: Record<string, string> = {
  'ERC20: insufficient allowance': 'The staking contract is not approved to move this much DEXY yet. Approve it first.',
  'ERC20: transfer amount exceeds balance': 'Your DEXY balance is too low for this amount.',
  'Ownable: caller is not the owner': 'Only the owner of the contract can do this.',
  "SafeCast: value doesn't fit in 128 bits": 'This amount is too large for the contract to record.',
}

/**
 * Turns a failed simulation or transaction into one sentence that says what happened and, where it helps, what to
 * do. Contract errors are decoded by name from the combined ABIs in lib/abi.ts.
 */
export function describeError(err: unknown): string {
  if (err instanceof Error && err.name === 'Error' && err.message.startsWith('The transaction reverted when it landed'))
    return err.message
  if (!(err instanceof BaseError)) return err instanceof Error ? err.message : 'The request failed.'

  if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
  if (err.walk((e) => e instanceof InsufficientFundsError))
    return `Your wallet needs ${chain.name} ETH to pay for gas. Get some from a faucet and try again.`

  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null
  const name = reverted?.data?.errorName
  const a = (reverted?.data?.args ?? []) as readonly unknown[]
  // viem decodes a string revert as the built-in Error(string); older nodes only give the reason
  const reason = name === 'Error' ? (a[0] as string) : reverted?.reason
  if (reason && reasons[reason]) return reasons[reason]

  switch (name) {
    case 'WrongParams':
      return 'Enter an amount above zero and pick one of the levels.'
    case 'ZeroBoostedStake':
      return "This amount is too small: at this level's multiplier its weight rounds down to zero."
    case 'AlreadyMigrated':
      return 'The contract has been migrated, so new stakes are closed. Open stakes can still be withdrawn.'
    case 'StakeStillLocked':
      return 'This stake is still locked. It can be withdrawn from its unlock time on.'
    case 'AlreadyUnstaked':
      return 'This stake has already been withdrawn.'
    case 'StakeNotFound':
      return 'Your account has no stake with this number.'
    case 'NoRewardsToHarvest':
      return 'There is nothing to harvest yet. Rewards accrue every second while the stream runs.'
    case 'NoStakedTokens':
      return 'You have no open stake, so there is nothing to harvest.'
    case 'ClaimTooSoon':
      return `You claimed less than 24 hours ago. The faucet opens again for you at ${formatTime(a[1] as bigint)}.`
    case 'ClaimFromContract':
      return 'The faucet only hands out tokens to regular accounts, not to contracts or smart contract wallets.'
    case 'OnlyMinter':
      return 'Only the faucet can mint the testnet tokens.'
  }

  if (reverted) return `The transaction would revert${name ? ` (${name})` : ''}.`
  return err.shortMessage || 'The request failed.'
}
