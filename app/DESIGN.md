# Design notes

Working notes for the demo app. It shares the demo family's system with the money market app
([evm-lending-borrowing-protocol/app/DESIGN.md](https://github.com/GushALKDev/evm-lending-borrowing-protocol/blob/main/app/DESIGN.md)):
IBM Plex, the neutral greys, spacing, radii, components, danger and warn, and the interaction patterns.
Only the accent and the one memorable element change.

## Accent and data colors of this app

| Role | Light | Dark |
| :-- | :-- | :-- |
| Lichen accent | #5A6438 | #A2AE82 |
| Lichen hover | #48502B | #B3BE97 |
| Lichen soft | #E5E8DC | #2D3220 |
| Text on the accent | #FFFFFF | #0E1412 |
| Steel, the pool's stake in the stream split | #5B7FB0 | #6F8ECC |

The accent marks primary actions, the protocol's headline figure (USDC streamed to stakers), selected
level chips, links styled as buttons, the success toast, the mark, the favicon and the visitor's own
stake in the stream split. Steel is the only data color beyond it: everyone's stake.

Checked with `node scripts/contrast.mjs` (WCAG contrast; OKLab Delta E x 100 for normal vision):

| Check | Light | Dark |
| :-- | --: | --: |
| Accent against its button text | 6.34 | 7.91 |
| Hover against its button text | 8.54 | 9.52 |
| Accent against the ground | 5.52 | 7.91 |
| Steel against the ground | 3.58 | 5.69 |
| Steel against the surface it is drawn on | 4.11 | 5.29 |
| Delta E steel to accent | 17.7 | 17.4 |
| Delta E steel to danger | 23.7 | 21.2 |
| Delta E steel to warn | 20.1 | 24.7 |

## Subject

A multi-level staking contract on a testnet. Visitors are protocol founders, CTOs and engineers judging
the engineering, plus anyone who wants to stake. The page has two jobs: let them stake, harvest and
unstake without friction, and make the reward accounting visible (one accumulator per boosted unit,
multipliers that trade lock for weight, epochs that anchor the lock).

## The one memorable element

The stream split. Each level is a block as wide as the DEXY staked in it and as tall as its multiplier,
so the block's area is its boosted weight. Every boosted unit earns the same reward per second, so the
area is also the level's share of the stream, printed above it. The visitor's own DEXY is the accent
part at the left edge of each block. The drawing is the contract's weighting rather than decoration:
widths come from `getLevels()`, heights from each level's `boostP`, shares from `totalBoostedStake`.
Everything else stays quiet.

## Tokens

Ground, surface, ink, rules, danger and warn are the family's (see `src/styles.css`). Type: IBM Plex
Sans for everything, with tabular figures; IBM Plex Mono only for addresses. Sentence case throughout,
no all-caps labels.

## Layout

```
header        wordmark (links to the staking page), network, pages, test tokens, wallet
              pages: Stake, How it works, on a second header row below 1024 px
notice        one line: testnet, educational, not audited, stand-ins and shortened locks

/             hero: headline + stream split + four figures
              grid: your position, stake form and stakes (left, wider) | levels, stream, deposits (right)
/how-it-works four mechanics + what differs on this testnet

footer
```

Left-aligned throughout. Two columns from 1024 px, one below. The stream split keeps every level at
least 34 px wide and drops the level names below 480 px, leaving the multipliers.

## Rules

- Copy names what the user does: Stake, Harvest, Unstake. The button that says Stake produces a toast
  that says DEXY staked.
- Every preview shows before and after, computed with the contract's own rounding
  (`src/lib/staking.ts`): boosted weight, share of the stream, unlock time, rewards paid, and what a
  deposit adds to the next epoch's queue and daily rate.
- A deposit can be previewed without a wallet: the preview works for anyone, the button once a wallet
  is connected, and the panel says so.
- Figures that tick (rewards, the streamed total) project to the visitor's clock, kept between the
  latest block's timestamp and 30 seconds past it. Anything a call depends on (whether a stake is
  unlocked, what an unstake pays, whether the faucet opens) uses the latest block's timestamp, and the
  account's figures use the pool read in the same call as the account.
- Errors say what happened and what to do, decoded from the contracts' custom errors and from
  OpenZeppelin 4.9's revert strings.
- Motion only where something changed: the split's blocks ease to new widths and heights, rewards tick.
  Reduced motion turns the transitions off.
