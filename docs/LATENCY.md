# Latency and cost, measured

Every figure here came from the live deployment. Where something is a single sample it
says so, because a sample and a distribution are different claims.

## Attestation lag

The frontier is the highest source-chain height Creditcoin has attested. Lag is how far
behind the source chain's head it sits.

| Chain | Observed lag | Approx. |
|---|---|---|
| Ethereum mainnet | 36–39 blocks | 7.2–7.8 min |
| Ethereum Sepolia | 38–44 blocks | 7.6–8.8 min |

**The frontier advances ten blocks at a time**, on both chains. Watched directly across an
eight-minute window on Sepolia: 11,676,120 → …130 → …140 → …150 → …160. Two mainnet
samples an hour apart, 25,947,000 and 25,947,010, agree.

An earlier version of this file claimed a 150/200-block stride. That was wrong — those
figures were the distance from the latest attestation to the latest *checkpoint*, which is
a different thing. The correction is recorded rather than quietly replaced.

**This is minutes of observation, not a 24-hour distribution.** The figures are consistent
across every run so far and they are labelled as a sample.

### The builder trails the chain

The proof builder keeps its own cache and lags the precompile. Measured 2026-09-10: the
ChainInfo precompile reported Sepolia attested to 11,676,120 while both builder hosts
reported 11,676,110.

That matters more than ten blocks suggests. Asking for a proof on the strength of the
precompile alone returns a not-found, which is shaped exactly like "that transaction does
not exist". The prober waits on the slower of the two answers, so a timing gap is never
recorded as a missing transaction.

### End to end

A probe becomes a readable value on Creditcoin in roughly **8 to 9 minutes**. One
unattended keeper cycle: probed at 19:51:40, all five feeds proved and byte-equal at
20:00:03 — **8 minutes 23 seconds**.

## Gas

### On the source chain

| Operation | Gas |
|---|---|
| `probe`, one feed | 29,380 |
| `probeMany`, three feeds | 87,028 |
| `probeMany`, five feeds | ~53,000–140,000 depending on returndata size |
| Three real mainnet feeds, one transaction (stETH, ENS, Uniswap; tx `0x2e0728…`, 2026-09-13) | 143,660 |
| Two real mainnet feeds, one transaction (ENS, Uniswap; tx `0xf701eb…`, 2026-09-12) | 99,139 |
| `StateProbe` deployment | 385,849 |

At Ethereum mainnet's 0.06 gwei, the probe deployment cost **0.0000159 ETH (~$0.04)** and
a three-feed batch about **$0.02**. The `probe` and three-feed `probeMany` rows above the
mainnet ones are Sepolia measurements from the first deployment; the mainnet rows carry
their receipts and dates because the two runs differ and are not averaged.

### On Creditcoin

| Operation | Gas |
|---|---|
| Proving one feed | 200,480 |
| Proving one source transaction carrying two feeds | 231,101 |
| **Marginal cost of each additional feed in the same source transaction** | **30,621** |

**Two different kinds of batching, which an earlier version of this file conflated.**

*Several feeds in one source transaction.* `probeMany` reads many targets and emits a log
each, and one `submitProof` proves that single transaction. Every extra log costs
**30,621 gas** to decode and record — the 200,480 → 231,101 measurement above. This is
what the deployment does today.

*Several source transactions under one shared continuity proof.* `submitBatch` takes up to
ten separate transactions, each with its own Merkle proof, sharing one continuity proof.
That is what amortises the continuity chain, and it is the path for feeds probed in
different blocks.

Both are now measured, and they are not the same number.

| | Gas | Per query |
|---|---|---|
| One query, `submitProof` | 200,480 | 200,480 |
| Two logs in one source transaction, `submitProof` | 231,101 | 115,551 |
| Two queries in different blocks, `submitBatch` | **261,492** | **130,746** |

Marginal cost of a second **log in the same transaction**: 30,621 gas.
Marginal cost of a second **query under a shared continuity proof**: 61,012 gas.

The batch of two spanned Sepolia blocks 11,677,327 to 11,677,331 with **14 continuity
roots**, and cost 35% less than proving the two separately. The precompile accepts ten
queries, so a full batch falls further, but the marginal figure is the honest one to
extrapolate from and it is twice what an earlier version of this file claimed.

Use `probeMany` when feeds can be read in the same block — it is the cheaper of the two.
Use `submitBatch` when they cannot, which is any feed probed on its own cadence.

## What the lag means for a feed

A feed is honest only if its meaning survives the delay.

| Feed class | Survives 8 minutes? |
|---|---|
| 30-minute TWAP | yes — it is still a 30-minute TWAP |
| Liquid-staking rate | yes — moves basis points per day |
| Reserves, total supply | yes — a checkpoint, not a tick |
| Governance weight at a past block | yes — the block is fixed |
| Spot price for liquidation | **no** — do not use Lens for this |

## Reproducing these

```
node tools/verify-infra.mjs      # frontier and lag against both chains, right now
node prober/keep.mjs --once      # one full probe-and-prove cycle, timestamped
node tools/differential.mjs      # every held value against its source
```
