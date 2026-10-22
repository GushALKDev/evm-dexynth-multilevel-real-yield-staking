import { explorerAddress } from '../config/chain'
import { countdown, formatDuration, formatFixed, formatPct, formatTime, shortAddress } from '../lib/format'
import { QUOTE_DEXY, type StakingModel } from '../lib/model'

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
      <p className="hint" style={{ marginTop: 12 }}>
        Only the owner can fund the stream. A new funding spreads the new amount plus whatever is not streamed yet over a
        new duration, which changes the rate for every staker.
      </p>
    </div>
  )
}
