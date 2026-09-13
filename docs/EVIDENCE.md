# Evidence

Every address and transaction behind a claim in this repository. Nothing here is a
plan; each row is on a public chain and can be checked without asking us.

## Deployed

| What | Chain | Address | Status |
|---|---|---|---|
| `StateProbe` | Ethereum Sepolia (chain key 1) | [`0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115`](https://sepolia.etherscan.io/address/0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115) | current |
| `StateProbe` | Ethereum mainnet (chain key 3) | [`0x81b6DcbcE28EC0634DC905cfDc5eA84005915852`](https://etherscan.io/address/0x81b6DcbcE28EC0634DC905cfDc5eA84005915852) | current |
| `LensRegistry` | Creditcoin CC3 testnet | [`0x5c5bEE8b3D942cB7782071e13A272C7AE9f7C907`](https://creditcoin-testnet.blockscout.com/address/0x5c5bEE8b3D942cB7782071e13A272C7AE9f7C907) | current |
| `LensAggregatorV3`, ETH/USD | Creditcoin CC3 testnet | [`0x134dbefE46b803ADab301D3c85f33E82a16A3993`](https://creditcoin-testnet.blockscout.com/address/0x134dbefE46b803ADab301D3c85f33E82a16A3993) | current |
| `ReserveMonitor` | Creditcoin CC3 testnet | `0xB40692dD5077B4b2e5A75AccF4F610bac8b9C288` | current |
| `LensMarket` | Creditcoin CC3 testnet | `0x4d983eD19F7b1dDae5b5B2D2C00dD481ea581DAe` | current |
| `VotePort` | Creditcoin CC3 testnet | `0xe43E5484Da58762800e7f495076658586295ccD0` | current |
| `SnapshotProver` | Creditcoin CC3 testnet | `0xc722549aCe290e165C76F32d76f5bab40dBe6Df8` | current |
| `CircuitBreaker` | Creditcoin CC3 testnet | `0x9ddC59f0F9b434B74A9ceB015Ee1c6861BbEc936` | current |
| `FeedEscrow` | Creditcoin CC3 testnet | `0x4bab50d47E054E32C91F19E4E30027422061f636` | current |
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

The current source probes are ordinary deployments from the prober wallet, so their
addresses are chain-specific facts. The registry stores the mainnet and Sepolia emitter
separately and the live constructor read-back confirms both mappings. A new probe build
is recorded with its source-chain deployment transaction before the registry is rebuilt.

### Transactions

| What | Chain | Hash |
|---|---|---|
| `StateProbe` deployment | Sepolia | [`0xf0a89d2f6694406d98510f400b2136a05f206d35863ff9a81e2e71d9c6b549ae`](https://sepolia.etherscan.io/tx/0xf0a89d2f6694406d98510f400b2136a05f206d35863ff9a81e2e71d9c6b549ae) |
| `StateProbe` deployment | Ethereum mainnet | [`0xfbc6952c018ac1155797efc638433308de874f96902c4bd51cc47dc6453aebf3`](https://etherscan.io/tx/0xfbc6952c018ac1155797efc638433308de874f96902c4bd51cc47dc6453aebf3) |
| Seven feeds probed in one transaction | Sepolia | [`0x4a8cff7cb6d67a26f0185942576a9f52789a24f4fa51a6667aae2a1d16893ccd`](https://sepolia.etherscan.io/tx/0x4a8cff7cb6d67a26f0185942576a9f52789a24f4fa51a6667aae2a1d16893ccd) |
| Seven observations proven under one continuity proof | CC3 testnet | [`0x6fad658a250c02e3e4b8120ac980a9811f51ae932af6966f1de924de7947d504`](https://creditcoin-testnet.blockscout.com/tx/0x6fad658a250c02e3e4b8120ac980a9811f51ae932af6966f1de924de7947d504) |
| Two mainnet feeds (ENS, Uniswap) probed in one transaction | Ethereum mainnet | [`0xf701eb273d6ea254c0aba772cba2cec4a43e971408a4b7e8df342f96f1734977`](https://etherscan.io/tx/0xf701eb273d6ea254c0aba772cba2cec4a43e971408a4b7e8df342f96f1734977) |
| Three mainnet observations, from two source transactions, proven under one continuity proof | CC3 testnet | [`0xb009222f40c89c837faf4bf61fcaaad8fd195bded8ae48a751487b21ac464cde`](https://creditcoin-testnet.blockscout.com/tx/0xb009222f40c89c837faf4bf61fcaaad8fd195bded8ae48a751487b21ac464cde) |
| Three mainnet feeds (stETH, ENS, Uniswap) probed in one transaction | Ethereum mainnet | [`0x2e0728a4315fba446b207c45074a62a2c59b6a875fa1d69a98536565c25ec27f`](https://etherscan.io/tx/0x2e0728a4315fba446b207c45074a62a2c59b6a875fa1d69a98536565c25ec27f) |
| `LensRegistry` deployment, current | CC3 testnet | [`0x235b8baec382ef0d7e7e0d6a9d3ea9a984ad1fe33b6a59b757b09a7caeaad036`](https://creditcoin-testnet.blockscout.com/tx/0x235b8baec382ef0d7e7e0d6a9d3ea9a984ad1fe33b6a59b757b09a7caeaad036) |
| `LensAggregatorV3` deployment, current | CC3 testnet | [`0x09ecabf2fd8dc3858f1f4e0354b1f55dce17f07bfd1169f9339390212ebf1964`](https://creditcoin-testnet.blockscout.com/tx/0x09ecabf2fd8dc3858f1f4e0354b1f55dce17f07bfd1169f9339390212ebf1964) |
| `RegistryFeed` backing deployment | CC3 testnet | [`0xdc58aeb56b5e1b18b0570860e358f92f9578c84ad8a9bb774a053213f996c352`](https://creditcoin-testnet.blockscout.com/tx/0xdc58aeb56b5e1b18b0570860e358f92f9578c84ad8a9bb774a053213f996c352) |
| `RegistryFeed` issued deployment | CC3 testnet | [`0x66bcab99f7c540a71325cfe089a256b6a7cc9829c2b86470f02df366d09e66c4`](https://creditcoin-testnet.blockscout.com/tx/0x66bcab99f7c540a71325cfe089a256b6a7cc9829c2b86470f02df366d09e66c4) |
| `RatioFeed` deployment | CC3 testnet | [`0x483b817a82514e25b3eed6d2c5e5ead2abcdc97c1886862ee8e5b161cb4e0ed2`](https://creditcoin-testnet.blockscout.com/tx/0x483b817a82514e25b3eed6d2c5e5ead2abcdc97c1886862ee8e5b161cb4e0ed2) |
| `ReserveMonitor` deployment | CC3 testnet | [`0x44478b5e14f27a0728ca1ec03f1ef064a72e14e191974f52472057de20c0fe31`](https://creditcoin-testnet.blockscout.com/tx/0x44478b5e14f27a0728ca1ec03f1ef064a72e14e191974f52472057de20c0fe31) |
| `LensMarket` deployment | CC3 testnet | [`0x6a6eec66de368572ab756e576b86105cefea3c032fb90f9779e6810d3db7418e`](https://creditcoin-testnet.blockscout.com/tx/0x6a6eec66de368572ab756e576b86105cefea3c032fb90f9779e6810d3db7418e) |
| `CircuitBreaker` deployment | CC3 testnet | [`0xf9cf8461e1990cefa85c2b90b34fd77892eaa7f098a36c1f48a3019969d2f884`](https://creditcoin-testnet.blockscout.com/tx/0xf9cf8461e1990cefa85c2b90b34fd77892eaa7f098a36c1f48a3019969d2f884) |
| `FeedEscrow` deployment | CC3 testnet | [`0xc7c0def5fdf2ea014669b9255d16adf5aa306e1f7a77b83ea575176433337050`](https://creditcoin-testnet.blockscout.com/tx/0xc7c0def5fdf2ea014669b9255d16adf5aa306e1f7a77b83ea575176433337050) |
| `VotePort` deployment | CC3 testnet | [`0xcd9d1ee636531ca7a6fe0e5e6ca6bc25fde7ce32fbb2136903430153cf2f560a`](https://creditcoin-testnet.blockscout.com/tx/0xcd9d1ee636531ca7a6fe0e5e6ca6bc25fde7ce32fbb2136903430153cf2f560a) |
| `SnapshotProver` deployment | CC3 testnet | [`0xc91f3684d4119acc6717af3dab4c7d543ae49eec6da8904d8a04d97920f0824a`](https://creditcoin-testnet.blockscout.com/tx/0xc91f3684d4119acc6717af3dab4c7d543ae49eec6da8904d8a04d97920f0824a) |

### Deployed state, read back from the chain

On both current source probes:

| Call | Answer |
|---|---|
| `MAX_RETURN_BYTES()` | 8192 |
| `MAX_PROBE_GAS()` | 2000000 |

On the registry, CC3 testnet. These are the interesting ones: a contract on Creditcoin
answering questions about Ethereum, through the precompile, with no oracle involved.

| Call | Answer |
|---|---|
| `frontierOf(3)` — Ethereum mainnet | 25,963,990 (live doctor read) |
| `frontierOf(1)` — Sepolia | 11,691,500 (live doctor read) |
| `frontierOf(99)` — a key that is not attested | reverts `UnknownChainKey` |
| `MAX_BATCH()` | 10, matching the precompile's limit on queries under one continuity proof |
| `PROBED_SIGNATURE()` | `0x2373d36eb926cb2c85ee44b32054271c7ae2854ea55412b676125465f04b94fc` |

The chain-key binding was asserted on-chain by the constructor and can be read back:

| Chain key | Native chain id | Probe |
|---|---|---|
| 3 | 1 (Ethereum mainnet) | `0x81b6DcbcE28EC0634DC905cfDc5eA84005915852` |
| 1 | 11155111 (Sepolia) | `0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115` |

The registry refused to deploy until those keys matched what ChainInfo reports for this
environment, so a deployment pointed at the wrong environment fails at construction
rather than reporting the wrong chain's state.

## Measured

| Measurement | Value | Where |
|---|---|---|
| Attestation lag, Ethereum mainnet | 36 blocks, about 7 minutes | `VERIFIED.md` |
| Attestation lag, Sepolia | 37 blocks, about 7 minutes | `VERIFIED.md` |
| Seven Sepolia feeds in one `probeMany` transaction | 129,311 gas | source receipt `0x4a8cff...` |
| Three mainnet feeds in one `probeMany` transaction | 143,660 gas | source receipt `0x2e0728...`, 2026-09-13 |
| Two mainnet feeds (ENS, Uniswap) in one `probeMany` transaction | 99,139 gas | source receipt `0xf701eb...`, 2026-09-12 |
| Seven Sepolia observations under one continuity proof | 982,017 gas | CC3 receipt `0x6fad658a...` |
| Three mainnet observations, two source transactions, one continuity proof | 703,124 gas | CC3 receipt `0xb009222f...` |
| Three mainnet observations, one source transaction | 276,066 gas | CC3 receipt `0xf34bfd...`, 2026-09-13 |
| Mainnet stETH probe measured model | 89,292 gas limit; 57,134 used | source receipt `0x7256839a...` |

These receipts are the live batching evidence. The source-side measured model reserves
the wrapper baseline plus the target's direct estimate, including the EVM's 63/64 gas
forwarding rule; it is not a fixed multiplier. The proof path pays one shared continuity
chain per batch, so seven observations fit in one CC3 transaction rather than seven
separate submissions.


## The loop, closed

A value read on one chain, proven to another, and shown to be the same value.

### Current live Sepolia path

| Step | Where | Result |
|---|---|---|
| Read `totalSupply()` on Sepolia WETH | Sepolia, block 11,691,162 | 218,056.249 WETH |
| Probe it in a seven-feed batch | Sepolia | [`0x4a8cff7cb6d67a26f0185942576a9f52789a24f4fa51a6667aae2a1d16893ccd`](https://sepolia.etherscan.io/tx/0x4a8cff7cb6d67a26f0185942576a9f52789a24f4fa51a6667aae2a1d16893ccd), 129,311 gas |
| Wait for attestation | Creditcoin | frontier 11,691,500 at the doctor sample; 338 source blocks behind |
| Build and submit the shared proof | CC3 testnet | [`0x6fad658a250c02e3e4b8120ac980a9811f51ae932af6966f1de924de7947d504`](https://creditcoin-testnet.blockscout.com/tx/0x6fad658a250c02e3e4b8120ac980a9811f51ae932af6966f1de924de7947d504), 982,017 gas, block 5,477,003 |
| Read it back | CC3 testnet | `0x…2e2cda5a0da5116714fe` |

Anyone can check the last line against the source without trusting this repository:

```
cast call 0x5c5bEE8b3D942cB7782071e13A272C7AE9f7C907 \
  'observationOf(bytes32)((bytes,uint256,uint64,uint64,bool,bool,address))' \
  0x7296382ac1d2e0419f5ff0588bf91e56d9cd0399882670559a3361c8ec796346 \
  --rpc-url https://rpc.cc3-testnet.creditcoin.network

cast call 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 'totalSupply()(uint256)' \
  --block 11691162 --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

The decoded returndata and the direct source read are byte-equal: both are the WETH
total supply at source block 11,691,162.

### A Chainlink price, proven

Sepolia's Chainlink ETH/USD aggregator read through Lens at source block 11,691,162:

| Where | Bytes | Value |
|---|---|---|
| On Sepolia, directly | `0x…3aaba98236` | $2,519.88 |
| On Creditcoin, proven | `0x…3aaba98236` | $2,519.88 |

Worth stating plainly: this is a Chainlink feed carried onto a chain Chainlink does not
serve, without Chainlink's participation and without anyone being trusted to report it
honestly. The number is not relayed. The read happened on Sepolia, and the log proving it
happened was verified by the precompile.

### The two clocks, measured on chain

The probe emits the source-chain time of the read because nothing downstream can recover
it. Here is why that matters, taken from the live deployment rather than a test:

| | Value | |
|---|---|---|
| Sepolia block 11,691,162 timestamp | 1789243932 | source-chain read time |
| `sourceTimestamp` in the proven observation | 1789243932 | exact match |
| `recordedAt`, Creditcoin's own clock | 1789246170 | proof landing time |
| Gap | **2,238 seconds** | this sample, Sepolia block 11,691,162; an earlier sample in `SECURITY.md` measured 558 seconds — the gap is the attestation lag plus however long the prover waited |

A Chainlink-shaped consumer computes age as `block.timestamp - updatedAt`. Had `updatedAt`
carried Creditcoin's clock, the value would have looked younger than it was by the
attestation gap. The adapter reports `sourceTimestamp`, while Lens freshness itself is
computed as `frontier - probeHeight` in source-chain blocks; `recordedAt` is never used to
make a consumer accept a value.

### A Chainlink feed served through Chainlink's own interface

`LensAggregatorV3` at `0x134dbefE46b803ADab301D3c85f33E82a16A3993`, read exactly as any
lending market reads a price:

The following values are from the doctor/claim verification sample; age advances with the
source frontier.

| Call | Answer |
|---|---|
| `description()` | `sepolia.chainlink.ethUsd` |
| `decimals()` | 8 |
| `version()` | 4 |
| `latestRoundData().answer` | `251988116022` — $2,519.88 per ETH |
| `latestRoundData().roundId` | 11,691,162 — the source height the read happened at |
| `latestRoundData().updatedAt` | 1789243932 — the source clock |
| `ageInBlocks()` | 338 source blocks at the doctor sample |

The round id is the source-chain height rather than a counter, which makes a round a
statement about where on the source chain the value came from.

### VotePort: current live governance path

The fresh `VotePort` deployment reads the checkpointed weight proven in the same seven-feed
Sepolia proof. The snapshot remains historical by design: the feed calls
`getPastVotes(account, 11,676,782)` while the probe transaction itself ran at source block
11,691,162.

| Read | Result |
|---|---|
| Current `VotePort` | `0xe43E5484Da58762800e7f495076658586295ccD0` |
| `provenWeight(0xcf7a...FC359, 11676782)` | 1,000,000 LVOTE |
| Fresh proposal | id 0, snapshot 11,676,782 |
| Fresh vote outcome | 1,000,000 for, 0 against |

| Step | Chain | Hash |
|---|---|---|
| Open the proposal | CC3 testnet | [`0x5b5c1f29a16aac70224cf9956985560f48481658cb5b131d2b3cd1212d43635f`](https://creditcoin-testnet.blockscout.com/tx/0x5b5c1f29a16aac70224cf9956985560f48481658cb5b131d2b3cd1212d43635f) |
| Cast the vote with the proven weight | CC3 testnet | [`0x84065ed540be0204cadb60a32c267a2c0364c9e429bcc9a976499997c7578a87`](https://creditcoin-testnet.blockscout.com/tx/0x84065ed540be0204cadb60a32c267a2c0364c9e429bcc9a976499997c7578a87) |

No token moved and no weight was supplied by the caller. `VotePort` derives the feed id
from the caller, token, selector and snapshot block, then reads the verified observation.

**About the token.** `LensVoteToken` is a real OpenZeppelin `ERC20Votes` deployment, not a
mock. Its checkpoints are genuine, and the same `VotePort` constructor accepts a
Compound-style selector for tokens such as UNI and COMP.

### Both kinds of batching, measured

| What | Chain | Result |
|---|---|---|
| Seven source reads in one `probeMany` | Sepolia | 129,311 gas, tx `0x4a8cff...` |
| Seven verified observations in one `submitBatch` | CC3 testnet | 982,017 gas, tx `0x6fad658a...` |
| Three mainnet source reads in one `probeMany` | Ethereum mainnet | 143,660 gas, tx `0x2e0728...` |
| Three verified observations from two source transactions in one `submitBatch` | CC3 testnet | 703,124 gas, tx `0xb009222f...` |
| Three verified observations from one source transaction in one `submitProof` | CC3 testnet | 276,066 gas, tx `0xf34bfd...` |

The shared continuity proof is paid once per batch. The source prober's measured gas model
also reserves the wrapper baseline and each target's estimate; it does not hide pallet-EVM
forwarding under a fixed heuristic.

### The refusals, on the live chain

The fresh registry's read path fails closed. `frontierOf(99)` reverts with
`UnknownChainKey`, and the deployed adapter refuses an unavailable or stale observation
instead of returning a sentinel price. Replay, receipt status, emitter binding, monotonic
height and attestation-range refusals are covered by the adversarial Foundry suite.

## Latest keeper refresh (2026-09-13)

The latest live keeper pass produced fresh source transactions on both configured chains.
The single-proof path initially saw the hosted builder's transient `BlockNotReady`
response; a retry completed the proofs. The client now retries that response through the
same primary, fallback and local-builder chain used by the batch path.

| Source | Probe transaction | Source block | Proof transaction | CC3 block | Proof gas | Result |
|---|---|---:|---|---:|---:|---|
| Ethereum mainnet | [`0x2e0728…ec27f`](https://etherscan.io/tx/0x2e0728a4315fba446b207c45074a62a2c59b6a875fa1d69a98536565c25ec27f) | 25,964,672 | [`0xf34bfd…8b2d0`](https://creditcoin-testnet.blockscout.com/tx/0xf34bfdb6b4536f54c3d87a56d3d63d00d92094596072bef7315fd8144ae8b2d0) | 5,477,722 | 276,066 | 3/3 byte-equal |
| Ethereum Sepolia | [`0x3da6ad…c92a6`](https://sepolia.etherscan.io/tx/0x3da6ad40d01ed65bdffadbd408e33e8935a26ca4daf7f2d28e1ef8208dbc92a6) | 11,692,212 | [`0x8cd83b…565f`](https://creditcoin-testnet.blockscout.com/tx/0x8cd83bfb71e45b70ed247d272ce89b980ffc3bf8f46a5cd50c5cb47cd68c565f) | 5,477,768 | 348,101 | 7/7 byte-equal |

The mainnet refresh included the stETH exchange rate (1.243869391 ETH/stETH), ENS
`getPastTotalSupply(25948230)` (100,000,000 ENS), and Uniswap's dynamic tick-cumulative array
(`33553776709271`, `33554133078311`). The Sepolia refresh included WETH total supply
(218,020.975 WETH), Aave WETH backing (12,071.334), aWETH issued (12,071.222), the
checkpointed voting weight (1,000,000 LVOTE), Chainlink ETH/USD ($2,524.13), and both
role checks (true and false). Every listed result was compared to the direct source read
at the proven source height.

## Audit status (2026-09-13)

The immutable graph has now been redeployed and exercised end-to-end. The status below is a
release audit, not a claim that the remaining measurement work is complete.

| Check | Current status |
|---|---|
| Deployment parity | Green: `check-deployed` matches all ten current deployments to checked-in bytecode. |
| Live operation | Green sample: `doctor` reports 0 failures across ten feeds and one low mainnet balance warning. |
| Byte equality | Green: all ten source reads are byte-equal at their exact proven heights, rechecked through public archive-capable endpoints with no key; zero divergence, zero unreachable. |
| Product smoke | Green: feed explorer, consumers, builder validation and fail-closed cards pass `web-smoke`. |
| Claims | Current deployment and transaction claims verify; run `node tools/verify-claims.mjs` after any doc edit. |
| Coverage | Green: 95.01% lines (704/741), 89.94% statements, 61.90% branches; 200 tests pass. |
| Verification | Green for the complete deployed graph: all eleven CC3 contracts are Blockscout verified; those eleven plus both source probes are Sourcify full matches (13 total). |
| Operations | Sepolia keeper and indexer are running persistently on the VPS. End-to-end latency is published as a three-day distribution in `LATENCY.md`; mainnet automation awaits funding. |

The current graph has source verification, archive differential, coverage, symbolic
proofs of the consumer arithmetic and live unattended services.

### Fresh lending price (2026-09-13)

The Sepolia Chainlink ETH/USD feed was refreshed at source block `11694457` and proved to
CC3 testnet with exact byte equality at **$2,520.54/ETH**.

- source transaction: `0xb0436d409dbaee1f567422fd14ebe24ccfa1b696767fc030e62d8f925d8d72e8`
- Creditcoin proof transaction: `0xff4d43f0fb465d4fd1a3f1aaef05ad1843d0736d1fe8c47ff44d194107caac42`
