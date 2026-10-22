# Dexynth Staking demo app

A web app for the staking contract in this repository, running on Base Sepolia with testnet tokens. Visitors can
read the whole pool without a wallet, and with one they can claim test DEXY, stake it at any level, watch their
rewards accrue every second, harvest them and unstake once the lock ends.

Proof of concept, not audited, for educational purposes. The tokens are testnet stand-ins with no value.

<!-- Live: https://staking-poc.gushalk.workers.dev (once deployed) -->

## What it shows

- **The stream split.** Each level is a block as wide as the DEXY staked in it and as tall as its multiplier, so
  its area is its boosted weight and its share of the reward stream. The visitor's own stake is drawn inside it.
- **Positions as the contract sees them.** Rewards tick every second. The app projects the accumulator with the
  contract's own formulas and rounding (`src/lib/staking.ts`), checked to the wei against a local deployment
  (`scripts/parity.test.ts`).
- **Previews before every call.** A stake shows the boosted weight, the share of the stream and the unlock time
  before and after; an unstake shows the DEXY returned and about what it pays in USDC. Each call is simulated before
  the wallet asks for a signature, so a revert arrives as a sentence (`src/lib/errors.ts`) instead of a failed
  transaction.
- **Levels and the epoch clock.** What 1,000 DEXY staked now would earn a day at each level, at today's pool, and
  how far the current epoch has run, since a stake unlocks at the next epoch start plus its lock.
- **Funding the stream.** Anyone can preview what a funding would do to the daily rate, the unstreamed total and
  the end of the stream, computed as `addStakingReward` computes it. Only the owner's wallet can send it: the panel
  mints any USDC the owner is short through the faucet, approves it and funds, and a faucet claim also gives the
  owner 100,000 USDC.

## What is a testnet stand-in

The staking contract is the repository's own, `src/DexynthStaking.sol`, unchanged. The protocol has no oracle or
other external dependency, so the only stand-ins are the tokens and the demo configuration around them, all in
`script/testnet/`:

- **`TestnetFaucet` and `TestnetToken`.** The faucet deploys DEXY (18 decimals) and a USDC stand-in (6 decimals,
  the reward token), and only the faucet can mint either. It hands out 10,000 DEXY per account, once every 24
  hours. What it checks: the limit per account, that claims come straight from an externally owned account (so one
  transaction cannot claim through many fresh contracts), and that only its owner mints freely or seeds stakes.
  What it does not check: someone who funds many accounts can claim with each. Smart contract wallets cannot claim.
  USDC is earned by staking; only the faucet's owner receives it from a claim, 100,000 per claim, to fund the
  stream.
- **The seed.** Before the stream starts, the faucet contract stakes 500,000 DEXY across the five levels (50,000,
  75,000, 125,000, 125,000 and 125,000), 50 faucet drips. The faucet has no function to unstake or harvest, so the
  pool never empties and no dust stake can be alone in it when the stream starts. The rewards that seed earns stay
  in the staking contract.
- **Time.** Epochs last 1 day, the shortest the constructor accepts, and the locks are 1 hour, 1 day, 3 days,
  7 days and 14 days instead of the deploy script's 30 to 720 days with 15-day epochs. The multipliers, 0.65x to
  1.35x, are the deploy script's, read from `DeployDexynthStaking._levels()`.
- **The stream.** The deployer funds 100,000 USDC over 365 days and stays the owner of both contracts.
  `TopUpRewards.s.sol` funds it again.

## Run it locally

Requires Node 22 and, for a local chain, Foundry.

```bash
cd app
npm install
npm run dev                  # reads the Base Sepolia deployment
```

Against a local chain instead (anvil and a full deployment):

```bash
./app/scripts/local-chain.sh                 # from the repo root; deploys, checks, writes deployments/31337.json
cd app && VITE_CHAIN_ID=31337 npm run dev
```

anvil mines a block only when a transaction arrives, so the chain's clock stands still between transactions and
right after a stake there is nothing to harvest yet. `cast rpc evm_setIntervalMining 2` makes it mine every
2 seconds; Base Sepolia produces a block about every 0.2 seconds.

Checks:

```bash
npm run typecheck
npm test                                                   # unit tests of the staking math and the model
LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts     # parity, needs anvil's default mining (see below)
node scripts/contrast.mjs                                  # the color figures in DESIGN.md
```

The parity suite checks every function the app mirrors against the contracts, to the wei: the pool and user
state each stake leaves at every level, a stake whose weight rounds to zero, pending rewards at many timestamps,
what a harvest and an unstake pay, unlock times on both sides of an epoch boundary, the end of the stream, and the
unstreamed amount a migration moves. It also sends a stake estimated right after another call updated the pool,
with the app's gas margin. It reverts the chain to a snapshot when it finishes, so it can run again. It pins each transaction's timestamp,
so it needs anvil to mine on every transaction, as it does by default: after `evm_setIntervalMining`, run
`cast rpc evm_setAutomine true` first. CI runs it on
every push, against a fresh local deployment.

