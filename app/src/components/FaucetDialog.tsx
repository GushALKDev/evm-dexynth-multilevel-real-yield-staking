import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { faucetAbi } from '../lib/abi'
import { formatFixed, formatTime } from '../lib/format'
import type { StakingModel } from '../lib/model'
import { TokenIcon } from './icons'
import { Dialog } from './Wallet'

export function FaucetDialog({ model, onClose, onConnect }: { model: StakingModel; onClose: () => void; onConnect: () => void }) {
  const { address, chainId } = useConnection()
  const { run, busy } = useTx()
  const wrongNetwork = !!address && chainId !== chain.id
  const watch = useWatchAsset()
  const d = model.deployment
  const acc = model.account
  const next = acc ? acc.data.nextClaimAt : 0n
  // Against the latest block: the claim's simulation sees that timestamp, not the visitor's clock
  const canClaim = !!acc && model.chainTime >= next
  const noGas = !!acc && acc.data.wallet.eth === 0n
  const tokens = [
    { info: d.dexy, drip: model.static.drip, balance: acc?.data.wallet.dexy ?? 0n },
    { info: d.reward, drip: model.static.usdcDrip, balance: acc?.data.wallet.reward ?? 0n },
  ]

  return (
    <Dialog title="Test tokens" onClose={onClose}>
      <p className="muted">
        The faucet hands out testnet DEXY and USDC with no value, once every 24 hours per account. Stake the DEXY, and
        deposit the USDC as rewards to watch the next epoch's rate rise. Transactions also need a little {chain.name} ETH
        for gas.
      </p>
      <div className="rows" style={{ margin: '14px 0 18px' }}>
        {tokens.map(({ info, drip }) => (
          <div className="row" key={info.symbol}>
            <span className="asset">
              <TokenIcon symbol={info.symbol} />
              {info.symbol}
            </span>
            <span style={{ fontWeight: 500 }}>{formatFixed(drip, info.decimals, 0)}</span>
          </div>
        ))}
      </div>

      {!address ? (
        <button className="btn btn-primary btn-block" onClick={onConnect}>
          Connect wallet
        </button>
      ) : wrongNetwork ? (
        <p className="muted">Your wallet is on another network. Switch to {chain.name} from the button at the top.</p>
      ) : (
        <div className="steps">
          {noGas ? (
            <div className="callout" data-tone="warn">
              Your wallet has no {chain.name} ETH. Get some from a{' '}
              <a href={links.ethFaucet} target="_blank" rel="noreferrer">
                {chain.name} faucet
              </a>{' '}
              first, then come back.
            </div>
          ) : null}
          <button
            className="btn btn-primary btn-block"
            disabled={!canClaim || !!busy || noGas}
            onClick={() =>
              run('Claim test tokens', 'Test tokens claimed', {
                address: d.faucet,
                abi: faucetAbi,
                functionName: 'claim',
              })
            }
          >
            {busy ? 'Claiming…' : 'Claim test tokens'}
          </button>
          {!canClaim && acc ? (
            <p className="hint">You claimed less than 24 hours ago. The faucet opens again for you at {formatTime(next)}.</p>
          ) : null}
        </div>
      )}

      {address && acc && !wrongNetwork ? (
        <div className="rows" style={{ marginTop: 18 }}>
          {tokens.map(({ info, balance }) => (
            <div className="row" key={info.symbol}>
              <span className="muted">Your {info.symbol}</span>
              <span>
                {formatFixed(balance, info.decimals, info.shown)}{' '}
                <button
                  className="link-button"
                  style={{ marginLeft: 8, fontSize: 13 }}
                  onClick={() => watch.mutate({ type: 'ERC20', options: { address: info.address, symbol: info.symbol, decimals: info.decimals } })}
                >
                  Add to wallet
                </button>
              </span>
            </div>
          ))}
        </div>
      ) : null}
    </Dialog>
  )
}
