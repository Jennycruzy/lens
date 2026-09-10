# Historical state, with no storage proof

The technique worth publishing, and the contract that was removed for it.

## The idea

A probe reads current state. But **many contracts expose their own history through
ordinary view functions**:

- `ERC20Votes.getPastVotes(account, block)` — OpenZeppelin
- `getPriorVotes(account, block)` — Compound-style, as UNI and COMP use
- `observe(secondsAgo[])` — Uniswap V3
- any checkpointed accumulator

For those targets, *"what was the balance at block N"* is not a storage question at all.
It is a function call, made now, whose answer is about then. Probing that call is an
ordinary probe, provable by the ordinary path.

**So historical state is verified with no storage proof anywhere in the system.** That
turns the airdrop-snapshot problem — prove what someone held at a past block — into an
ordinary Lens feed.

## How the block is bound to the answer

The block is an **argument to the call**, so it is inside the calldata:

```solidity
bytes memory callData = abi.encodeWithSelector(GET_PAST_VOTES, account, snapshotBlock);
```

and a feed's identity is

```
feedId = keccak256(abi.encode(chainKey, target, keccak256(callData)))
```

The identifier therefore commits to the token, the account **and the block**, together.
A weight from one block can never be counted as a weight from another, and one holder's
proof is useless to a different holder, because both produce a different identifier. Two
tests assert exactly that.

## Why there is no HistoryProbe

An earlier version of this repository had a separate `HistoryProbe` that emitted the
height an answer was *about* as its own event field, alongside the height the read ran at.

It was removed, because that field cannot be checked.

The registry never sees calldata — only `keccak256(calldata)`, which arrives as an indexed
log topic. It cannot parse arguments, so it could not compare a declared height against
the height actually passed to the target. A prober could probe
`getPastVotes(alice, 100)` while declaring the answer was about block 999. The feed would
still be correct, because the feed is keyed on the calldata. But the declared height
stored beside it would be a lie, and it would read as authoritative.

**An unverifiable field that looks authoritative is worse than no field.** The calldata
already binds the block exactly, so the extra one bought nothing and added a claim nobody
could check. `StateProbe` covers the technique completely.

The guard it carried — refusing a height at or above the current block — guarded the
declared height rather than the one in the calldata, so it did not prevent the thing it
appeared to prevent.

## Demonstrated, live

| | |
|---|---|
| `VotePort` | a vote cast on Creditcoin with `getPastVotes` weight from Sepolia block 11,676,782 |
| `SnapshotProver` | a claim paid on a holding proven at the same block |
| `mainnet.ens.pastSupply` | ENS `getPastTotalSupply` at Ethereum mainnet block 25,948,230, proven and byte-equal |
| Fork tests | ENS checkpoints 50,000 blocks back, byte-equal to a direct call |

## What it does not cover

**A contract that keeps no checkpoints cannot answer about its own past**, and no amount
of probing changes that. A plain ERC-20 without `ERC20Votes` can only ever report its
balance now. Lens has no storage proofs and does not claim any.

The technique covers the checkpointed class exactly. That boundary is stated rather than
blurred.