## Gas

A node can estimate gas at the latest block's timestamp. When another call already updated the pool in that block,
the pool update is skipped in the estimate, and when the caller was settled in that block, so is the settlement.
When the caller's own harvest or unstake in that block already paid the rewards, the estimate pays nothing: no
transfer and no event. One block later all of it runs. `FOUNDRY_PROFILE=testnet forge test --match-contract
GasMargin -vv` measures the difference at up to 64,476 gas (an unstake right after the caller's own harvest, with
the paid USDC moved out in that block), and the app sends `estimate * 125 / 100 + 80,000` (`src/hooks/useTx.ts`).
The parity suite lands that unstake on anvil with the app's limit.

## Deploy the contracts to Base Sepolia

From the repository root, with a fresh key used only for this demo:

```bash
cast wallet import demo-deployer --interactive    # stores the key encrypted, asks for a password
```

Fund that address with a little Base Sepolia ETH from one of the
[Base faucets](https://docs.base.org/base-chain/network-information/network-faucets), then:

```bash
forge script script/testnet/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
forge script script/testnet/ConfirmDeployment.s.sol --rpc-url https://sepolia.base.org
```

The first script simulates everything first, including a smoke test in which a fresh address claims, stakes, earns
for an hour and harvests, and only then broadcasts. It deploys the faucet and its two tokens and the staking
contract, seeds the five levels, mints 100,000 USDC to the deployer and funds the stream over 365 days. Forge runs a
script in full before it sends anything, so the first script only records the addresses, in
`cache/testnet-deployment-84532.json`. The second sends nothing: it checks on the chain that every recorded address
holds code and that the contracts are wired and configured as the first script sets them up, and only then writes
`app/src/config/deployments/84532.json`, which the app reads: commit that file. If a broadcast fails halfway, the
check fails and the app's file stays as it was. If the RPC has not caught up with the deployment yet, run the check
again. Nothing in either script depends on a price or a short time window.

To fund the stream again later, with the same key (it spreads the new amount plus whatever is not streamed yet over
the new duration, which changes the rate for every staker):

```bash
TOP_UP_USDC=100000 TOP_UP_DAYS=365 forge script script/testnet/TopUpRewards.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

To verify the contracts, add `--verify --verifier sourcify` to the deploy command; Sourcify needs no key. The
deployment of 22 Oct 2026 was verified this way, with an exact match for all four contracts. Blockscout's keyless
API (`--verifier blockscout`) answered "Too many requests" to every attempt, even one contract at a time.
BaseScan verification goes through the Etherscan API V2, whose chain list marks Base Sepolia as paid plan only
(`https://api.etherscan.io/v2/chainlist`); with a paid key, use `--verify --etherscan-api-key <key>` instead.
To verify an already deployed contract, use `forge verify-contract <address> <path>:<name> --constructor-args <abi
encoded args> --chain 84532 --verifier sourcify`.

The testnet tooling has its own tests, kept apart so the protocol's test figures stay unchanged:

```bash
FOUNDRY_PROFILE=testnet forge test
```

## Deploy the app to Cloudflare Workers

The app runs as `staking-poc`, an assets-only Worker: there is no Worker script. `wrangler.jsonc` points it at
`dist/` and holds the SPA fallback, which serves `index.html` for every page path (`/how-it-works`).
`public/_headers` holds the cache and security headers; Vite copies it into `dist/`.

The `og:image` and `og:url` tags in `index.html` carry the absolute workers.dev URL, since link preview crawlers
do not resolve relative paths: change them if the Worker's URL differs or the app moves to its own domain.

First deploy, from a terminal in `app/`:

```bash
npx wrangler login           # authorizes wrangler on your Cloudflare account, in the browser
npm run deploy               # builds, deploys and prints the workers.dev URL
```

Deploys on push: in the Cloudflare dashboard, connect this repository to the Worker (Workers Builds) with root
directory `app`, build command `npm run build` and deploy command `npx wrangler deploy`. The Worker name in
`wrangler.jsonc` must match the Worker in the dashboard, or the build fails.

`VITE_RPC_URL` is optional, for when the public Base Sepolia RPC rate limits the page. Vite reads it at build time,
so on Workers Builds it goes in the build variables (Settings, Build), not in the runtime variables. Any key in it
is visible to visitors, so restrict it to the site's domain at the provider.

## Structure

```
src/
  abi/          generated from the Foundry build (npm run abi after forge build)
  config/       chain, links, and the deployment files written by the script
  lib/          staking math, the derived model, error messages, formatting
  hooks/        chain reads, the model, transactions, toasts, the current page
  components/   the interface
scripts/
  local-chain.sh     local rehearsal of the testnet deployment
  parity.test.ts     app math against a local deployment
  sync-abi.mjs       regenerates src/abi
  contrast.mjs       contrast and color distance of the accent and data colors
```

Design notes: [DESIGN.md](./DESIGN.md).
