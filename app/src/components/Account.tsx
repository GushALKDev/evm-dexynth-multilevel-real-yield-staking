import { useState } from 'react'
import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { stakingAbi, tokenAbi } from '../lib/abi'
import { countdown, formatDate, formatDuration, formatFixed, formatPct, formatTime, parseAmount, toInput } from '../lib/format'
import { DAY, ONE, type AccountView, type StakingModel } from '../lib/model'
import { applyStake, applyUnstake, rewardsOver, type StakeInfo } from '../lib/staking'

const multiplier = (boostP: bigint) => `${formatFixed(boostP, 10, 2)}x`

/* ------------------------------------------------------------------ */
/* Summary                                                             */
/* ------------------------------------------------------------------ */

function Summary({ model, acc }: { model: StakingModel; acc: AccountView }) {
  const d = model.deployment
  const { run, busy } = useTx()
  const watch = useWatchAsset()
  const noGas = acc.data.wallet.eth === 0n
  const hasStake = acc.user.totalStakedDexy > 0n

  return (
    <>
      <div className="position-main">
        <span className="position-state">Rewards to harvest</span>
        <span className="position-amount" data-testid="pending">
          {formatFixed(acc.pending, d.reward.decimals, 6)}
          <small>USDC</small>
        </span>
        <span className="hint">
          {hasStake
            ? model.stream.active
              ? `About ${formatFixed(acc.perDay, d.reward.decimals, 2)} USDC a day at today's pool, ${formatPct(acc.share, 2)} of the stream. Rewards accrue every second.`
              : model.live.migrated
                ? 'The owner migrated the rewards not streamed yet, so your stakes earn nothing more. You can harvest what has accrued and withdraw every stake.'
                : model.epoch < 0n
                  ? `Epoch 0 starts at ${formatTime(model.nextEpochAt)}, and your stakes earn from then.`
                  : `Nothing was deposited for epoch ${model.epoch.toString()}, so your stakes earn nothing until the next epoch starts on ${formatDate(model.nextEpochAt)}.`
            : 'Stake DEXY below to start earning a share of the stream.'}
        </span>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>DEXY staked</dt>
          <dd>{formatFixed(acc.user.totalStakedDexy, d.dexy.decimals, d.dexy.shown)}</dd>
        </div>
        <div className="row">
          <dt>Boosted weight</dt>
          <dd>{formatFixed(acc.user.boostedBalance, d.dexy.decimals, d.dexy.shown)}</dd>
        </div>
        <div className="row">
          <dt>Harvested so far</dt>
          <dd>
            {formatFixed(acc.user.totalHarvestedRewards, d.reward.decimals, d.reward.shown)} <span className="faint">USDC</span>
            <button
              className="link-button"
              style={{ marginLeft: 8, fontSize: 13 }}
              onClick={() => watch.mutate({ type: 'ERC20', options: { address: d.reward.address, symbol: d.reward.symbol, decimals: d.reward.decimals } })}
            >
              Add to wallet
            </button>
          </dd>
        </div>
        <div className="row">
          <dt>In your wallet</dt>
          <dd>
            {formatFixed(acc.data.wallet.dexy, d.dexy.decimals, d.dexy.shown)} <span className="faint">DEXY</span>
            {', '}
            {formatFixed(acc.data.wallet.reward, d.reward.decimals, d.reward.shown)} <span className="faint">USDC</span>
          </dd>
        </div>
      </dl>
      {hasStake ? (
        <button
          className="btn btn-block"
          style={{ marginTop: 14 }}
          disabled={acc.pendingAtChain === 0n || !!busy || noGas}
          onClick={() =>
            run('Harvest rewards', 'Rewards harvested', { address: d.staking, abi: stakingAbi, functionName: 'harvest' })
          }
        >
          {busy === 'Harvest rewards' ? 'Harvesting…' : 'Harvest rewards'}
        </button>
      ) : null}
    </>
  )
}

/* ------------------------------------------------------------------ */
/* Stake                                                               */
/* ------------------------------------------------------------------ */

