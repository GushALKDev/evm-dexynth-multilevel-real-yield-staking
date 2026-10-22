import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import type { Abi, Address } from 'viem'
import { useConnection } from 'wagmi'
import { estimateGas, simulateContract, writeContract } from 'wagmi/actions'
import { BaseError, ContractFunctionRevertedError, encodeFunctionData, ExecutionRevertedError } from 'viem'
import { explorerTx } from '../config/chain'
import { describeError } from '../lib/errors'
import { waitForOutcome } from '../lib/receipt'
import { wagmiConfig } from '../wagmi'
import { useToasts } from './useToasts'

export interface ContractCall {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
}

/** The call passed simulation but reverted once mined, so nothing changed. */
export class LandedRevertError extends Error {
  constructor() {
    super('The transaction reverted when it landed, so nothing changed. The state may have moved: try again.')
  }
}

/** Tries, and the pause between them, for a call that follows an approval while the RPC catches up. */
const CATCH_UP_TRIES = 5
const CATCH_UP_MS = 2_000

/**
 * The gas limit sent for a node estimate. A node can estimate at the latest block's timestamp: when another call
 * already updated the pool in that block, _updatePool returns early in the estimate, and when the caller was settled
 * in it, so does _settle. When the caller's own harvest or unstake in that block already paid the rewards, the
 * estimate pays nothing: no transfer, no event. One block later all of them run. script/testnet/test/GasMargin.t.sol
 * measures up to 64,476 gas of difference and checks that the fixed part alone covers it.
 */
export function withGasMargin(estimate: bigint): bigint {
  return (estimate * 125n) / 100n + 80_000n
}

const isRevert = (err: unknown) =>
  err instanceof BaseError &&
  !!err.walk((e) => e instanceof ContractFunctionRevertedError || e instanceof ExecutionRevertedError)

/** Builds, simulates and estimates a call: everything before the wallet asks for a signature. */
async function prepare(call: ContractCall, account: Address) {
  // Simulating first surfaces a revert, decoded, before the wallet asks for a signature.
  const { request } = await simulateContract(wagmiConfig, { ...call, account } as never)
  const estimate = await estimateGas(wagmiConfig, {
    account,
    to: call.address,
    data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
  })
  return { request, gas: withGasMargin(estimate) }
}

/** Simulates, sends and confirms one call at a time, reporting each step in a toast. */
export function useTx() {
  const { address } = useConnection()
  const toasts = useToasts()
  const queryClient = useQueryClient()
  const [busy, setBusy] = useState<string | null>(null)

  const run = useCallback(
    async (label: string, done: string, call: ContractCall, opts: { afterApproval?: boolean } = {}): Promise<boolean> => {
      if (!address) return false
      setBusy(label)
      const id = toasts.push({ tone: 'pending', title: label, body: 'Checking the call against the chain…' })
      try {
        // A public RPC spreads requests over several nodes, so the call right after an approval can reach one
        // that has not imported the approval's block yet and revert on the old allowance. That call retries a
        // revert for a few blocks before reporting it.
        let prepared
        for (let attempt = 1; !prepared; attempt++) {
          try {
            prepared = await prepare(call, address)
          } catch (err) {
            if (!opts.afterApproval || attempt >= CATCH_UP_TRIES || !isRevert(err)) throw err
            await new Promise((r) => setTimeout(r, CATCH_UP_MS))
          }
        }
        const { request, gas } = prepared
        toasts.update(id, { body: 'Confirm it in your wallet.' })
        const hash = await writeContract(wagmiConfig, { ...(request as object), gas } as never)
        toasts.update(id, { body: 'Waiting for the block…', href: explorerTx(hash) })
        const outcome = await waitForOutcome(wagmiConfig, hash)
        if (outcome === 'unknown' || outcome === 'cancelled') {
          // The transaction was sent, but it did not land as sent or its outcome could not be read: do not guess.
          toasts.update(id, {
            tone: 'error',
            title: outcome === 'cancelled' ? `${label}: cancelled` : `${label}: outcome unknown`,
            body:
              outcome === 'cancelled'
                ? 'Your wallet replaced the transaction with a cancellation, so nothing changed.'
                : 'The transaction was sent but its result could not be read from the RPC. Check it on the explorer before trying again.',
          })
          await queryClient.invalidateQueries()
          return false
        }
        if (outcome === 'reverted') throw new LandedRevertError()
        toasts.update(id, { tone: 'success', title: done, body: undefined })
        await queryClient.invalidateQueries()
        return true
      } catch (err) {
        console.error(err)
        toasts.update(id, { tone: 'error', title: `${label} failed`, body: describeError(err) })
        return false
      } finally {
        setBusy(null)
      }
    },
    [address, toasts, queryClient],
  )

  return { run, busy }
}
