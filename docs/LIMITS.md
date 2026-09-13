# Limits

What Lens cannot do, volunteered rather than discovered. A reader who finds a limit
themselves assumes it was being hidden.

## It is not a spot feed

The attestation frontier trails the source chain's head by roughly **30 to 40 blocks**,
about **seven to eight minutes**, advancing ten blocks at a time. That is measured, not
estimated — see `VERIFIED.md`.

So Lens is wrong for anything whose meaning depends on being current: a perpetual's mark
price, a liquidation engine that must react within a block, an AMM quote. Those need a
feed that can be wrong quickly rather than one that is right slowly.

Lens is right for values where lag is already part of the meaning:

| Feed class | Why the lag costs nothing |
|---|---|
| Time-averaged prices | A thirty-minute TWAP read eight minutes late is still a thirty-minute TWAP |
| Liquid-staking rates | Move on the order of basis points per day |
| Reserves and supply | Checkpoints, not ticks |
| Governance weight at a past block | The block is in the past by construction |
| Access lists, pause flags, roles | Change rarely and deliberately |

## Historical state only where a contract keeps its own history

The technique in `HistoryProbe` reads a contract's own checkpoints:
`ERC20Votes.getPastVotes`, Compound-style `getPriorVotes`, Uniswap's `observe`. For those
targets, "what was the balance at block N" is a function call, not a storage question.

**A contract that keeps no checkpoints cannot answer about its own past, and no amount of
probing changes that.** A plain ERC-20 without `ERC20Votes` can only ever report its
balance now. Lens has no storage proofs and does not pretend to.

## Sepolia price feeds are not meaningful

Sepolia's Uniswap pools have no real liquidity, and a TWAP over a dead pool is a number
without a meaning. Price feeds on Sepolia are the Chainlink aggregator, which is a real
deployment, or nothing. Real pool-derived prices come from Ethereum mainnet.

## The demonstration governance token is ours

`LensVoteToken` on Sepolia is a real OpenZeppelin `ERC20Votes` deployment, not a mock, but
we deployed it and hold the supply. Sepolia has almost no checkpointed governance tokens
and the UNI deployment that exists is held by nobody who could demonstrate with it.

Every other part of that path is the production one — the read, the attestation, the
proof, the registry's checks. Pointing `VotePort` at a widely-held token changes one
constructor argument.

## A median needs inputs that differ

`MedianFeed` is implemented and tested, but no median is deployed with meaningful inputs.
A median is worth something across **independent probers** or across **the same asset on
two source chains**; with one prober and feeds that do not overlap between chains, any
median we deployed today would average a value against itself. That would be theatre, so
it is not deployed. The capability is real and the tests exercise it.

## Coverage is not uniform

**95.01% of lines** (704/741), 89.94% of statements and 61.90% of branches across
`contracts/src`, from `npm run coverage` on 2026-09-13; 200 tests pass.

`StateProbe` reads around 52% of lines, which understates it: its read path is inline
assembly, which the coverage instrument cannot see. It is covered by unit tests, fork
tests against real mainnet contracts, and every end-to-end run.

## No symbolic proofs

The design notes ask for a symbolic proof of the freshness arithmetic. **halmos could not
be installed in this environment**, so that claim is not made. What exists instead is
every boundary enumerated by hand — reorg distances, the bound at −1/exact/+1, a zero
bound, `type(uint64).max` extremes — plus a wide fuzz. That is "tested very hard", not
"proved", and the difference is real.

## Mainnet historical verification requires archive access

`lens verify` and `tools/differential.mjs` re-read the source contract at the exact height
that was proven. The release run configures `ETHEREUM_ARCHIVE_RPC` and completed all ten
checks with zero divergence. Operators must provide equivalent archive access; an ordinary
RPC can refuse old mainnet state.

Inconclusive is reported as its own outcome and never as a divergence, and it does not
fail the run. A node declining to answer says nothing about whether the values agree, and
treating that as a disagreement would be both alarming and false.

Sepolia feeds check normally: its public RPCs serve the depth involved.

The values were byte-equal when they were proven — that comparison happens inside
`prove.mjs` at submission time, against the same height, and it is recorded in
`EVIDENCE.md`. What is missing is the ability to re-run it later.

## Latency figures are a sample, not a distribution

The lag numbers come from a handful of observations across one afternoon and one keeper
cycle. They are consistent, and they are labelled as a sample. A 24-hour distribution is
not yet collected.

## EVM only

Attestcoin readability is EVM-only, so Lens is. A new source chain is a configuration row
and needs no contract change, but it has to be an EVM chain Creditcoin attests.

## The trust that remains

Lens removes the oracle. It does not remove Creditcoin's validators: a value is as
trustworthy as the attestation of the block it came from. Every Attestcoin application
shares that assumption. Lens is built on it, not free of it.
