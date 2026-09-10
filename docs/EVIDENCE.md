# Evidence

Every address and transaction behind a claim in this repository. Nothing here is a
plan; each row is on a public chain and can be checked without asking us.

## Deployed

| What | Chain | Address | Status |
|---|---|---|---|
| `StateProbe` | Ethereum Sepolia (chain key 1) | [`0xC335466ffcac94fCe7820326930888dAA9204a23`](https://sepolia.etherscan.io/address/0xC335466ffcac94fCe7820326930888dAA9204a23) | current |
| `StateProbe` | Ethereum mainnet (chain key 3) | `0xC335466ffcac94fCe7820326930888dAA9204a23` | same address, awaiting funding |
| `LensRegistry` | Creditcoin CC3 testnet | [`0x81b6DcbcE28EC0634DC905cfDc5eA84005915852`](https://creditcoin-testnet.blockscout.com/address/0x81b6DcbcE28EC0634DC905cfDc5eA84005915852) | current |
| `LensAggregatorV3`, ETH/USD | Creditcoin CC3 testnet | [`0x43E5d502Fa15bE5ef70799B629718fb4CF490fF5`](https://creditcoin-testnet.blockscout.com/address/0x43E5d502Fa15bE5ef70799B629718fb4CF490fF5) | current |
| `ReserveMonitor` | Creditcoin CC3 testnet | `0xD51bEE1d6b2f013d907D3e13e570b2b6586e0c72` | current |
| `LensMarket` | Creditcoin CC3 testnet | `0xEE527a62C239E4664e887c0e248eAc741E0EF9EF` | current |
| `VotePort` | Creditcoin CC3 testnet | `0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115` | current |
| `SnapshotProver` | Creditcoin CC3 testnet | `0xaef8215c3048687Cf3d0346cB9FcB1BE67c12647` | current |
| `CircuitBreaker` | Creditcoin CC3 testnet | `0xf219a37884B5314dD5057d0C4051aa0349907066` | current |
| `FeedEscrow` | Creditcoin CC3 testnet | `0x4f6b5262221a6fBDE2126174577f4E9956ddFa04` | current |
| `LensVoteToken` | Ethereum Sepolia | `0x99E1749Fd45Bb14CF59139b04Cc387981f3ef66e` | a real ERC20Votes, see below |

### Superseded, and why

The first pair are still on chain and still work. They are listed because the
transactions below were made against them, and a record that quietly drops its earlier
addresses is not a record.

| What | Chain | Address |
|---|---|---|
| `StateProbe` | Sepolia | `0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe` |
| `LensRegistry` | CC3 testnet | `0xFCCd509F4EbB8Bc9Baf8cAA965231F8ACCf2DaaA` |

They were replaced because the probe emitted only the source-chain *height* of a read,
not its *time*. That is unrecoverable downstream: the timestamp is absent from the proven
transaction encoding, and Creditcoin's own clock reads minutes later because the
attestation lag sits between them. A Chainlink-shaped consumer comparing
`block.timestamp - updatedAt` would have measured the wrong gap and believed the value
fresher than it was. The probe now emits both clocks and the registry keeps them apart.

The probe is deployed through the standard deterministic deployer with the salt
`keccak256("lens.state-probe.v2")`, so its address is a property of its bytecode rather
than of who deployed it or when. Anyone can verify the address without trusting us:

```
cast compute-address --create2 \
  --salt $(cast keccak "lens.state-probe.v1") \
  --init-code-hash <keccak of the current StateProbe creation code> \
  0x4e59b44847b379578588920cA78FbF26c0B4956C
```

That also means the mainnet probe is already pinned: when the key is funded, the same
bytecode lands at the same address, and the registry needs no change.

### Transactions

| What | Chain | Hash |
|---|---|---|
| `StateProbe` deployment | Sepolia | [`0x00534c2a78f3b7ec070aa9376ed9029ed50fa37a8a55ce2f3dffac1b9751d967`](https://sepolia.etherscan.io/tx/0x00534c2a78f3b7ec070aa9376ed9029ed50fa37a8a55ce2f3dffac1b9751d967) |
| First probe, Sepolia WETH `totalSupply()` | Sepolia | [`0xe5124c2b39622e95399153908fc3f30b474e5a48d9f32ff54e014f97b2da6e7f`](https://sepolia.etherscan.io/tx/0xe5124c2b39622e95399153908fc3f30b474e5a48d9f32ff54e014f97b2da6e7f) |
| Two feeds probed in one transaction | Sepolia | [`0x29a8a7be2ff3cde02fd767771b09fc6e4ac2f5c1c4c6584f3b04251657946e0d`](https://sepolia.etherscan.io/tx/0x29a8a7be2ff3cde02fd767771b09fc6e4ac2f5c1c4c6584f3b04251657946e0d) |
| Both proven in one submission | CC3 testnet | [`0x82653274dbb461627b6c5d96f6ba9d37681ce7a21145a4c5da7e9b95ce3c8f6d`](https://creditcoin-testnet.blockscout.com/tx/0x82653274dbb461627b6c5d96f6ba9d37681ce7a21145a4c5da7e9b95ce3c8f6d) |
| That probe proven and recorded | CC3 testnet | [`0xd9290d8dc006cead38f120e9edc5bd241d810dd412a79f92e16b37821ed22668`](https://creditcoin-testnet.blockscout.com/tx/0xd9290d8dc006cead38f120e9edc5bd241d810dd412a79f92e16b37821ed22668) |
| `LensRegistry` deployment, superseded | CC3 testnet | [`0xece577fa31a23b930c69044c9f4ae16c4592eab1e72f0bce9f32026c47056090`](https://creditcoin-testnet.blockscout.com/tx/0xece577fa31a23b930c69044c9f4ae16c4592eab1e72f0bce9f32026c47056090) |
| `StateProbe` deployment, current | Sepolia | contract `0xC335466ffcac94fCe7820326930888dAA9204a23` |
| `LensRegistry` deployment, current | CC3 testnet | [`0xf8cdec304aedc50478a4055ab4b0632721388387895b0fd5b88cc1761afc8293`](https://creditcoin-testnet.blockscout.com/tx/0xf8cdec304aedc50478a4055ab4b0632721388387895b0fd5b88cc1761afc8293) |

### Deployed state, read back from the chain

On the probe, Sepolia:

| Call | Answer |
|---|---|
| `MAX_RETURN_BYTES()` | 8192 |
| `MAX_PROBE_GAS()` | 2000000 |

On the registry, CC3 testnet. These are the interesting ones: a contract on Creditcoin
answering questions about Ethereum, through the precompile, with no oracle involved.

| Call | Answer |
|---|---|
| `frontierOf(3)` — Ethereum mainnet | 25,948,180 |
| `frontierOf(1)` — Sepolia | 11,676,100 |
| `frontierOf(99)` — a key that is not attested | reverts `UnknownChainKey` |
| `MAX_BATCH()` | 10, matching the precompile's limit on queries under one continuity proof |
| `PROBED_SIGNATURE()` | `0x2373d36eb926cb2c85ee44b32054271c7ae2854ea55412b676125465f04b94fc` |

The chain-key binding was asserted on-chain by the constructor and can be read back:

| Chain key | Native chain id | Probe |
|---|---|---|
| 3 | 1 (Ethereum mainnet) | `0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe` |
| 1 | 11155111 (Sepolia) | `0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe` |

The registry refused to deploy until those keys matched what ChainInfo reports for this
environment, so a deployment pointed at the wrong environment fails at construction
rather than reporting the wrong chain's state.

## Measured

| Measurement | Value | Where |
|---|---|---|
| Attestation lag, Ethereum mainnet | 39 blocks, about 7.8 minutes | `VERIFIED.md` |
| Attestation lag, Sepolia | 41 blocks, about 8.2 minutes | `VERIFIED.md` |
| Three real mainnet feeds in one probe transaction | 155,260 gas | `READ-PATH.md` |
| Proving one feed to Creditcoin | 200,480 gas | measured |
| Proving one source transaction carrying two feeds | 231,101 gas | measured |
| **Marginal cost of a second feed in the same source transaction** | **30,621 gas** | the two rows above |

That last number is the argument for batching. The first feed in a proof costs 200,480
gas; the second costs 30,621, because the continuity proof is paid for once and the
Merkle proof is all that is added per query. The precompile accepts ten queries under one
continuity proof, so a full batch approaches roughly 48,000 gas per feed against 200,480
for the same ten proven one at a time — about a quarter of the cost.
| `StateProbe` deployment | 385,849 gas, 0.00094 ETH at 1.2 gwei | this file |


## The loop, closed

A value read on one chain, proven to another, and shown to be the same value.

| Step | Where | Result |
|---|---|---|
| Read `totalSupply()` on Sepolia WETH | Sepolia, block 11,676,153 | 218,248.508 WETH |
| Probe it | Sepolia | 29,380 gas |
| Wait for attestation | Creditcoin | about 8 minutes, 33 blocks |
| Build the proof | prover.cc3-testnet | 1,920 transaction bytes, 7 Merkle siblings, 8 continuity roots |
| Submit it | CC3 testnet | 200,480 gas, Creditcoin block 5,464,540 |
| Read it back | CC3 testnet | `0x…2e37467cb64a9aa49304` |

Anyone can check the last line against the source without trusting this repository:

```
cast call 0xFCCd509F4EbB8Bc9Baf8cAA965231F8ACCf2DaaA \
  'observationOf(bytes32)((bytes,uint256,uint64,bool,bool,address))' \
  0x7296382ac1d2e0419f5ff0588bf91e56d9cd0399882670559a3361c8ec796346 \
  --rpc-url https://rpc.cc3-testnet.creditcoin.network

cast call 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 'totalSupply()(uint256)' \
  --block 11676153 --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

Both give 218248508270969010557700.

### A Chainlink price, proven

Sepolia's Chainlink ETH/USD aggregator read through Lens, at source block 11,676,425:

| Where | Bytes | Value |
|---|---|---|
| On Sepolia, directly | `0x…3970a509c0` | $2,467.03 |
| On Creditcoin, proven | `0x…3970a509c0` | $2,467.03 |

Worth stating plainly: this is a Chainlink feed carried onto a chain Chainlink does not
serve, without Chainlink's participation and without anyone being trusted to report it
honestly. The number is not relayed. The read happened on Sepolia, and the log proving it
happened was verified by the precompile.

### The two clocks, measured on chain

The probe emits the source-chain time of the read because nothing downstream can recover
it. Here is why that matters, taken from the live deployment rather than a test:

| | Value | |
|---|---|---|
| Sepolia block 11,676,454 timestamp | 1789062012 | 17:40:12 UTC |
| `sourceTimestamp` recorded on Creditcoin | 1789062012 | 17:40:12 UTC — exact match |
| `recordedAt`, Creditcoin's own clock | 1789062570 | 17:49:30 UTC |
| Gap | **558 seconds** | |

A Chainlink-shaped consumer computes age as `block.timestamp - updatedAt`. Had `updatedAt`
carried Creditcoin's clock, every price would have looked **558 seconds younger than it
was**, and a staleness check set to nine minutes would have passed on a value nine and a
half minutes old. The adapter reports the source clock, so the check measures the real
number.

### A Chainlink feed served through Chainlink's own interface

`LensAggregatorV3` at `0x43E5…0fF5`, read exactly as any lending market reads a price:

| Call | Answer |
|---|---|
| `description()` | `sepolia.chainlink.ethUsd` |
| `decimals()` | 8 |
| `version()` | 4 |
| `latestRoundData().answer` | `246703000000` — $2,467.03 per ETH |
| `latestRoundData().roundId` | 11,676,454 — the source height the read happened at |
| `latestRoundData().updatedAt` | 1789062012 — the source clock |
| `ageInBlocks()` | 6 source blocks |

The round id is the source-chain height rather than a counter, which makes a round a
statement about where on the source chain the value came from.

### A vote cast on Creditcoin with weight proven from another chain

The governance claim, carried out rather than described. Proposal 0 on
`0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115`:

| | |
|---|---|
| Proposal | "Adopt Lens as the reference feed for this treasury" |
| Snapshot | Sepolia block 11,676,782 |
| `provenWeight(voter, 11676782)` | 1,000,000 LVOTE |
| `forVotes` after the vote | 1,000,000 LVOTE |
| `weightUsed` | 1,000,000 LVOTE |
| A second vote from the same address | reverts `AlreadyVoted(0, 0xcf7a…)` |

| Step | Chain | Hash |
|---|---|---|
| Probe the holder's weight at the snapshot | Sepolia | `0x6f80012b138dfbbefe0166e1a94ac16700d795de6fa035f6d8f76c32c352d1f6` |
| Open the proposal | CC3 testnet | `0x1abd0b22275a7c7e48538212c4ada66a6a4e981a9ef7dc7dc5a5c387a2d67346` |
| Cast the vote | CC3 testnet | `0x1fbd183ee2fec918733f100f101f54bcf311b4af262dccaa3b9870dd4846adf5` |

No token moved. No bridge, no snapshot API, no tally anybody had to be trusted about. The
weight was read from the token's own checkpoints on Sepolia and the log proving that read
was verified by the precompile.

**About the token.** `LensVoteToken` is a real OpenZeppelin `ERC20Votes` deployment, not a
mock, but it is ours: Sepolia has almost no checkpointed governance tokens and the UNI
deployment that exists is held by nobody who could demonstrate with it. Its checkpoints
are genuine — `getPastVotes` returns 0 at block 11,676,781 and 1,000,000 at 11,676,782,
the block the delegation landed in. Every other part of the path is the production one,
and pointing this at a widely-held token changes one constructor argument.

### Both kinds of batching, measured

| What | Chain | Hash |
|---|---|---|
| Two queries from different blocks, one shared continuity proof | CC3 testnet | [`0xf05c6f49ff2d9ed8e41eaf21853c49a8ebe03a274249acc8c7ca3d95e98218c4`](https://creditcoin-testnet.blockscout.com/tx/0xf05c6f49ff2d9ed8e41eaf21853c49a8ebe03a274249acc8c7ca3d95e98218c4) |

Sepolia blocks 11,677,327 and 11,677,331, spanned by 14 continuity roots, recorded in one
Creditcoin transaction: **261,492 gas, 130,746 per query**, against 200,480 to prove one
alone. That is 35% cheaper than proving the two separately.

An earlier version of this file called the 231,101 figure a shared continuity proof. It
was not: that transaction called `submitProof` on a single source transaction carrying two
logs. Both mechanisms are real and their costs differ — 30,621 gas for another log in the
same transaction, 61,012 for another query under a shared continuity chain.

### The refusals, on the live chain

Rejections are asserted in tests, but two of them have now also been observed on
Creditcoin itself rather than against a stub:

| Attempt | Result |
|---|---|
| Submit the same proof a second time | `QueryAlreadyConsumed(queryKey=0xa31c4e17c23099854734310d55fea1faa760d2dbb544abe119ef90ddf412904c)` |
| `frontierOf(99)`, a chain key this environment does not attest | `UnknownChainKey(99)` |

A valid proof stays valid forever, which is exactly why it has to be spent once.


## Not yet done

Listed so this file is a record rather than an advertisement.

| Missing | Consequence |
|---|---|
| `HistoryProbe`, `LensComposer`, `CircuitBreaker`, `FeedEscrow` | no historical reads, no medians or ratios, no automatic breaker, no liveness incentive |
| All four consumers | the platform claim rests on the shim and the registry alone so far |
| Invariant, symbolic and differential tests | the eight invariants are argued in comments, not enforced by a runner |
| `LensConsumer` has no test of its own | it compiles and nothing executes it |
| Contract verification on Blockscout and Sourcify | a reader can call the contracts but cannot read their source on an explorer |
| Mainnet probe | the address is pinned and the bytecode is fixed, but nothing is deployed there |
| SDK, indexer, templates, web app | nothing to point a stranger at yet |
