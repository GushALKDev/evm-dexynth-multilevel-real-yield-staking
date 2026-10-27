# Dexynth Staking demo app

A web app for the staking contract in this repository, running on Base Sepolia with testnet tokens. Visitors can
read the whole pool without a wallet, and with one they can claim test DEXY and USDC, stake at any level, watch their
rewards accrue every second, harvest them, unstake once the lock ends, and deposit USDC as rewards to watch the next
epoch's rate rise. A scheduled depositor on Cloudflare Workers plays the platform that earns the yield.

Proof of concept, not audited, for educational purposes. The tokens are testnet stand-ins with no value.

Live: https://staking-poc.tesselium.com

## What it shows

- **The running epoch.** Next to the headline: the epoch's number, the time it has left and the USDC it streams in
  all.
- **The stream split.** Each level is a block as wide as the DEXY staked in it and as tall as its multiplier, so
  its area is its boosted weight and its share of the reward stream. Each column shows its DEXY staked and share,
  and the USDC the level gets over the epoch. The visitor's own stake is drawn inside it.
- **Positions as the contract sees them.** Rewards tick every second. The app projects the accumulator with the
  contract's own formulas and rounding (`src/lib/staking.ts`), checked to the wei against a local deployment
  (`scripts/parity.test.ts`).
- **Previews before every call.** A stake shows the boosted weight, the share of the stream and the unlock time
  before and after; an unstake shows the DEXY returned and about what it pays in USDC. Each call is simulated before
  the wallet asks for a signature, so a revert arrives as a sentence (`src/lib/errors.ts`) instead of a failed
  transaction.
- **Levels and the epoch clock.** What 1,000 DEXY staked now would earn a day at each level, at today's pool, how
  far the current epoch has run, what it streams a day and what is deposited for the next one.
- **Depositing rewards.** Anyone can deposit USDC. The panel previews what a deposit adds to the next epoch's queue
  and daily rate, computed as `addStakingReward` computes it, then approves and deposits. The epoch running keeps its
  rate.

## What is a testnet stand-in

The staking contract is the repository's own, `src/DexynthStaking.sol`, unchanged. The protocol has no oracle or
other external dependency, so the only stand-ins are the tokens and the demo configuration around them, all in
`script/testnet/`:

- **`TestnetFaucet` and `TestnetToken`.** The faucet deploys DEXY (18 decimals) and a USDC stand-in (6 decimals,
  the reward token), and only the faucet can mint either. It hands out 10,000 DEXY and 500 USDC per account, once
  every 24 hours, so a visitor can stake and also deposit rewards. What it checks: the limit per account, that
  claims come straight from an externally owned account (so one transaction cannot claim through many fresh
  contracts), that only its owner mints freely, seeds stakes or replaces the feeder, and that only the feeder funds
  rewards through `fundRewards`. What it does not check: someone who funds many accounts can claim with each. Smart
  contract wallets cannot claim.
- **The seed.** Before epoch 0 starts, the faucet contract stakes 500,000 DEXY across the five levels (50,000,
  75,000, 125,000, 125,000 and 125,000), 50 faucet drips. The faucet has no function to unstake or harvest, so the
  pool never empties and no dust stake can be alone in it when the first rewards stream. The rewards that seed earns
  stay in the staking contract.
- **Time.** Epochs last 7 days and the locks are 1 hour, 1 day, 3 days, 7 days and 14 days instead of the deploy
  script's 30 to 720 days with 15-day epochs. Epoch 0 starts 5 minutes after the deployment. The multipliers,
  0.65x to 1.35x, are the deploy script's, read from `DeployDexynthStaking._levels()`.
- **Rewards.** The deployer deposits 2,000 USDC before epoch 0 starts, so they stream during it, and stays the owner
  of both contracts. From then on the feeder deposits a day of yield every day (see below), and
  `TopUpRewards.s.sol` deposits extra USDC by hand.

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
state each stake leaves at every level and on both sides of an epoch turn, a stake whose weight rounds to zero,
pending rewards at many timestamps and across funded and empty epochs, what a harvest and an unstake pay, a deposit
by any account and the feeder's funding, and the unstreamed amount a migration moves. It also sends a stake estimated right after another call updated the pool,
with the app's gas margin. It reverts the chain to a snapshot when it finishes, so it can run again. It pins each transaction's timestamp,
so it needs anvil to mine on every transaction, as it does by default: after `evm_setIntervalMining`, run
`cast rpc evm_setAutomine true` first. CI runs it on
every push, against a fresh local deployment.

## Gas

A node can estimate gas at the latest block's timestamp. When another call already updated the pool in that block,
the pool update is skipped in the estimate, and when the caller was settled in that block, so is the settlement.
When the caller's own harvest or unstake in that block already paid the rewards, the estimate pays nothing: no
transfer and no event. When an epoch starts between the two blocks, the landing also writes the new epoch's state.
One block later all of it runs. `FOUNDRY_PROFILE=testnet forge test --match-contract GasMargin -vv` measures the
difference at up to 65,606 gas (an unstake right after the caller's own harvest, with the paid USDC moved out in
that block; 24,581 for a harvest across an epoch turn), and the app sends `estimate * 125 / 100 + 80,000`
(`src/hooks/useTx.ts`).
The parity suite lands that unstake on anvil with the app's limit.

## Deploy the contracts to Base Sepolia

From the repository root, with a fresh key used only for this demo:

```bash
cast wallet import demo-deployer --interactive    # stores the key encrypted, asks for a password
```

