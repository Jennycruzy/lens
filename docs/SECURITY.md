# Security

## The sentence everything rests on

> A prober is trusted for **liveness, never correctness**. A forged probe fails at the
> precompile. A withheld probe causes **refusal, never a wrong answer**.

Anyone may run a prober. Nobody has to be trusted to run one honestly, because a prober
never supplies a value — it causes a source chain to produce one. The read is performed by
the EVM on the chain that owns the state, the result is emitted in a transaction, and the
transaction is proven to Creditcoin by the precompile. A prober who lies produces a log
that was never in an attested block, and the proof fails.

The remaining power a prober has is to do nothing. That is why the failure mode is
refusal: a feed nobody updates ages out, and every consumer stops reading it.

## What the precompile does and does not prove

It proves a transaction was **included** in a block, and that the block is really part of
the confirmed source chain.

It does **not** prove the transaction succeeded. A reverted transaction is still in its
block and the precompile will happily prove it. Everything past inclusion is the
registry's job.

## The six checks, and the attack each one stops

| # | Check | Without it |
|---|---|---|
| 1 | Receipt status is 1 | A reverted probe is proven and its garbage recorded as a value |
| 2 | Each query consumed once | A valid proof stays valid forever, so any old one can be replayed to freeze a feed at a past value |
| 3 | Height inside the attested range | A height past the frontier, or below the attestation genesis, is accepted with nothing anchoring it |
| 4 | Newest wins by source height | An older observation overwrites a newer one, and a prober chooses which past value a consumer sees |
| 5 | Chain key asserted against the native chain id | The registry verifies every proof correctly while reporting another chain's state, because keys mean different chains in different environments |
| 6 | Log emitted by the registered probe | Anyone deploys a look-alike emitter and forges every feed |

Each is proven by an adversarial test that hands the registry a **valid** proof and checks
it still refuses. The precompile is doing its job in all of them; the question is whether
the registry does its own.

Two more are enforced that the design notes did not ask for:

- The height the probe emitted must equal the height that was proven, so a log cannot be
  bound to the wrong block.
- A truncated read is recorded as truncated, and consumers refuse it. A prefix of a number
  decodes to a plausible number that is wrong.

## No admin keys anywhere

There is no owner, no pause key, no upgrade path and no privileged role in any Lens
contract.

- `StateProbe` and `HistoryProbe` hold no state and have no operations to protect.
- `LensRegistry` fixes its chain keys and probe addresses at construction. There is no
  function to change them.
- `CircuitBreaker` trips and untrips as a function of what the registry and the precompile
  report. `poke` takes no arguments, so a caller cannot influence the outcome, and a test
  demonstrates that an outsider calling it changes nothing.
- `FeedEscrow` lets a funder withdraw their own unspent balance after a timelock. That is
  the only privileged action in the system and it cannot touch a feed's contents.

This is a real difference from the oracles Lens replaces, so it is stated as a property
rather than an aspiration.

## Fail closed

No path hands a consumer a value it might believe is fresh when it is not.

Four refusals are kept distinct, because a caller that cannot tell them apart cannot react
correctly to any of them: **missing** (never proven — ask a prober), **failed** (proven,
and proven to have failed at the source), **truncated** (the answer is a prefix), and
**stale** (outside the age you allowed).

Age is `frontier - probeHeight`: how far behind the attested head of the source chain the
value sits. Never wall-clock, never a Creditcoin height. When a source-chain reorg rewinds the frontier below a recorded height, the observation may no longer be canonical. Readers return a maximum-value sentinel and refuse it; they never treat a regressed frontier as age zero.

## The two clocks

`updatedAt` on the Chainlink adapter is the **source chain's** clock, never Creditcoin's.
They are minutes apart because the attestation lag sits between them; on the live
deployment the gap measured **558 seconds**.

A Chainlink-shaped consumer computes age as `block.timestamp - updatedAt` and liquidates
on the result. Reporting the moment the proof landed would make every price look nine
minutes younger than it was, and a staleness check set to nine minutes would pass on a
value nine and a half minutes old.

The source timestamp is unrecoverable downstream — it is not in the proven transaction
encoding — so the probe emits it and the registry keeps both clocks separately.

## Attacks considered

**Forge a value.** Fails at the precompile: the log was never in an attested block.

**Replay an old proof.** Rejected by check 2. Demonstrated on the live chain:
`QueryAlreadyConsumed(0xa31c4e17…)`.

**Deploy a look-alike probe and emit whatever you like.** Rejected by check 6. The
registry accepts logs only from the emitter registered for that chain key.

**Point a registry at the wrong environment.** The constructor resolves each chain key
through ChainInfo and asserts the native chain id. On the wrong environment it reverts
rather than deploying.

**Withhold.** Every prober must withhold together. One who defects takes the fee and the
feed updates, which `FeedEscrow` prices and a test demonstrates. Meanwhile consumers
refuse rather than reading something stale.

**Return megabytes to exhaust gas.** Returndata is capped at 8,192 bytes and flagged as
truncated. Forwarded gas is capped at 2,000,000 per read, so a target that reverts — which
consumes everything forwarded — cannot take the rest of a batch down with it.

**Move the price violently.** `CircuitBreaker` trips beyond its bound and refuses reads
until a fresh in-bound observation arrives. It does not heal by waiting.

**Reorg the source chain.** The frontier regresses below a recorded height, which the
breaker treats as a trip condition. This was not designed from the specification — an
invariant run produced it.

## Where the trust actually sits

Lens removes the oracle. It does not remove Creditcoin's own validators: a value is as
trustworthy as the attestation of the block it came from. That is the same assumption
every Attestcoin application makes, and it is the assumption Lens is built on rather than
one it eliminates.
