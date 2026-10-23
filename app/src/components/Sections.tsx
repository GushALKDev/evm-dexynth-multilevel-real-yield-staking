import type { ComponentProps } from 'react'
import { chain, explorerAddress, links } from '../config/chain'
import { navigate, pages, type Page } from '../hooks/useRoute'
import { formatDuration, formatFixed } from '../lib/format'
import type { StakingModel } from '../lib/model'
import { Mark } from './icons'
import { WalletButton } from './Wallet'

/** Link to a page of this app: a plain click switches page without a reload, a modified click keeps the browser's behavior. */
export function Link({ href, ...rest }: ComponentProps<'a'> & { href: string }) {
  return (
    <a
      href={href}
      {...rest}
      onClick={(e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
        e.preventDefault()
        navigate(href)
      }}
    />
  )
}

export function Header({ page, onConnect, onFaucet }: { page: Page; onConnect: () => void; onFaucet: () => void }) {
  return (
    <header className="site-header">
      <div className="wrap">
        <Link className="wordmark" href="/">
          <Mark />
          Dexynth Staking
        </Link>
        <span className="network">{chain.name}</span>
        <nav className="page-nav" aria-label="Pages">
          {pages.map((p) => (
            <Link key={p.page} className="page-link" href={p.path} aria-current={p.page === page ? 'page' : undefined}>
              {p.label}
            </Link>
          ))}
        </nav>
        <div className="header-actions">
          <button className="btn btn-faucet" onClick={onFaucet} aria-label="Get test tokens">
            <span>Test tokens</span>
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M8 2.5c2 2.6 3.5 4.6 3.5 6.6a3.5 3.5 0 0 1-7 0c0-2 1.5-4 3.5-6.6z" fill="none" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
          <WalletButton onConnect={onConnect} />
        </div>
      </div>
    </header>
  )
}

export function Notice() {
  return (
    <div className="notice">
      <div className="wrap">
        Testnet proof of concept for educational purposes, with tokens that have no value. Not audited. DEXY and USDC
        are faucet stand-ins and the locks are shortened to hours and days: <Link href="/how-it-works#testnet">what differs</Link>.
      </div>
    </div>
  )
}

export function HowItWorks({ model }: { model: StakingModel }) {
  const levels = model.levels
  const first = levels[0]
  const last = levels[levels.length - 1]
  const st = model.static
  const d = model.deployment
  const multiplier = (boostP: bigint) => `${formatFixed(boostP, 10, 2)}x`
  return (
    <section className="section" id="how">
      <div className="wrap">
        <div className="section-head">
          <h2>How this staking contract works</h2>
          <p>
            Four design decisions shape it. Each one is written up in the repository's{' '}
            <a href={links.design} target="_blank" rel="noreferrer">
              design guide
            </a>
            .
          </p>
        </div>
        <div className="mechanics">
          <div className="mechanic">
            <h3>One accumulator for everyone</h3>
            <p>
              The contract keeps one number: the reward per boosted unit accumulated since deployment. Every stake,
              unstake, harvest, deposit and migration first adds the time since the last update times the reward rate,
              divided by the total boosted stake. Your rewards are your boosted balance times how far that number has
              moved since you were last settled, rounded down. Stake, unstake and harvest do not loop over stakes, levels
              or epochs.
            </p>
          </div>
          <div className="mechanic">
            <h3>Levels trade lock for weight</h3>
            <p>
              A stake's weight is its amount times its level's multiplier, from {multiplier(first.boostP)} to{' '}
              {multiplier(last.boostP)}, rounded down. Every boosted unit earns the same reward per second, so a longer
              lock earns more per DEXY. The constructor only accepts locks and multipliers that strictly increase level
              by level, with multipliers averaging exactly 1.0x. A stake unlocks its level's lock after it was made.
              Unstaking withdraws one stake and pays all your accrued rewards; harvesting pays them and leaves your
              stakes in place.
            </p>
          </div>
          <div className="mechanic">
            <h3>Deposits stream epoch by epoch</h3>
            <p>
              Anyone can deposit USDC with addStakingReward. What is deposited during an epoch streams evenly over the
              next one, so a deposit never changes the rate of the epoch already running: a platform deposits its yield
              as it earns it, and stakers see a steady rate for a whole epoch. An epoch nobody deposited for streams
              nothing. Time with nobody staked is set aside and joins the next deposit.
            </p>
          </div>
          <div className="mechanic">
            <h3>The owner can only migrate</h3>
            <p>
              The owner's one power over rewards is the migration: after a delay of {formatDuration(st.migrationDelay)}{' '}
              and within a window of {formatDuration(st.migrationWindow)}, it moves the rewards not streamed yet (the
              rest of the current epoch and what is queued for the next), and that closes new stakes and lifts every
              lock. There is no pause, and no function that moves a staker's DEXY or accrued rewards to anyone but that
              staker.
            </p>
          </div>
        </div>

        <div className="oracle-note testnet-note" id="testnet">
          <div>
            <h3>What differs on this testnet</h3>
            <p>
              The{' '}
              <a href={explorerAddress(d.staking)} target="_blank" rel="noreferrer">
                staking contract
              </a>{' '}
              is the repository's own, unchanged. What surrounds it is set up for a demo:
            </p>
          </div>
          <ul className="plain-list">
            <li>
              DEXY and USDC are testnet stand-ins from a{' '}
              <a href={explorerAddress(d.faucet)} target="_blank" rel="noreferrer">
                faucet contract
              </a>
              , with no value. The faucet hands out {formatFixed(st.drip, d.dexy.decimals, 0)} DEXY and{' '}
              {formatFixed(st.usdcDrip, d.reward.decimals, 0)} USDC per account once every 24 hours, so you can stake
              and also deposit rewards.
            </li>
            <li>
              Epochs last {formatDuration(model.epochs.duration)} and the locks run from{' '}
              {formatDuration(first.lockingPeriod)} to {formatDuration(last.lockingPeriod)}. The production configuration
              in script/DeployDexynthStaking.s.sol uses 15-day epochs and locks of 30 to 720 days. The multipliers are
              the same.
            </li>
            <li>
              The faucet contract staked {formatFixed(model.live.faucetStaked, d.dexy.decimals, 0)} DEXY across the
              levels before epoch 0 started, so the pool is never empty. It has no function to unstake, so that stake
              stays.
            </li>
            <li>
              The deployer deposited the first epoch's rewards and remains the owner. Since then a scheduled depositor
              plays the platform: once a day it deposits a day of yield through the faucet, between 500 and 2,000 USDC a
              week in all. {formatFixed(model.stream.funded, d.reward.decimals, 0)} USDC funded so far.
            </li>
          </ul>
        </div>
      </div>
    </section>
  )
}

export function Footer({ model }: { model: StakingModel | null }) {
  return (
    <footer className="site-footer">
      <div className="wrap">
        <p>Proof of concept, not audited, for educational purposes. Testnet tokens have no value.</p>
        <nav className="footer-links" aria-label="Links">
          <a href={links.repo} target="_blank" rel="noreferrer">
            Source code
          </a>
          <a href={links.design} target="_blank" rel="noreferrer">
            Documentation
          </a>
          {model ? (
            <a href={explorerAddress(model.deployment.staking)} target="_blank" rel="noreferrer">
              Staking contract
            </a>
          ) : null}
          <a href={links.author} target="_blank" rel="noreferrer">
            Built by Gustavo Martín
          </a>
        </nav>
      </div>
    </footer>
  )
}
