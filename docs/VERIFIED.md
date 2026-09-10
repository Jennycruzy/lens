# Verified infrastructure

Every fact Lens depends on, re-derived from the live network rather than taken from
documentation — including from Lens's own design notes. Each row carries its source and
the date it was checked.

Re-run at any time:

```
node tools/verify-infra.mjs
```

The tool writes `docs/evidence/infra-verification.json` and exits non-zero if any check
fails. Last full run: **2026-09-10**, CC3 testnet height 5,463,550, 9/9 checks passing.

---

## What the runtime says

### CC3 testnet

| Item | Value | How confirmed |
|---|---|---|
| RPC | `https://rpc.cc3-testnet.creditcoin.network` (also `wss://`) | `eth_chainId` → `0x18e8f` = **102031** |
| BlockProver precompile | `0x0000000000000000000000000000000000000FD2` | rejected a forged proof at runtime, see below |
| ChainInfo precompile | `0x0000000000000000000000000000000000000fd3` | `get_supported_chains()` answered |
| Decoder contract | `0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f` | `eth_getCode` → 9,598 bytes |
| Proof builder, primary | `https://prover.cc3-testnet.creditcoin.network` | HTTP 200 |
| Proof builder, failover | `https://proof-gen-api.cc3-testnet.creditcoin.network` | HTTP 200 |
| Contracts package | `@gluwa/asc-contracts@0.2.1` | installed, interfaces read from source |
| SDK | `@gluwa/usc-sdk@0.18.0` | installed, source included in the tarball |

### Attested source chains — confirmed by runtime call, not by documentation

`get_supported_chains()` on CC3 testnet returns:

| Chain key | Native chain id | Name | Encoding |
|---|---|---|---|
| **3** | 1 | Ethereum | 1 |
| **1** | 11155111 | Sepolia ethereum | 1 |

Two things follow, and both shape the whole project.

**CC3 testnet attests Ethereum mainnet.** Lens deploys to a testnet, as the rules require,
while reading real mainnet state. Uniswap TWAPs, stETH rates and live reserves are all in
range.

**The same integer means different chains in different environments.** Ethereum mainnet is
key `3` here and key `1` on CC3 mainnet, where key `1` on testnet is Sepolia. A hardcoded
key would verify every proof correctly while reporting the wrong chain — proofs still
valid, answers still wrong. Chain keys are therefore resolved from ChainInfo at
construction and asserted against the native chain id, which is the only environment-
independent identifier available. Sepolia is confirmed attested alongside Ethereum, so the
dual-source design stands.

### Measured attestation lag

Frontier from ChainInfo against the live source head, at 2026-09-10T12:40Z:

| Chain | Attested height | Source head | Lag | Approx. |
|---|---|---|---|---|
| Ethereum mainnet | 25,947,010 | 25,947,049 | 39 blocks | ~7.8 min |
| Sepolia | 11,674,960 | 11,675,001 | 41 blocks | ~8.2 min |

**Correction.** An earlier version of this file claimed attestations land 200 blocks
apart on mainnet and 150 on Sepolia. That was wrong. Those figures were the distance
between the latest attestation and the latest *checkpoint*, which is a different thing
that was misread as a stride.

The frontier is observed to advance in steps of **10 blocks** on both chains. On Sepolia
it was watched directly across an eight-minute window, moving 11,676,120 → 11,676,130 →
11,676,140 → 11,676,150 → 11,676,160. Two mainnet samples taken about an hour apart,
25,947,000 and 25,947,010, agree.

So the frontier trails the head by roughly 30 to 40 blocks and closes that gap ten blocks
at a time, which is consistent with the documented target of verification within about
15 seconds of source-chain finalisation. Distribution over 24 hours is still being
collected; what is above is direct observation over minutes, and is labelled as such.

Attestation genesis height is `0` for both chains, so there is no lower bound on how far
back a block can be proven beyond what the prover will build.

---

## Precompile interfaces, read from source

From `@gluwa/asc-contracts@0.2.1`, `contracts/write-ability/common/INativeQueryVerifier.sol`.
The precompile was previously called Native Query Verifier and the name survives in the
package.

```solidity
struct MerkleProofEntry { bytes32 hash; bool isLeft; }
struct MerkleProof      { bytes32 root; MerkleProofEntry[] siblings; }
struct ContinuityProof  { bytes32 lowerEndpointDigest; bytes32[] roots; }

function verify(uint64 chainKey, uint64 height, bytes calldata encodedTransaction,
                MerkleProof calldata, ContinuityProof calldata) external view returns (bool);

function verify(uint64 chainKey, uint64[] calldata heights, bytes[] calldata encodedTransactions,
                MerkleProof[] calldata, ContinuityProof calldata sharedContinuityProof)
                external view returns (bool);

function verifyAndEmit(...)      // same two shapes, non-view, emits TransactionVerified
function calculateTxIndex(MerkleProof calldata) external view returns (uint64);
```

Four points that matter for the contracts:

- **Both `verify` and `verifyAndEmit` exist, in single and array form.** `verify` is `view`,
  so a read path can check a proof without a state write. `verifyAndEmit` emits
  `TransactionVerified(chainKey, height, transactionIndex)`.
- **The array form takes one shared continuity proof** for N transactions on the same chain
  key, which is exactly what amortises proof cost across a batch. All N must fall inside
  the range that one continuity chain covers.
- **The batch limit counts queries:** up to 10 queries share a continuity proof.
- **`calculateTxIndex` is provided.** The transaction index does not have to be recovered
  from the Merkle path by hand, as the older published examples do.

