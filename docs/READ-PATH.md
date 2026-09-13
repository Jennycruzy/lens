# The read, proven byte-for-byte

The claim Lens rests on is narrow and testable: **what the probe emits is exactly what
the target returns.** If that ever diverges, every number Lens publishes is worthless.
So it is asserted in code against real Ethereum mainnet state, not demonstrated once by
hand.

```
forge test --match-path 'contracts/test/fork/*' -vv
```

Run 2026-09-10 against Ethereum mainnet (chain key 3 on CC3 testnet), 5/5 passing.

| Read | Target | Value observed | Byte-equal to a direct call |
|---|---|---|---|
| Uniswap V3 30-minute TWAP | USDC/WETH 0.05% pool | average tick `198282`, about 2,451 USDC per ETH | yes |
| ERC-20 total supply | USDC | 50,578,278,081,858,490 — about $50.58B | yes |
| ERC-20 balance | USDC held by the 0.05% pool | 74,568,403,997,651 — about $74.57M | yes |
| Liquid-staking rate | stETH `getPooledEthByShares(1e18)` | 1.243714506052480615 | yes |
| A read that fails | USDC, a function it does not have | recorded as failed, empty revert data | n/a |

Three of those feeds in a single source transaction cost **155,260 gas** in the fork test
(the live mainnet batch of stETH, ENS and Uniswap measured 143,660, see `LATENCY.md`),
which is the number that makes batching worth doing: one transaction, one block, one continuity proof
on the Creditcoin side.

## Why these reads and not a spot price

Every value above is either time-averaged or a slowly-moving accumulator. That is
deliberate. The attestation frontier trails the source head by roughly eight minutes
(measured in `VERIFIED.md`), so a feed is only honest if its meaning survives that lag.

- A 30-minute TWAP read eight minutes late is still a 30-minute TWAP.
- A liquid-staking exchange rate moves on the order of basis points per day.
- A token supply or a reserve balance is a checkpoint, not a tick.

A spot price for fast liquidation is not in this set and will not be. That limit is
published rather than hidden, because a feed whose meaning depends on being current is
the one case where this design is the wrong tool.

## What a reverted read is worth

`test_unsupportedFunctionOnARealTokenIsReportedAsFailure` asks USDC for a function it
does not have. The probe records `success = false` and emits it anyway.

That matters because it separates two states a consumer must never confuse: *the read
failed* and *no read exists*. The first is a fact about the source chain and is provable.
The second is silence, and silence is what a withholding prober produces. A consumer that
cannot tell them apart cannot fail closed.
