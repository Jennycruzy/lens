# Lens

### Verified cross-chain contract reads for Creditcoin.

Creditcoin can prove that an Ethereum transaction happened.
Lens lets it verify what an Ethereum contract returned.

**Live explorer:** <https://lens.54-154-121-30.sslip.io>
· CC3 testnet · Ethereum mainnet and Sepolia sources · 200 Foundry tests · MIT

Attestcoin proves transaction inclusion and events. Many cross-chain questions are not
transactions:

- What are this vault's reserves?
- What was this account's voting weight at block N?
- Does this address hold this role?
- What did this checkpointed exchange-rate function return?

Lens performs the read on the source-chain EVM, emits the result, and proves that event
to Creditcoin through Attestcoin. **The source chain computes the answer. The prober only
decides when to ask.**

```mermaid
flowchart LR
  A["Ethereum<br/>contract state"] -->|staticcall| B["StateProbe"]
  B -->|Probed event| C["Attestcoin<br/>transaction proof"]
  C --> D["LensRegistry<br/>on Creditcoin"]
  D --> E["ReserveMonitor"]
  D --> F["AggregatorV3 adapter"]
  D --> G["Governance, roles"]
  D --> H["other Creditcoin apps"]
```

Lens is not another application built on Attestcoin. It is a reusable read layer for
applications built on Attestcoin: one feed can serve many consumers, and one integration
expands the data available to all of them.

## Live demo

<https://lens.54-154-121-30.sslip.io>

The page reads Creditcoin and the source chains directly in your browser — there is no
server and nothing cached. Pick a feed, watch the four stages, and press **Verify** to
re-run the same call at the proven block and compare the bytes yourself. Both Sepolia
and Ethereum mainnet feeds recheck live: the page carries a short list of public
endpoints that serve historical state, and only if every one of them declines does it
say "could not check" rather than showing a false result.

## Why Lens exists

Attestcoin already gives Creditcoin contracts cryptographic evidence about transactions
and events on supported chains. Lens extends that model to read-only contract queries by
turning the EVM's answer into an attestable event.

| Attestcoin natively proves | Lens lets a contract verify |
|---|---|
| this transaction was included | what did this view function return? |
| this event was emitted | what were this vault's reserves? |
| this payment happened | what was voting power at block N? |
| | does this address hold this role? |
| | what is this checkpointed exchange rate? |

No protocol upgrade is required. There are no storage proofs here and none are claimed:
the contract answers, the answer is emitted, the emission is proven.

## How one proof works

1. **Source read.** `StateProbe` on Ethereum staticcalls the target with the caller's
   calldata and emits `Probed(target, callHash, …, blockNumber, blockTimestamp, returnData)`.
   The EVM produced the bytes; the prober supplied only the question.
2. **Attestation.** Creditcoin's validators attest the source chain. The frontier trails
   the head by 30–40 blocks, measured.
3. **Proof.** A prober submits the transaction's Merkle and continuity proofs to
   `LensRegistry`, which verifies them through the BlockProver precompile and then runs
   its own six checks (receipt status, single use, attested range, newest wins, chain key
   bound to native chain id, registered emitter).
4. **Consumption.** The registry stores the bytes with the source block and the source
   clock. Consumers read with a freshness bound in source blocks and are refused — with a
   distinct error — when the value is missing, failed, truncated or stale.

The security sentence: **the caller can choose when to ask. It cannot choose the answer.**
A forged probe fails at the precompile. A withheld probe makes the feed stale, and stale
is refused.

## Live deployments

