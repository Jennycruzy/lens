# Evidence

Every address and transaction behind a claim in this repository. Nothing here is a
plan; each row is on a public chain and can be checked without asking us.

## Deployed

| What | Chain | Address | Status |
|---|---|---|---|
| `StateProbe` | Ethereum Sepolia (chain key 1) | [`0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe`](https://sepolia.etherscan.io/address/0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe) | live, 1,042 bytes |
| `StateProbe` | Ethereum mainnet (chain key 3) | `0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe` | same address, awaiting funding |
| `LensRegistry` | Creditcoin CC3 testnet | [`0xFCCd509F4EbB8Bc9Baf8cAA965231F8ACCf2DaaA`](https://creditcoin-testnet.blockscout.com/address/0xFCCd509F4EbB8Bc9Baf8cAA965231F8ACCf2DaaA) | live |

The probe is deployed through the standard deterministic deployer with the salt
`keccak256("lens.state-probe.v1")`, so its address is a property of its bytecode rather
than of who deployed it or when. Anyone can verify the address without trusting us:

```
cast compute-address --create2 \
  --salt $(cast keccak "lens.state-probe.v1") \
  --init-code-hash 0x405e87ce05c732afa93d801edefea825cf7c1847bdab009a21a6a51b7b9290b5 \
  0x4e59b44847b379578588920cA78FbF26c0B4956C
```

That also means the mainnet probe is already pinned: when the key is funded, the same
bytecode lands at the same address, and the registry needs no change.

### Transactions

| What | Chain | Hash |
|---|---|---|
| `StateProbe` deployment | Sepolia | [`0x00534c2a78f3b7ec070aa9376ed9029ed50fa37a8a55ce2f3dffac1b9751d967`](https://sepolia.etherscan.io/tx/0x00534c2a78f3b7ec070aa9376ed9029ed50fa37a8a55ce2f3dffac1b9751d967) |
| First probe, Sepolia WETH `totalSupply()` | Sepolia | [`0xe5124c2b39622e95399153908fc3f30b474e5a48d9f32ff54e014f97b2da6e7f`](https://sepolia.etherscan.io/tx/0xe5124c2b39622e95399153908fc3f30b474e5a48d9f32ff54e014f97b2da6e7f) |
| That probe proven and recorded | CC3 testnet | [`0xd9290d8dc006cead38f120e9edc5bd241d810dd412a79f92e16b37821ed22668`](https://creditcoin-testnet.blockscout.com/tx/0xd9290d8dc006cead38f120e9edc5bd241d810dd412a79f92e16b37821ed22668) |
| `LensRegistry` deployment | CC3 testnet | [`0xece577fa31a23b930c69044c9f4ae16c4592eab1e72f0bce9f32026c47056090`](https://creditcoin-testnet.blockscout.com/tx/0xece577fa31a23b930c69044c9f4ae16c4592eab1e72f0bce9f32026c47056090) |

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
| `PROBED_SIGNATURE()` | `0xcc205dbd77fbafc012eccc26fdeae09611101621c9e62bb7de830d156832dbfe` |

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

### The refusals, on the live chain

Rejections are asserted in tests, but two of them have now also been observed on
Creditcoin itself rather than against a stub:

| Attempt | Result |
|---|---|
| Submit the same proof a second time | `QueryAlreadyConsumed(queryKey=0xa31c4e17c23099854734310d55fea1faa760d2dbb544abe119ef90ddf412904c)` |
| `frontierOf(99)`, a chain key this environment does not attest | `UnknownChainKey(99)` |

A valid proof stays valid forever, which is exactly why it has to be spent once.
