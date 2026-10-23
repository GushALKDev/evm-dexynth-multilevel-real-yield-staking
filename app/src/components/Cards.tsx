import { useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { stakingAbi, tokenAbi } from '../lib/abi'
import { countdown, formatDuration, formatFixed, formatPct, formatTime, parseAmount, shortAddress } from '../lib/format'
import { DAY, QUOTE_DEXY, type StakingModel } from '../lib/model'
import { MAX_TOTAL_FUNDING, PRECISION, applyDeposit, updatePool } from '../lib/staking'

const multiplier = (boostP: bigint) => `${formatFixed(boostP, 10, 2)}x`

export function LevelsCard({ model }: { model: StakingModel }) {
  const d = model.deployment
  return (
    <div className="card">
      <div className="card-title">
        <h3>Levels</h3>
      </div>
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th scope="col">Level</th>
              <th scope="col">Lock</th>
              <th scope="col" className="num">
                Staked
              </th>
              <th scope="col" className="num">
                USDC a day
              </th>
            </tr>
          </thead>
          <tbody>
            {model.levels.map((l) => (
              <tr key={l.index}>
                <td>
                  {l.index} <span className="faint">{multiplier(l.boostP)}</span>
                </td>
                <td>{formatDuration(l.lockingPeriod)}</td>
                <td className="num" title={`${formatPct(l.share, 2)} of the stream`}>
                  {formatFixed(l.totalStaked, d.dexy.decimals, 0)}
                </td>
                <td className="num">{formatFixed(l.perDayQuote, d.reward.decimals, 4)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="hint" style={{ marginTop: 12 }}>
        USDC a day: what {formatFixed(QUOTE_DEXY, d.dexy.decimals, 0)} DEXY staked now at that level would earn at
        today's pool, until others stake or leave. Locks and multipliers are fixed at deployment, and each lock counts
        from the stake.
      </p>
    </div>
  )
}

export function StreamCard({ model }: { model: StakingModel }) {
  const d = model.deployment
  const st = model.static
  const s = model.stream
  const started = model.epoch >= 0n
  const elapsed = started ? Number(model.now - (model.nextEpochAt - model.epochs.duration)) : 0
  const epochProgress = Math.min(100, (elapsed / Number(model.epochs.duration)) * 100)
  const live = model.live
  const executeFrom = live.migrationRequestTime + st.migrationDelay
  const next = model.epoch + 1n

  return (
    <div className="card">
      <div className="card-title">
        <h3>Stream and epochs</h3>
      </div>
      <dl className="rows">
        <div className="row">
          <dt>Funded since deployment</dt>
          <dd>
            {formatFixed(s.funded, d.reward.decimals, 2)} <span className="faint">USDC</span>
          </dd>
        </div>
        <div className="row">
          <dt>Not streamed yet</dt>
          <dd>
            {formatFixed(s.unstreamed, d.reward.decimals, 2)} <span className="faint">USDC</span>
          </dd>
        </div>
        <div className="row">
          <dt>{started ? `Epoch ${model.epoch.toString()} streams` : 'Streams before epoch 0'}</dt>
          <dd>
            {formatFixed(s.perDay, d.reward.decimals, 2)} <span className="faint">USDC a day</span>
          </dd>
        </div>
        <div className="row">
          <dt>Deposited for epoch {next.toString()}</dt>
          <dd>
            {formatFixed(s.queued, d.reward.decimals, 2)} <span className="faint">USDC, {formatFixed(s.nextPerDay, d.reward.decimals, 2)} a day</span>
          </dd>
        </div>
        <div className="row">
          <dt>Epoch</dt>
          <dd>
            {started ? (
              <>
                {model.epoch.toString()}{' '}
                <span className="faint">
                  of {formatDuration(model.epochs.duration)}, next in {countdown(model.nextEpochAt - model.now)}
                </span>
              </>
            ) : (
              <>
                0 in {countdown(model.nextEpochAt - model.now)}{' '}
                <span className="faint">of {formatDuration(model.epochs.duration)} each</span>
              </>
            )}
          </dd>
        </div>
      </dl>
      <div
        className="progress"
        role="progressbar"
        aria-label="Current epoch elapsed"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(epochProgress)}
      >
        <div style={{ width: `${epochProgress}%` }} />
      </div>
      <dl className="rows" style={{ marginTop: 12 }}>
        <div className="row">
          <dt>Owner</dt>
          <dd>
            <a className="mono" href={explorerAddress(live.owner)} target="_blank" rel="noreferrer">
              {shortAddress(live.owner)}
            </a>
          </dd>
        </div>
        <div className="row">
          <dt>Migration</dt>
          <dd>
            {live.migrated
              ? 'Executed'
              : model.migrationPending
                ? `Requested, executable from ${formatTime(executeFrom)}`
                : live.migrationRequestTime > 0n
                  ? 'Last request expired unexecuted'
                  : 'None requested'}
          </dd>
        </div>
      </dl>
    </div>
  )
}

export function DepositCard({ model }: { model: StakingModel }) {
  const d = model.deployment
  const { address, chainId } = useConnection()
  const { run, busy } = useTx()
  const [amountInput, setAmountInput] = useState('')

  const acc = model.account
  // The pool read with the account when one is connected, so the preview matches its other figures
  const pool = acc?.pool ?? model.pool
  const t = model.now
  const amount = parseAmount(amountInput, d.reward.decimals)
  const capRoom = MAX_TOTAL_FUNDING - model.stream.funded
  const wallet = acc?.data.wallet.reward ?? 0n
  const next = model.epoch + 1n

  let error: string | undefined
  if (model.live.migrated) error = 'The contract has been migrated, so it no longer takes deposits.'
  else if (amountInput !== '' && amount === null) error = `Enter a number with at most ${d.reward.decimals} decimals.`
  else if (amount !== null && amount > capRoom) error = 'More than the contract can still be funded with.'
  else if (acc && amount !== null && amount > wallet)
    error = `More than your wallet balance. The faucet hands out ${formatFixed(model.static.usdcDrip, d.reward.decimals, 0)} USDC a day.`

  const valid = amount !== null && amount > 0n && !error
  const before = updatePool(pool, t)
  const after = valid ? applyDeposit(pool, amount, t) : null
  const needsApproval = valid && (acc?.data.rewardAllowance ?? 0n) < amount
  const wrongNetwork = !!address && chainId !== chain.id
  const noGas = !!acc && acc.data.wallet.eth === 0n
  const canSubmit = !!acc && valid && !busy && !wrongNetwork && !noGas

  const submit = async () => {
    if (!address || amount === null) return
    if (needsApproval) {
      const ok = await run('Approve USDC', 'USDC approved', {
        address: d.reward.address,
        abi: tokenAbi,
        functionName: 'approve',
        args: [d.staking, amount],
      })
      if (!ok) return
    }
    const ok = await run(
      'Deposit rewards',
      'Rewards deposited',
      { address: d.staking, abi: stakingAbi, functionName: 'addStakingReward', args: [amount] },
      { afterApproval: needsApproval },
    )
    if (ok) setAmountInput('')
  }

  // The next epoch's rate in USDC units a day, from what is queued for it
  const perDay = (queued: bigint) => ((queued / pool.epochDuration) * DAY) / PRECISION

  return (
    <div className="card">
      <div className="card-title">
        <h3>Deposit rewards</h3>
        <span className="card-sub">Anyone</span>
      </div>
      <div className="action" style={{ marginTop: 0 }}>
        <div className="field">
          <label className="field-label" htmlFor="deposit-amount">
            <span>USDC</span>
            {acc ? <span>Wallet {formatFixed(wallet, d.reward.decimals, d.reward.shown)} USDC</span> : null}
          </label>
          <div className="input-wrap" data-invalid={amountInput !== '' && amount === null}>
            <input
              id="deposit-amount"
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0.00"
              value={amountInput}
              onChange={(e) => setAmountInput(e.target.value)}
            />
            <span className="unit">USDC</span>
          </div>
        </div>
        {error ? (
          <span className="hint" data-tone="danger">
            {error}
          </span>
        ) : null}

        {after ? (
          <dl className="rows">
            <div className="row">
              <dt>Deposited for epoch {next.toString()}</dt>
              <dd>
                <span className="faint">{formatFixed(before.queuedRewards / PRECISION, d.reward.decimals, 2)}</span>
                <span className="arrow">to</span>
                {formatFixed(after.queuedRewards / PRECISION, d.reward.decimals, 2)}
              </dd>
            </div>
            <div className="row">
              <dt>Epoch {next.toString()} streams a day</dt>
              <dd>
                <span className="faint">{formatFixed(perDay(before.queuedRewards), d.reward.decimals, 2)}</span>
                <span className="arrow">to</span>
                {formatFixed(perDay(after.queuedRewards), d.reward.decimals, 2)}
              </dd>
            </div>
            <div className="row">
              <dt>Epoch {next.toString()} starts</dt>
              <dd>{formatTime(after.nextEpochStart)}</dd>
            </div>
          </dl>
        ) : null}

        <p className="hint">
          A deposit joins what is queued for the next epoch and streams evenly over it, so the epoch running now keeps
          its rate. Time with nobody staked is set aside and joins the next deposit.
        </p>

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
          {busy === 'Approve USDC'
            ? 'Approving…'
            : busy === 'Deposit rewards'
              ? 'Depositing…'
              : needsApproval
                ? 'Approve and deposit'
                : 'Deposit'}
        </button>
        {!acc ? (
          <p className="hint">Connect a wallet to deposit. Anyone can preview what a deposit would do.</p>
        ) : wrongNetwork ? (
          <p className="hint">Switch your wallet to {chain.name} from the button at the top.</p>
        ) : needsApproval && canSubmit ? (
          <p className="hint">Two transactions: an approval for this amount, then the deposit itself.</p>
        ) : null}
      </div>
    </div>
  )
}
