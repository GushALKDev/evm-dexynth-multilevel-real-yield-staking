import { chain, explorerAddress } from '../config/chain'
import { countdown, formatCompact, formatDate, formatDuration, formatFixed, formatPct, formatTime } from '../lib/format'
import type { StakingModel } from '../lib/model'

const multiplier = (boostP: bigint) => `${formatFixed(boostP, 10, 2)}x`

/**
 * The pool drawn as the contract weighs it: one block per level, as wide as the DEXY staked in it and as tall as its
 * multiplier, so each block's area is its boosted weight and its share of the stream. The visitor's own DEXY in each
 * level is the accent part at the block's left edge.
 */
export function StreamSplit({ model }: { model: StakingModel }) {
  const d = model.deployment
  const levels = model.levels
  const total = model.totalStaked
  const maxBoost = levels.reduce((m, l) => (l.boostP > m ? l.boostP : m), 0n)
  const acc = model.account
  const yoursTotal = acc ? acc.dexyByLevel.reduce((a, b) => a + b, 0n) : 0n

  if (total === 0n) return <p className="muted">Nothing is staked yet. The first stake will appear here.</p>

  return (
    <>
      <div className="split" role="img" aria-label="Each level's DEXY staked, multiplier and share of the reward stream">
        {levels.map((l) => {
          const width = Number((l.totalStaked * 10_000n) / total) / 100
          const height = Number((l.boostP * 10_000n) / maxBoost) / 100
          const yours = acc ? acc.dexyByLevel[l.index] : 0n
          const yoursWidth = l.totalStaked > 0n ? Number((yours * 10_000n) / l.totalStaked) / 100 : 0
          const perDay = model.stream.active ? (model.stream.perDay * l.share) / 10n ** 18n : 0n
          return (
            <div
              key={l.index}
              className="split-col"
              style={{ flexGrow: width, flexBasis: 0 }}
              title={`Level ${l.index}: ${formatDuration(l.lockingPeriod)} lock, ${multiplier(l.boostP)}, ${formatFixed(l.totalStaked, d.dexy.decimals, 0)} DEXY staked, ${formatPct(l.share, 1)} of the stream, about ${formatFixed(perDay, d.reward.decimals, 2)} USDC a day`}
            >
              <span className="split-share">{formatPct(l.share, 1)}</span>
              <div className="split-area">
                <div className="split-block" style={{ height: `${height}%` }}>
                  {yours > 0n ? <div className="split-yours" style={{ width: `${Math.max(yoursWidth, 1.5)}%` }} /> : null}
                </div>
              </div>
              <span className="split-label">
                <span className="split-level">Level {l.index}</span>
                <span>{multiplier(l.boostP)}</span>
              </span>
            </div>
          )
        })}
      </div>
      <div className="legend">
        <span>
          <i className="swatch-pool" />
          Everyone's stake
        </span>
        {yoursTotal > 0n ? (
          <span>
            <i className="swatch-yours" />
            Yours, {formatPct(acc!.share, 2)} of the stream
          </span>
        ) : null}
        <span className="faint">Width: DEXY staked. Height: multiplier. Above: share of the stream.</span>
      </div>
    </>
  )
}

export function Hero({ model }: { model: StakingModel }) {
  const d = model.deployment
  const s = model.stream
  const started = model.epoch >= 0n
  const next = model.epoch + 1n
  return (
    <section className="hero">
      <div className="wrap">
        <div className="hero-head">
          <h1>Stake DEXY, pick a lock, and earn USDC every second.</h1>
          <p className="hero-sub">
            A multi-level staking contract that streams its reward token through one global accumulator, epoch by epoch:
            what is deposited during an epoch streams over the next one. Running on {chain.name} with testnet tokens;
            every figure on this page is computed from the contract's live state.
          </p>
        </div>
        <div className="sheet">
          <div className="sheet-top">
            <h2>The reward stream, split by boosted weight</h2>
            <a className="card-sub" href={explorerAddress(d.staking)} target="_blank" rel="noreferrer">
              Read live from {chain.name}
            </a>
          </div>
          <StreamSplit model={model} />
          <p className="sheet-note">
            Every boosted unit earns the same reward per second, so a level's share of the stream is its share of the
            total area. A stake's boosted weight is its amount times its level's multiplier, rounded down.
          </p>
          {model.live.migrated ? (
            <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
              The owner has migrated the rewards that were not streamed yet. New stakes are closed and every stake can
              be withdrawn now, lock or not.
            </div>
          ) : !started ? (
            <div className="callout" style={{ marginTop: 14 }}>
              Epoch 0 starts at {formatTime(model.nextEpochAt)}, with {formatFixed(s.queued, d.reward.decimals, 2)} USDC
              deposited for it. Stakes made before then earn from its start.
            </div>
          ) : !s.active ? (
            <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
              Nothing was deposited for epoch {model.epoch.toString()}, so stakes earn nothing until epoch {next.toString()}{' '}
              starts on {formatDate(model.nextEpochAt)}.
            </div>
          ) : null}
          <div className="figures">
            <div className="figure">
              {s.streamed !== null ? (
                <>
                  <div className="figure-value tone-accent">{formatFixed(s.streamed, d.reward.decimals, 4)}</div>
                  <div className="figure-label">USDC streamed to stakers so far</div>
                </>
              ) : (
                <>
                  <div className="figure-value">Migrated</div>
                  <div className="figure-label">The owner moved the unstreamed rewards out</div>
                </>
              )}
            </div>
            <div className="figure">
              <div className="figure-value">{formatFixed(s.perDay, d.reward.decimals, 2)}</div>
              <div className="figure-label">{started ? `USDC a day in epoch ${model.epoch.toString()}` : 'USDC a day until epoch 0'}</div>
            </div>
            <div className="figure">
              <div className="figure-value">{formatCompact(model.totalStaked, d.dexy.decimals)}</div>
              <div className="figure-label">DEXY staked</div>
            </div>
            <div className="figure">
              <div className="figure-value">{formatFixed(s.queued, d.reward.decimals, 2)}</div>
              <div className="figure-label">
                USDC deposited for epoch {next.toString()}, which starts in {countdown(model.nextEpochAt - model.now)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