Fund that address with a little Base Sepolia ETH from one of the
[Base faucets](https://docs.base.org/base-chain/network-information/network-faucets). The feeder's address (see
[the scheduled depositor](#the-scheduled-depositor)) goes in `FEEDER_ADDRESS`. Then:

```bash
FEEDER_ADDRESS=<feeder address> forge script script/testnet/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
forge script script/testnet/ConfirmDeployment.s.sol --rpc-url https://sepolia.base.org
```

The first script simulates everything first, including a smoke test in which a fresh address claims, stakes, earns
for an hour of epoch 0, harvests and deposits its USDC, and the feeder funds the next epoch, and only then
broadcasts. It deploys the faucet (with the feeder) and its two tokens and the staking contract, whose epoch 0
starts 5 minutes later, seeds the five levels, and mints 2,000 USDC to the deployer and deposits them for epoch 0.
Forge runs a script in full before it sends anything, so the first script only records the addresses, in
`cache/testnet-deployment-84532.json`. The second sends nothing: it checks on the chain that every recorded address
holds code and that the contracts are wired and configured as the first script sets them up, including the first
deposit queued for or streaming in epoch 0, and only then writes `app/src/config/deployments/84532.json`, which the
app and the feeder read: commit that file. If a broadcast fails halfway, the check fails and the app's file stays as
it was. Run the check within epoch 0; if the RPC has not caught up with the deployment yet, run it again. The start
of epoch 0 is computed when forge simulates the script, before it sends anything: a broadcast that takes longer than
5 minutes from then makes the staking deployment revert (`StartNotInFuture`) or lands the first deposit in epoch 1,
and the check fails on either.

A new deployment changes every address and the contract's interface, so the app and the feeder go out with it:
commit the deployment file, then deploy the app and the feeder.

To deposit extra USDC by hand, with the same key (it joins what is queued for the next epoch, and the running epoch
keeps its rate):

```bash
TOP_UP_USDC=1000 forge script script/testnet/TopUpRewards.s.sol \
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

## The scheduled depositor

`feeder/` is a second Worker, `staking-feeder`, that plays the platform earning the yield. A cron trigger runs it
every hour. Each epoch has a plan derived from its index alone (`feeder/plan.ts`): a total between 500 and 2,000
USDC, split over its 7 days with weights between 0.5 and 1.5, each day's deposit due from a random hour. When a day's
hour has come and the faucet's `lastFundedAt` is older than the day's start, the Worker calls
`TestnetFaucet.fundRewards`, which mints that day's USDC and deposits it for the next epoch. It keeps no state, so a
failed run is retried the next hour, and a day the Worker misses entirely is skipped.

Setup, once:

1. Create a key used only for this, `cast wallet new`, and fund its address with a little Base Sepolia ETH for gas.
   That address is the `FEEDER_ADDRESS` of the contract deployment above. The key only lets it fund rewards; if it
   leaks, the faucet's owner replaces it with `setFeeder`.
2. From `app/`, store the key as a Worker secret and deploy the Worker. The secret prompt asks for the key, with its
   `0x` prefix; it is stored encrypted at Cloudflare and never written to the repository:

   ```bash
   npx wrangler secret put FEEDER_PRIVATE_KEY -c feeder/wrangler.jsonc
   npx wrangler deploy -c feeder/wrangler.jsonc
   ```

3. Its runs show in the Cloudflare dashboard (Workers, `staking-feeder`, Logs), or live with
   `npx wrangler tail -c feeder/wrangler.jsonc`.

The addresses are bundled from `src/config/deployments/84532.json` at build time, so deploy the Worker again after
every contract deployment. `RPC_URL` in `feeder/wrangler.jsonc` defaults to the public Base Sepolia endpoint, enough
for one run an hour. On the Workers free plan a cron run gets 10 ms of CPU time; waiting for the RPC does not count.

To rehearse it on a local chain, after `./app/scripts/local-chain.sh` (whose feeder is anvil's account 5):

```bash
npx wrangler dev -c feeder/wrangler.jsonc --test-scheduled --var RPC_URL:http://127.0.0.1:8545 \
  --var STAKING_ADDRESS:<staking> --var FAUCET_ADDRESS:<faucet> --var FEEDER_PRIVATE_KEY:<anvil key 5>
curl "http://localhost:8787/cdn-cgi/handler/scheduled?cron=0+*+*+*+*"
```

Each call runs the Worker once against the local chain's time; `cast rpc evm_setNextBlockTimestamp` and
`cast rpc evm_mine` move that time to a day's planned hour.

## Deploy the app to Cloudflare Workers

The app runs as `staking-poc`, an assets-only Worker: there is no Worker script. `wrangler.jsonc` points it at
`dist/` and holds the SPA fallback, which serves `index.html` for every page path (`/how-it-works`).
`public/_headers` holds the security headers; Vite copies it into `dist/`.

The `og:image` and `og:url` tags in `index.html` carry the absolute URL of the app's domain, staking-poc.tesselium.com,
since link preview crawlers do not resolve relative paths: change them if the app moves to another domain.

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
feeder/         the scheduled depositor Worker, its plan and its tests
scripts/
  local-chain.sh     local rehearsal of the testnet deployment
  parity.test.ts     app math against a local deployment
  sync-abi.mjs       regenerates src/abi
  contrast.mjs       contrast and color distance of the accent and data colors
```

Design notes: [DESIGN.md](./DESIGN.md).
