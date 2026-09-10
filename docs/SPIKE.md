# The spike

The one result everything else depended on: **a real Uniswap V3 TWAP, read on Ethereum
mainnet, proven to a Creditcoin testnet contract, byte-equal to a direct call.**

If this had failed, nothing else in this repository would have been worth building. It is
recorded first because it was done first.

## What was proven

| | |
|---|---|
| Source chain | Ethereum mainnet — chain key **3** on CC3 testnet |
| Target | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`, the USDC/WETH 0.05% pool |
| Call | `observe([1800, 0])` — a 30-minute time-weighted observation |
| Source block | 25,949,269 |
| Probe transaction | [`0x328ecec676aef660e30bb878353f7d3a10bfde5288377892378943abe68f40c7`](https://etherscan.io/tx/0x328ecec676aef660e30bb878353f7d3a10bfde5288377892378943abe68f40c7) |
| Returndata | **288 bytes**, two dynamic arrays |
| Result | byte-equal to a direct `eth_call` at the same height |

```
on Creditcoin : 0x0000…0040 0000…00a0 0000…0002 0000…1e7bcad29e8f 0000…1e7be016feb7
                0000…0002 0000…02023d13125837ea5f2e41bf32 0000…02023d2c7bf91aeb50c7799acf
on the source : (identical)

decoded       : tick cumulatives 33517032611471, 33517389414071
```

## Why the variable-length case was the risk

A fixed 32-byte return is the easy case. The escalation the design notes call for was
fixed-width → single dynamic word → array, recording where it breaks.

`observe(uint32[])` returns **two dynamic arrays** — offsets, lengths and elements, 288
bytes in total. It is the hardest shape in the ordinary feed set, and it survived the
whole path intact: emitted by the probe, carried in the transaction encoding, proven by
the precompile, decoded by the registry, and stored.

**It does not break at 288 bytes.** The probe caps returndata at 8,192 bytes and flags
anything longer as truncated, and a consumer refuses a truncated value rather than
decoding a prefix. Where the proof path itself would fail is above that cap and has not
been reached, because nothing sensible to probe returns that much.

## Why a TWAP and not a spot price

The frontier trails the source head by 30–40 blocks, about eight minutes. A spot price
read eight minutes late is a different number. **A thirty-minute average read eight
minutes late is still a thirty-minute average.**

That is the whole feed-selection rule, and the spike deliberately proved the class Lens is
built for rather than the class it cannot serve.

## What the first probe found

The pre-flight comparison in the prober reported the TWAP as **not matching**, and it was
the tool that was wrong, not Lens. `observe(…, 0)` is relative to the current block; the
comparison read at block 25,949,267 and the probe executed at 25,949,269. Two blocks of
legitimate movement, reported as a divergence.

The comparison now re-reads at the block the probe actually ran in. Recorded because a
feed whose value moves every block is exactly the case a fixed-value feed would never have
exposed — every earlier feed had passed.

## Reproducing it

```
node prober/probe.mjs mainnet.uniswap.ethUsdcTwap
node prober/prove.mjs <tx-hash> 1
node tools/differential.mjs
```

The last command re-reads every held value against its source at the proven height. It is
the same comparison, run against whatever is live rather than against this transcript.