function StakeForm({ model, acc }: { model: StakingModel; acc: AccountView }) {
  const d = model.deployment
  const [levelIndex, setLevelIndex] = useState(0)
  const [input, setInput] = useState('')
  const { run, busy } = useTx()
  const { address } = useConnection()

  const level = model.levels[levelIndex]
  const wallet = acc.data.wallet.dexy
  const amount = parseAmount(input, d.dexy.decimals)
  const invalidInput = input !== '' && amount === null
  const noGas = acc.data.wallet.eth === 0n
  const a = amount ?? 0n

  // Projected to the visitor's clock, the closest guess for when the call lands
  const after = applyStake(acc.pool, acc.user, level, a, model.now)
  const shareAfter = after.pool.totalBoostedStake > 0n ? (after.user.boostedBalance * ONE) / after.pool.totalBoostedStake : 0n
  const perDayAfter = rewardsOver(after.pool, after.user.boostedBalance, model.now, DAY)

  let error: string | undefined
  if (model.live.migrated) error = 'The contract has been migrated, so new stakes are closed.'
  else if (a > wallet) error = 'More than your wallet balance.'
  else if (a > 0n && after.boosted === 0n) error = "Too small: at this level's multiplier its weight rounds down to zero."

  const needsApproval = a > 0n && acc.data.allowance < a
  const canSubmit = a > 0n && !error && !busy && !noGas

  const submit = async () => {
    if (!amount || !address) return
    if (needsApproval) {
      const ok = await run('Approve DEXY', 'DEXY approved', {
        address: d.dexy.address,
        abi: tokenAbi,
        functionName: 'approve',
        args: [d.staking, amount],
      })
      if (!ok) return
    }
    const ok = await run(
      'Stake DEXY',
      'DEXY staked',
      { address: d.staking, abi: stakingAbi, functionName: 'stake', args: [amount, levelIndex] },
      { afterApproval: needsApproval },
    )
    if (ok) setInput('')
  }

  return (
    <div className="action" style={{ marginTop: 22 }}>
      <h3 className="action-title">Stake</h3>
      <div className="level-choice" role="radiogroup" aria-label="Level">
        {model.levels.map((l) => (
          <button
            key={l.index}
            role="radio"
            className="chip level-chip"
            aria-checked={levelIndex === l.index}
            onClick={() => setLevelIndex(l.index)}
          >
            <strong>{multiplier(l.boostP)}</strong>
            <span>{formatDuration(l.lockingPeriod)}</span>
          </button>
        ))}
      </div>
      <p className="hint">
        Level {levelIndex}: locked for {formatDuration(level.lockingPeriod)} from the stake, weighted{' '}
        {multiplier(level.boostP)}.
      </p>

      <div className="field">
        <label className="field-label" htmlFor="amount">
          <span>Amount</span>
          <span>Wallet {formatFixed(wallet, d.dexy.decimals, d.dexy.shown)} DEXY</span>
        </label>
        <div className="input-wrap" data-invalid={invalidInput || (!!amount && !!error)}>
          <input
            id="amount"
            className="amount-input"
            inputMode="decimal"
            autoComplete="off"
            placeholder="0.00"
            value={input}
            onChange={(e) => setInput(e.target.value)}
          />
          <span className="unit">DEXY</span>
          <button className="max" disabled={wallet === 0n} onClick={() => setInput(toInput(wallet, d.dexy.decimals))}>
            Max
          </button>
        </div>
        {invalidInput ? (
          <span className="hint" data-tone="danger">
            Enter a number with at most {d.dexy.decimals} decimals.
          </span>
        ) : null}
        {error && (amount || model.live.migrated) ? (
          <span className="hint" data-tone="danger">
            {error}
          </span>
        ) : null}
      </div>

      {amount && !error ? (
        <dl className="rows">
          <div className="row">
            <dt>Boosted weight</dt>
            <dd>
              <span className="faint">{formatFixed(acc.user.boostedBalance, d.dexy.decimals, d.dexy.shown)}</span>
              <span className="arrow">to</span>
              {formatFixed(after.user.boostedBalance, d.dexy.decimals, d.dexy.shown)}
            </dd>
          </div>
          <div className="row">
            <dt>Share of the stream</dt>
            <dd>
              <span className="faint">{formatPct(acc.share, 2)}</span>
              <span className="arrow">to</span>
              {formatPct(shareAfter, 2)}
            </dd>
          </div>
          {model.stream.active ? (
            <div className="row">
              <dt>USDC a day, at today's pool</dt>
              <dd>
                <span className="faint">{formatFixed(acc.perDay, d.reward.decimals, 2)}</span>
                <span className="arrow">to</span>
                {formatFixed(perDayAfter, d.reward.decimals, 2)}
              </dd>
            </div>
          ) : null}
          <div className="row">
            <dt>Unlocks</dt>
            <dd>{formatTime(after.unlockTime)}</dd>
          </div>
        </dl>
      ) : null}

      {noGas ? (
        <div className="callout" data-tone="warn">
          Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
          <a href={links.ethFaucet} target="_blank" rel="noreferrer">
            faucet
          </a>
          .
        </div>
      ) : null}

      <button className="btn btn-primary btn-block" disabled={!canSubmit} onClick={submit}>
        {busy === 'Approve DEXY' ? 'Approving…' : busy === 'Stake DEXY' ? 'Staking…' : needsApproval ? 'Approve and stake' : 'Stake'}
      </button>
      {needsApproval && canSubmit ? (
        <p className="hint">Two transactions: an approval for this amount, then the stake itself.</p>
      ) : null}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Stakes                                                              */
/* ------------------------------------------------------------------ */

function UnstakePreview({ model, acc, stake, onDone }: { model: StakingModel; acc: AccountView; stake: StakeInfo; onDone: () => void }) {
  const d = model.deployment
  const { run, busy } = useTx()
  // At the latest block's timestamp, from the pool read with the account: about what the call pays when it lands
  const after = applyUnstake(acc.pool, acc.user, stake, model.chainTime)
  const shareAfter = after.pool.totalBoostedStake > 0n ? (after.user.boostedBalance * ONE) / after.pool.totalBoostedStake : 0n
  return (
    <div className="unstake-preview">
      <p>
        Withdraws stake {stake.index.toString()} and pays every reward your account has accrued, not only this stake's.
      </p>
      <dl className="rows">
        <div className="row">
          <dt>DEXY returned</dt>
          <dd>{formatFixed(after.principal, d.dexy.decimals, d.dexy.shown)}</dd>
        </div>
        <div className="row">
          <dt>USDC paid, about</dt>
          <dd>{formatFixed(after.rewards, d.reward.decimals, 6)}</dd>
        </div>
        <div className="row">
          <dt>Share of the stream</dt>
          <dd>
            <span className="faint">{formatPct(acc.share, 2)}</span>
            <span className="arrow">to</span>
            {formatPct(shareAfter, 2)}
          </dd>
        </div>
      </dl>
      <div className="inline-actions">
        <button
          className="btn btn-primary"
          disabled={!!busy || acc.data.wallet.eth === 0n}
          onClick={async () => {
            const ok = await run('Unstake', 'Stake withdrawn', {
              address: d.staking,
              abi: stakingAbi,
              functionName: 'unstake',
              args: [stake.index],
            })
            if (ok) onDone()
          }}
        >
          {busy ? 'Unstaking…' : 'Unstake'}
        </button>
        <button className="btn btn-quiet" onClick={onDone}>
          Cancel
        </button>
      </div>
    </div>
  )
}

function Stakes({ model, acc }: { model: StakingModel; acc: AccountView }) {
  const d = model.deployment
  const [selected, setSelected] = useState<bigint | null>(null)
  if (acc.open.length === 0 && acc.closed.length === 0) return null
  const chosen = acc.open.find((s) => s.index === selected)

  return (
    <div style={{ marginTop: 26 }}>
      <h3 className="action-title">Your stakes</h3>
      {acc.open.length === 0 ? <p className="muted">No open stakes.</p> : null}
      {acc.open.length > 0 ? (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th scope="col">Stake</th>
                <th scope="col">Level</th>
                <th scope="col" className="num">
                  DEXY
                </th>
                <th scope="col">Unlocks</th>
                <th scope="col">
                  <span className="visually-hidden">Action</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {acc.open.map((s) => {
                // Against the latest block, which the unstake's simulation and landing cannot be earlier than
                const unlocked = model.live.migrated || model.chainTime >= s.unlockTime
                return (
                  <tr key={s.index.toString()} aria-selected={selected === s.index}>
                    <td>{s.index.toString()}</td>
                    <td>
                      {s.level} <span className="faint">{multiplier(model.levels[s.level].boostP)}</span>
                    </td>
                    <td className="num">{formatFixed(s.stakedDexy, d.dexy.decimals, d.dexy.shown)}</td>
                    <td>
                      {unlocked ? (
                        <span className="status" data-tone="ok">
                          Unlocked
                        </span>
                      ) : (
                        <span title={formatTime(s.unlockTime)}>in {countdown(s.unlockTime - model.now)}</span>
                      )}
                    </td>
                    <td className="num">
                      <button
                        className="link-button"
                        disabled={!unlocked}
                        onClick={() => setSelected(s.index)}
                        aria-label={`Unstake stake ${s.index.toString()}`}
                      >
                        Unstake
                      </button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      ) : null}
      {chosen ? <UnstakePreview model={model} acc={acc} stake={chosen} onDone={() => setSelected(null)} /> : null}
      {acc.closed.length > 0 ? (
        <details className="closed-stakes">
          <summary>Withdrawn stakes ({acc.closed.length})</summary>
          <ul className="plain-list">
            {acc.closed.map((s) => (
              <li key={s.index.toString()}>
                Stake {s.index.toString()}: {formatFixed(s.stakedDexy, d.dexy.decimals, d.dexy.shown)} DEXY at level {s.level},
                staked {formatTime(s.timestamp)}
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* First visit                                                         */
/* ------------------------------------------------------------------ */

function GetStarted({ model }: { model: StakingModel }) {
  const first = model.levels[0]
  return (
    <div className="card">
      <div className="card-title">
        <h3>Try the whole cycle</h3>
      </div>
      <div className="flow">
        <div className="flow-step">
          <b>1</b>
          <span>
            Get a little {chain.name} ETH for gas from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </span>
        </div>
        <div className="flow-step">
          <b>2</b>
          <span>Connect your wallet and claim test DEXY and USDC from the button at the top.</span>
        </div>
        <div className="flow-step">
          <b>3</b>
          <span>Stake it at any level and watch your rewards accrue every second. Harvest them whenever you like.</span>
        </div>
        <div className="flow-step">
          <b>4</b>
          <span>
            Deposit your USDC as rewards and watch the next epoch's rate rise. Come back once the stake unlocks, its
            lock after staking ({formatDuration(first.lockingPeriod)} at level 0), and unstake it.
          </span>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Card                                                                */
/* ------------------------------------------------------------------ */

export function AccountCard({ model, onConnect, onFaucet }: { model: StakingModel; onConnect: () => void; onFaucet: () => void }) {
  const { status, chainId } = useConnection()
  const acc = model.account
  const d = model.deployment

  if (status !== 'connected') {
    return (
      <>
        <div className="card">
          <div className="card-title">
            <h2>Your position</h2>
          </div>
          <div className="empty">
            <p>
              <strong>Connect a wallet to stake.</strong> You can read the whole pool without one.
            </p>
            <p>
              New here? The faucet gives you {formatFixed(model.static.drip, d.dexy.decimals, 0)} DEXY and{' '}
              {formatFixed(model.static.usdcDrip, d.reward.decimals, 0)} USDC on {chain.name}, once every 24 hours.
            </p>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <button className="btn btn-primary" onClick={onConnect}>
                Connect wallet
              </button>
              <button className="btn" onClick={onFaucet}>
                Get test tokens
              </button>
            </div>
          </div>
        </div>
        <GetStarted model={model} />
      </>
    )
  }

  if (chainId !== chain.id) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Your wallet is on another network. Switch to {chain.name} from the button at the top.</p>
      </div>
    )
  }

  if (!acc) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Reading your stakes…</p>
      </div>
    )
  }

  const empty = acc.user.stakeCount === 0n && acc.data.wallet.dexy === 0n

  return (
    <div className="card">
      <div className="card-title">
        <h2>Your position</h2>
        {empty ? (
          <button className="link-button" onClick={onFaucet}>
            Get test tokens
          </button>
        ) : null}
      </div>
      <Summary model={model} acc={acc} />
      <StakeForm model={model} acc={acc} />
      <Stakes model={model} acc={acc} />
    </div>
  )
}
