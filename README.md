# Lens

**Verified cross-chain state on Creditcoin. No oracle, no bridge, no trusted party.**

Attestcoin proves what a transaction *did*. It cannot prove what a contract *is* — there
are no storage proofs, only transaction and event inclusion. So a contract on Creditcoin
can prove "Alice sent 500 USDC" but not "what is Alice's balance", "what is ETH worth", or
"is this vault solvent". Every DeFi application on Creditcoin still imports a centralised
price feed, on the chain marketed as eliminating oracles.

**Lens turns state into a transaction.** A permissionless contract on the source chain
staticcalls a target and emits the returndata. The EVM performs the read. The result lands
in a block, the block is attested, and the log is proven to Creditcoin through the
readability path that already exists.

No protocol change. No trusted party. No incentive assumption on correctness.

## The security sentence

> A prober is trusted for **liveness, never correctness**. A forged probe fails at the
> precompile. A withheld probe causes **refusal, never a wrong answer**.

## Live now

| Contract | Chain | Address |
|---|---|---|
| `LensRegistry` | Creditcoin CC3 testnet | [`0x81b6DcbcE28EC0634DC905cfDc5eA84005915852`](https://creditcoin-testnet.blockscout.com/address/0x81b6DcbcE28EC0634DC905cfDc5eA84005915852) |
| `LensAggregatorV3` | Creditcoin CC3 testnet | [`0x43E5d502Fa15bE5ef70799B629718fb4CF490fF5`](https://creditcoin-testnet.blockscout.com/address/0x43E5d502Fa15bE5ef70799B629718fb4CF490fF5) |
| `ReserveMonitor` · `LensMarket` · `VotePort` · `SnapshotProver` | Creditcoin CC3 testnet | see [`docs/EVIDENCE.md`](docs/EVIDENCE.md) |
| `CircuitBreaker` · `FeedEscrow` | Creditcoin CC3 testnet | see [`docs/EVIDENCE.md`](docs/EVIDENCE.md) |
| `StateProbe` | Ethereum Sepolia **and** mainnet | [`0xC335466ffcac94fCe7820326930888dAA9204a23`](https://etherscan.io/address/0xC335466ffcac94fCe7820326930888dAA9204a23) |

Every Creditcoin contract is verified on Blockscout. The probe has the same address on
both source chains because it is deployed through the standard deterministic deployer, so
its address is a property of its bytecode rather than of who deployed it.

**CC3 testnet attests Ethereum mainnet** — chain key 3, confirmed at runtime. A testnet
deployment reading real mainnet state is the point, not a workaround.

## Check it yourself

```
node tools/verify-infra.mjs      # every dependency, re-derived from the live network
node tools/verify-claims.mjs     # every claim in these docs, checked against the chains
node tools/differential.mjs      # every value held, against the source that produced it
```

Or without cloning anything:

```
cast call 0x81b6DcbcE28EC0634DC905cfDc5eA84005915852 'frontierOf(uint64)(uint64)' 3 \
  --rpc-url https://rpc.cc3-testnet.creditcoin.network
```

That returns Ethereum mainnet's attested height, read by a contract on Creditcoin through
the precompile, with no oracle in the path.

## Limits, up front

- **Not a spot feed.** The attestation frontier trails the source head by 30–40 blocks,
  about 7–8 minutes, measured. Lens carries time-averaged and checkpointed values, where
  lag is part of what the number means.
- **Historical state only where a contract keeps its own checkpoints** —
  `ERC20Votes.getPastVotes`, Compound-style checkpoints, Uniswap's `observe`. There are no
  storage proofs here and none are claimed.
- **The demonstration governance token on Sepolia is ours**, because Sepolia has almost no
  checkpointed governance tokens. Every other part of that path is the production one.
- **No symbolic proofs.** halmos could not be installed; the freshness arithmetic is
  covered exhaustively and by fuzz instead, which is not the same thing.

Fuller: [`docs/LIMITS.md`](docs/LIMITS.md).

## Prior art

The staticcall-and-emit pattern is known. Herodotus, Axiom and Lagrange solve state proofs
cryptographically on Ethereum. Chainlink's `AggregatorV3Interface` is the de-facto consumer
shape and Lens implements it deliberately.

Original here: the Attestcoin application; a freshness standard bound to the attestation
frontier; a consumer standard where staleness fails closed; the checkpointed-history
technique; and the composition layer.

## Documentation

| | |
|---|---|
| [`SECURITY.md`](docs/SECURITY.md) | the six checks and the attack each one stops |
| [`LIMITS.md`](docs/LIMITS.md) | what this cannot do |
| [`INTEGRATING.md`](docs/INTEGRATING.md) | reading a feed, and choosing a freshness bound |
| [`VERIFIED.md`](docs/VERIFIED.md) | every dependency, re-derived from the live network |
| [`EVIDENCE.md`](docs/EVIDENCE.md) | every address and transaction behind a claim |
| [`LATENCY.md`](docs/LATENCY.md) | measured attestation lag and gas |
| [`SETUP.md`](SETUP.md) | building and running |

## Tests

```
forge test          # 184 tests
node tools/differential.mjs
```

Unit, fork against real mainnet contracts, adversarial (one test per way of getting a
wrong answer in), invariant (12 properties across four handlers, 16,384 generated calls
each), property tests over the freshness arithmetic, and a differential run against live
feeds. Coverage is currently 93.16% of lines across `contracts/src`; the 95% release threshold remains open.

There are no symbolic proofs: halmos could not be installed here, and the freshness
arithmetic is covered exhaustively and by fuzz instead. Those are different claims and
`LIMITS.md` keeps them apart.

**No mocks in any demo path.** The stubs in `contracts/test/helpers` exist to drive the
registry through states the live network will not hold still for — a rewinding frontier, a
chain with nothing attested — and every behaviour they cover is also exercised on-chain.