Types are `uint64` for both chain key and height. Proofs are typed structs, not opaque
`bytes`.

### The precompile does not check whether the transaction succeeded

Stated plainly in the documentation and confirmed by the interface: verification proves
that a transaction was *included* in a block and that the block is really part of the
confirmed source chain. A reverted transaction is still in its block. Receipt status must
be checked by the consuming contract:

```solidity
EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(encodedTransaction);
require(receipt.receiptStatus == 1);
```

`EvmV1Decoder` ships in the same package and does expose receipt status, transaction
fields and logs, so this check is available on-chain.

### Runtime behaviour of the precompile

Calling `verify` with a zero root, empty siblings and `0xdeadbeef` as the transaction
reverts with `Merkle proof validation failed`. A forged proof is rejected by the
precompile, not by Lens — which is the whole security argument, observed rather than
asserted.

---

## What the proof builder exposes

Neither host publishes a schema at any of the usual paths, but the SDK names the routes
and both hosts answer them:

| Route | Purpose |
|---|---|
| `/api/v1/proof-by-tx/{chainKey}/{txHash}` | the proof for one transaction |
| `/api/v1/attested-height/{chainKey}` | how far the builder itself has ingested |

**The builder trails the precompile.** Measured 2026-09-10: the ChainInfo precompile
reported Sepolia attested to 11,676,120 while both builders reported 11,676,110. The
builder keeps its own cache, so a height that is attested on-chain is not necessarily
one the builder can prove yet.

That matters more than the ten-block gap suggests. Asking for a proof on the strength of
the precompile alone returns a not-found, which is indistinguishable in shape from "that
transaction does not exist". Waiting on the slower of the two answers is what keeps a
timing gap from being recorded as a missing transaction.

Both hosts are live and answer identically, so the failover chain has two independent
legs before the SDK's local builder is needed at all.

## Corrections to the design notes

Six things were assumed and turned out to be wrong. They are recorded because the
contract interfaces changed as a result.

1. **Chain key is `uint64`, not `uint32`.** Every signature carrying a chain key was
   widened.
2. **Proofs are structs, not `bytes`.** The registry entry point takes
   `MerkleProof` and `ContinuityProof` directly rather than opaque byte strings, which
   removes a decode step and a class of malleability.
3. **A local proof builder already exists.** `@gluwa/usc-sdk` ships
   `proof-provider/raw`, which builds continuity and Merkle proofs from a block provider
   and ChainInfo without the hosted service. The hosted builder is therefore not a single
   point of failure, and the failover chain has a genuine third leg.
4. **`chainName` is ABI type `bytes`, not `string`,** even though the SDK's TypeScript
   interface declares it as `string`. Decoding it as a string yields hex. Minor, but it
   silently produced unreadable output in the first run of the verification tool.
5. **`get_chain_by_key` returns a different shape from `get_supported_chains`.** The
   first wraps the chain struct with a presence flag —
   `ChainInfoResult { ChainInfo info; bool exists; }` — while the second returns the bare
   struct in an array. Reading the wrong one made the registry constructor revert on
   Creditcoin **with no revert data at all**, which is not diagnosable from the error.
   No local test could have caught it, because the precompile does not exist off-chain.
6. **`forge script` cannot deploy to Creditcoin.** Two independent reasons: CC3 block
   headers carry no `prevrandao`, which Foundry's header validation requires from Paris
   onward, and the precompiles are native code with no bytecode, so a local fork answers
   `call to non-contract address 0x...fD3` before the script reaches the network.
   Deployment goes through the node instead. Both are recorded because anyone else
   building here will hit them within an hour.

## A false pass, and the fix

The first version of the verification tool reported the BlockProver check as passing. It
was not passing. The function signature it used listed the `MerkleProof` fields in the
wrong order, so ethers rejected the call locally with `no matching function` and the
tool's `catch` branch scored any thrown error as "the precompile rejected the proof". The
call never reached the network.

The check now distinguishes a local ABI or encoding error from an on-chain revert and
scores the former as a failed, inconclusive check. Recorded here because it is the exact
failure the tool exists to prevent, and it was found by reading output rather than
trusting an exit code.

---

## Still open

Measured against the live network, in order of when they block work:

| Question | Why it matters | Status |
|---|---|---|
| Largest returndata that survives the proof path | bounds what a probe may return | needs the first end-to-end read |
| Log index numbering, block-wide or per-transaction, in the decoder | wrong reading binds the wrong log | needs the first end-to-end read |
| Attestation lag distribution over 24h | published as a measurement, not a guess | one sample so far, collection running |
| Frontier behaviour under a source-chain reorg | the circuit breaker trips on frontier regression | observational, needs a reorg |
| Proof builder rate limits and auth | failover policy | neither host exposes a schema at the usual paths |
| Sourcify endpoint for CC3 testnet | contract verification must be a full match | still open; Blockscout is confirmed at `creditcoin-testnet.blockscout.com` and the tCTC faucet is a Discord bot, both written up in `FUNDING.md` |

### `eth_estimateGas` on pallet-evm — answered, and it is worse than expected

Not merely unreliable: on failure it returns

```
VM Exception while processing transaction: revert   data: '0x'
```

with no reason, no selector, and no custom error. A contract that reverts for six
different reasons produces the same six-character answer to all of them.

An `eth_call` first is therefore not an optimisation, it is the only way to learn
anything. That is how the constructor bug above was found: the estimate said "revert",
and the call said which shape was wrong. Every path in the prober that sends a
transaction calls first.

Nothing above is a guess in the codebase. Where a value is unknown, the code reads it at
runtime or refuses.
