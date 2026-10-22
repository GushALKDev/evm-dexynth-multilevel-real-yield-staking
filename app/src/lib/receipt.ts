import type { Hex } from 'viem'
import type { Config } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'

export type Outcome = 'success' | 'reverted' | 'cancelled' | 'unknown'

/** How long to wait for a receipt before reporting the outcome as unknown */
const RECEIPT_TIMEOUT_MS = 180_000

/**
 * How a sent transaction ended, as far as the RPC can tell. viem's receipt wait, not wagmi's: wagmi's throws on a
 * reverted receipt, which would read as an unreadable one. A transaction the wallet replaced with a cancellation
 * resolves with the cancellation's receipt, so it is reported as cancelled rather than as a success.
 */
export async function waitForOutcome(config: Config, hash: Hex): Promise<Outcome> {
  const client = getPublicClient(config)
  if (!client) return 'unknown'
  let cancelled = false
  try {
    const receipt = await client.waitForTransactionReceipt({
      hash,
      timeout: RECEIPT_TIMEOUT_MS,
      onReplaced: (replacement) => {
        cancelled = replacement.reason === 'cancelled'
      },
    })
    if (cancelled) return 'cancelled'
    return receipt.status === 'success' ? 'success' : 'reverted'
  } catch {
    return 'unknown'
  }
}
