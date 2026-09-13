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
| Source block | 25,963,759 |
| Probe transaction | [`0xf701eb273d6ea254c0aba772cba2cec4a43e971408a4b7e8df342f96f1734977`](https://etherscan.io/tx/0xf701eb273d6ea254c0aba772cba2cec4a43e971408a4b7e8df342f96f1734977) |
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

The current prober pins its direct read, then compares against the block in the emitted
event. The fresh two-feed mainnet probe recorded the Uniswap observation with
`success=true` and byte-equal returndata at block 25,963,759. Its measured gas model
reserved a 38,365-gas wrapper baseline plus direct target estimates, avoiding the
underestimate that can occur when a probe intentionally catches an inner revert.

The comparison re-reads at the block the probe actually ran in. A feed whose value moves
every block is exactly the case a fixed-value feed would never have exposed.

## Reproducing it

```
node prober/probe.mjs mainnet.uniswap.ethUsdcTwap
node prober/prove.mjs <tx-hash> 1
node tools/differential.mjs
```

The last command re-reads every held value against its source at the proven height. It is
the same comparison, run against whatever is live rather than against this transcript.