| Contract | Chain | Address |
|---|---|---|
| `LensRegistry` | Creditcoin CC3 testnet | [`0x5c5bEE8b3D942cB7782071e13A272C7AE9f7C907`](https://creditcoin-testnet.blockscout.com/address/0x5c5bEE8b3D942cB7782071e13A272C7AE9f7C907) |
| `LensAggregatorV3` | Creditcoin CC3 testnet | [`0x134dbefE46b803ADab301D3c85f33E82a16A3993`](https://creditcoin-testnet.blockscout.com/address/0x134dbefE46b803ADab301D3c85f33E82a16A3993) |
| `ReserveMonitor` · `LensMarket` · `VotePort` · `SnapshotProver` · `CircuitBreaker` · `FeedEscrow` | Creditcoin CC3 testnet | [`docs/EVIDENCE.md`](docs/EVIDENCE.md) |
| `StateProbe` | Ethereum mainnet | [`0x81b6DcbcE28EC0634DC905cfDc5eA84005915852`](https://etherscan.io/address/0x81b6DcbcE28EC0634DC905cfDc5eA84005915852) |
| `StateProbe` | Ethereum Sepolia | [`0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115`](https://sepolia.etherscan.io/address/0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115) |

Every current deployment matches the checked-in bytecode (`node tools/check-deployed.mjs`),
all eleven CC3 contracts and both probes are source-verified, and [`deployments.json`](deployments.json)
is the single committed list the tools and the web page read from.

**CC3 testnet attests Ethereum mainnet**, so a testnet deployment reads real mainnet
state: the stETH exchange rate, ENS's historical voting supply and a Uniswap observation
are proven feeds today. Chain keys differ per environment (Ethereum mainnet is key 3
here), so the registry resolves and asserts them at construction rather than hardcoding
them.

## What Lens is good for

Verified cross-chain state for values whose meaning survives finality:

- liquid-staking exchange rates
- reserve and backing checkpoints, total supply
- historical governance weight
- access-control roles and pause flags
- time-averaged inputs such as a 30-minute Uniswap observation
- any checkpointed value a contract keeps itself

## Limits

What Lens cannot do, volunteered rather than discovered.

- **Not a spot feed.** The attestation frontier trails the source head by 30–40 blocks,
  seven to eight minutes, advancing ten blocks at a time; source block to readable on
  Creditcoin measured p50 8.7 min, p95 11.4 min over three days (`docs/LATENCY.md`).
  Lens is the wrong tool for an instantaneous AMM quote, a perp mark price, a
  block-sensitive liquidation engine or a sub-minute trading signal. Those need a feed
  that can be wrong quickly rather than one that is right slowly.
- **No storage proofs.** Historical state is available only where a contract keeps its
  own checkpoints — `ERC20Votes.getPastVotes`, Compound-style `getPriorVotes`, Uniswap's
  `observe`. A plain ERC-20 can only ever report its balance now, and no amount of
  probing changes that.
- **A carried feed keeps its origin's trust.** A value whose source is Chainlink is still
  a Chainlink value when Lens carries it. What Lens removes is the additional trusted
  cross-chain reporter or bridge, nothing more.
- **Creditcoin's validators remain.** A value is as trustworthy as the attestation of the
  block it came from. Every Attestcoin application shares that assumption; Lens is built
  on it, not free of it.
- **EVM only.** Attestcoin readability is EVM-only, so Lens is. A new source chain is a
  configuration row, but it has to be an EVM chain Creditcoin attests.
- **Sepolia prices mean nothing.** Sepolia's pools have no real liquidity; the Sepolia
  price feed is Chainlink's real aggregator or nothing. Pool-derived values come from
  Ethereum mainnet, where the stETH, ENS and Uniswap feeds live.
- **The demonstration governance token is ours.** `LensVoteToken` on Sepolia is a real
  OpenZeppelin `ERC20Votes` deployment, but we deployed it and hold the supply, because
  Sepolia has almost no checkpointed governance tokens. Every other part of the path is
  the production one, and the same technique is proven on mainnet against ENS's own
  checkpoints; pointing `VotePort` at a widely-held token changes one constructor argument.
- **No median is deployed.** `MedianFeed` is implemented and tested, but with one prober
  and feeds that do not overlap between chains any median would average a value against
  itself, so none is deployed.
- **Coverage is not uniform.** 95.01% of lines, 89.94% of statements and 61.90% of
  branches across `contracts/src`. `StateProbe` reads around 52% of lines because its
  read path is inline assembly the instrument cannot see; it is covered by unit tests,
  fork tests against real mainnet contracts and every end-to-end run.
- **The symbolic proof covers the consumer, not the registry.** Five properties of the
  freshness arithmetic are proved for all inputs with halmos against a registry model.
  The registry's own six checks are tested adversarially, not proved.
- **Mainnet history depends on someone serving it.** Byte comparisons at a proven height
  need a node that still holds that state. Four public endpoints do today, without a
  key, and the tools try each in turn; if every one declines, the result is
  "inconclusive", never "diverged". The comparison was also made at proof time and is
  recorded in `docs/EVIDENCE.md`.
- **Three days of latency data, not thirty.** The distribution comes from 58 proof
  landings on Sepolia and 4 on mainnet between 10 and 13 September. Consistent, but
  short.

## Security model

A prober is trusted for liveness, never correctness. Correctness comes from the
source-chain EVM and the proof; the registry adds six checks, each with an adversarial
test that hands it a *valid* proof and confirms it still refuses. There is no owner, no
pause key and no upgrade path in any Lens contract. Age is measured in source-chain
blocks against the attested frontier, never wall-clock. The full model, the attacks
considered and the two-clocks problem: [`docs/SECURITY.md`](docs/SECURITY.md).

## Try it

Without cloning anything:

```
cast call 0x5c5bEE8b3D942cB7782071e13A272C7AE9f7C907 'frontierOf(uint64)(uint64)' 3 \
  --rpc-url https://rpc.cc3-testnet.creditcoin.network
```

That is Ethereum mainnet's attested height, read by a contract on Creditcoin through the
precompile. Then, from a clone (`SETUP.md` has the prerequisites):

```
node tools/verify-infra.mjs      # every dependency, re-derived from the live network
node tools/verify-claims.mjs     # every claim in these docs, checked against the chains
node tools/differential.mjs      # every value held, against the source that produced it
node tools/web-smoke.mjs         # everything the web page reads, resolved live
```

To make a new feed live: add it to `prober/lib/config.mjs`, then
`node prober/probe.mjs <name>` and `node prober/prove.mjs <tx> <chainId>`. The web
page's **Build a feed** panel derives the feed id and checks the target for you first.

## Integrate

Solidity, by inheriting `LensConsumer` and resolving the source chain key for your
environment at deployment; `AggregatorV3Interface`, through `LensAggregatorV3` for
slow-moving or time-averaged feeds; or JavaScript, through the SDK in [`sdk/`](sdk/),
which takes native chain ids and refuses explicitly. Details, bounds to choose and how to
handle refusal: [`docs/INTEGRATING.md`](docs/INTEGRATING.md).

## Testing and evidence

```
forge test                       # 200 tests: unit, adversarial, invariant, property, mainnet fork
npm run coverage                 # line, statement and branch coverage, labelled separately
```

Unit, fork against real mainnet contracts, adversarial (one test per way of getting a
wrong answer in), invariant (12 properties across four handlers), property tests over the
freshness arithmetic, and a differential run against live feeds. Coverage is 95.01% of
lines (see Limits for the assembly caveat).

```
halmos --match-contract FreshnessSymbolicTest   # 5 properties proved for all inputs
```

The consumer's freshness arithmetic is proved symbolically in
`contracts/test/symbolic/`: a value is handed out only when present, succeeded, whole,
not regressed and within the bound; every input meeting those conditions is accepted; a
refusal never carries bytes; a regressed frontier is the maximum age, never zero; and
the reverting and reporting reads agree. No mocks sit in any demo path: the stubs in
`contracts/test/helpers` drive the registry through states the live network will not
hold still for, and every behaviour they cover is also exercised on-chain.

Every address, transaction and measurement behind a claim is in
[`docs/EVIDENCE.md`](docs/EVIDENCE.md); lag and gas, each with its receipt, in
[`docs/LATENCY.md`](docs/LATENCY.md).

## Repository map

| | |
|---|---|
| `contracts/src` | `StateProbe`, `LensRegistry`, `LensConsumer`, `LensAggregatorV3`, composer, breaker, escrow, four consumers |
| `contracts/test` | unit, adversarial, invariant, property, symbolic and fork suites |
| `prober/` | probe, prove, batch, keep, watch, doctor — the operator CLI |
| `sdk/` | the JavaScript SDK |
| `web/` | the static explorer; `config.js` is generated from `prober/lib/config.mjs` |
| `tools/` | deployment, parity, claim, infra and web verification |
| `docs/` | [`SECURITY`](docs/SECURITY.md) · [`INTEGRATING`](docs/INTEGRATING.md) · [`EVIDENCE`](docs/EVIDENCE.md) · [`LATENCY`](docs/LATENCY.md) · [`VERIFIED`](docs/VERIFIED.md) · [`FUNDING`](docs/FUNDING.md) |
| `SETUP.md` | building and running |

## Roadmap

Lens can become shared verified-state infrastructure for Creditcoin applications. What is
built and what is next, labelled honestly:

- **Feed funding.** `FeedEscrow` is deployed: a protocol that needs a feed funds its
  updates, any eligible prober does the work and earns the configured reward, and
  correctness still comes from proof verification rather than from trusting the prober.
  It is a primitive today, not a production marketplace.
- **External integrators** on Creditcoin consuming existing feeds.
- **A productionised keeper** with a funded mainnet prober and a latency distribution
  over weeks rather than days.
- **More Attestcoin-supported EVM sources** — a configuration row each, no contract change.
- **Richer composition** for checkpointed state, and SDK publication on npm.

Prior art, acknowledged: the staticcall-and-emit pattern is known, and Herodotus, Axiom
and Lagrange solve state proofs cryptographically on Ethereum. What is original here is
the Attestcoin application, the freshness standard bound to the attestation frontier, the
fail-closed consumer standard, the checkpointed-history technique and the composition
layer.
