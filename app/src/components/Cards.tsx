import { useState } from 'react'
import { useConnection } from 'wagmi'
import { chain, explorerAddress, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { faucetAbi, stakingAbi, tokenAbi } from '../lib/abi'
import { countdown, formatDuration, formatFixed, formatPct, formatTime, parseAmount, shortAddress } from '../lib/format'
import { DAY, QUOTE_DEXY, type StakingModel } from '../lib/model'
import { MAX_TOTAL_FUNDING, PRECISION, applyFunding, streamedOverDay, unstreamedScaled } from '../lib/staking'

const multiplier = (boostP: bigint) => `${formatFixed(boostP, 10, 2)}x`

export function LevelsCard({ model }: { model: StakingModel }) {
  const d = model.deployment
  return (
    <div className="card">
      <div className="card-title">
        <h3>Levels</h3>
        <span className="card-sub">Fixed at deployment</span>
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
        today's pool, until others stake or leave. Locks count from the start of the next epoch.
      </p>
    </div>
  )
}

export function StreamCard({ model }: { model: StakingModel }) {
  const d = model.deployment
  const st = model.static
  const s = model.stream
  const elapsed = Number(model.now - (model.nextEpochAt - model.epochs.duration))
  const epochProgress = Math.min(100, (elapsed / Number(model.epochs.duration)) * 100)
  const live = model.live
  const executeFrom = live.migrationRequestTime + st.migrationDelay

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
          <dt>Stream ends</dt>
          <dd>{formatTime(s.endTime)}</dd>
        </div>
        <div className="row">
          <dt>Epoch</dt>
          <dd>
            {model.epoch.toString()} <span className="faint">of {formatDuration(model.epochs.duration)}, next in {countdown(model.nextEpochAt - model.now)}</span>
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

export function FundCard({ model }: { model: StakingModel }) {
  const d = model.deployment
  const { address, chainId } = useConnection()
  const { run, busy } = useTx()
  const [amountInput, setAmountInput] = useState('')
  const [daysInput, setDaysInput] = useState('365')

  const owner = model.live.owner
  const isOwner = !!address && address.toLowerCase() === owner.toLowerCase()
  const acc = model.account
  // The pool read with the account when one is connected, so the preview matches its other figures
  const pool = acc?.pool ?? model.pool
  const t = model.now
  const amount = parseAmount(amountInput, d.reward.decimals)
  const days = /^\d+$/.test(daysInput.trim()) ? BigInt(daysInput.trim()) : null
  const duration = days !== null && days > 0n ? days * DAY : null
  const capRoom = MAX_TOTAL_FUNDING - model.stream.funded

  let error: string | undefined
  if (model.live.migrated) error = 'The contract has been migrated, so the stream can no longer be funded.'
  else if (amountInput !== '' && amount === null) error = `Enter a number with at most ${d.reward.decimals} decimals.`
  else if (duration === null) error = 'Enter a duration in whole days, at least 1.'
  else if (amount !== null && amount > capRoom) error = 'More than the contract can still be funded with.'

  const after = amount !== null && duration !== null && !error ? applyFunding(pool, amount, duration, t) : null
  const wallet = acc?.data.wallet.reward ?? 0n
  const shortfall = isOwner && amount !== null && amount > wallet ? amount - wallet : 0n
  const needsApproval = isOwner && amount !== null && amount > 0n && (acc?.data.rewardAllowance ?? 0n) < amount
  const wrongNetwork = !!address && chainId !== chain.id
  const noGas = !!acc && acc.data.wallet.eth === 0n
  const canSubmit = isOwner && !!after && !busy && !wrongNetwork && !noGas

  const submit = async () => {
    if (!address || amount === null || duration === null) return
    if (shortfall > 0n) {
      const ok = await run('Mint testnet USDC', 'Testnet USDC minted', {
        address: d.faucet,
        abi: faucetAbi,
        functionName: 'mint',
        args: [d.reward.address, address, shortfall],
      })
      if (!ok) return
    }
    if (needsApproval) {
      const ok = await run('Approve USDC', 'USDC approved', {
        address: d.reward.address,
        abi: tokenAbi,
        functionName: 'approve',
        args: [d.staking, amount],
      }, { afterApproval: shortfall > 0n })
      if (!ok) return
    }
    const ok = await run(
      'Fund the stream',
      'Stream funded',
      { address: d.staking, abi: stakingAbi, functionName: 'addStakingReward', args: [amount, duration] },
      { afterApproval: shortfall > 0n || needsApproval },
    )
    if (ok) setAmountInput('')
  }

  const steps = (shortfall > 0n ? 1 : 0) + (needsApproval ? 1 : 0) + 1

  return (
    <div className="card">
      <div className="card-title">
        <h3>Fund the stream</h3>
        <span className="card-sub">Owner only</span>
      </div>
      <div className="action" style={{ marginTop: 0 }}>
        <div className="field">
          <label className="field-label" htmlFor="fund-amount">
            <span>New USDC</span>
            {isOwner ? <span>Wallet {formatFixed(wallet, d.reward.decimals, d.reward.shown)} USDC</span> : null}
          </label>
          <div className="input-wrap" data-invalid={amountInput !== '' && amount === null}>
            <input
              id="fund-amount"
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
        <div className="field">
          <label className="field-label" htmlFor="fund-days">
            <span>Over</span>
          </label>
          <div className="input-wrap" data-invalid={duration === null}>
            <input
              id="fund-days"
              className="amount-input"
              inputMode="numeric"
              autoComplete="off"
              value={daysInput}
              onChange={(e) => setDaysInput(e.target.value)}
            />
            <span className="unit">days</span>
          </div>
        </div>
        {error ? (
          <span className="hint" data-tone="danger">
            {error}
          </span>
        ) : null}

        {after && amount !== null ? (
          <dl className="rows">
            <div className="row">
              <dt>USDC streamed a day</dt>
              <dd>
                <span className="faint">{formatFixed(streamedOverDay(pool, t), d.reward.decimals, 2)}</span>
                <span className="arrow">to</span>
                {formatFixed(streamedOverDay(after, t), d.reward.decimals, 2)}
              </dd>
            </div>
            <div className="row">
              <dt>Not streamed yet</dt>
              <dd>
                <span className="faint">{formatFixed(unstreamedScaled(pool, t) / PRECISION, d.reward.decimals, 2)}</span>
                <span className="arrow">to</span>
                {formatFixed(unstreamedScaled(after, t) / PRECISION, d.reward.decimals, 2)}
              </dd>
            </div>
            <div className="row">
              <dt>Stream ends</dt>
              <dd>
                <span className="faint">{formatTime(pool.rewardEndTime)}</span>
                <span className="arrow">to</span>
                {formatTime(after.rewardEndTime)}
              </dd>
            </div>
          </dl>
        ) : null}

        <p className="hint">
          {amount === 0n
            ? 'With no new USDC, a funding only respreads what is not streamed yet over the new duration.'
            : 'A funding spreads the new USDC plus whatever is not streamed yet evenly over the new duration, which changes the rate for every staker.'}
        </p>

        {isOwner && shortfall > 0n && after ? (
          <div className="callout">
            Your wallet holds less than this, so it first mints {formatFixed(shortfall, d.reward.decimals, d.reward.shown)}{' '}
            testnet USDC to you through the faucet's owner-only mint. A faucet claim also gives the owner{' '}
            {formatFixed(model.static.ownerDrip, d.reward.decimals, 0)} USDC a day.
          </div>
        ) : null}
        {isOwner && noGas ? (
          <div className="callout" data-tone="warn">
            Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </div>
        ) : null}

        <button className="btn btn-primary btn-block" disabled={!canSubmit} onClick={submit}>
          {busy === 'Mint testnet USDC'
            ? 'Minting…'
            : busy === 'Approve USDC'
              ? 'Approving…'
              : busy === 'Fund the stream'
                ? 'Funding…'
                : 'Fund the stream'}
        </button>
        {isOwner ? (
          wrongNetwork ? (
            <p className="hint">Switch your wallet to {chain.name} from the button at the top.</p>
          ) : steps > 1 && canSubmit ? (
            <p className="hint">
              {steps} transactions: {shortfall > 0n ? 'a mint, ' : ''}
              {needsApproval ? 'an approval, ' : ''}then the funding itself.
            </p>
          ) : null
        ) : (
          <p className="hint">
            addStakingReward is restricted to the owner,{' '}
            <a className="mono" href={explorerAddress(owner)} target="_blank" rel="noreferrer">
              {shortAddress(owner)}
            </a>
            , so only that wallet can send this. Anyone can preview what a funding would do.
          </p>
        )}
      </div>
    </div>
  )
}
