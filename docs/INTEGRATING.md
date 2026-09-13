# Integrating

## A consumer in a few lines

```solidity
import {LensConsumer} from "lens/contracts/src/LensConsumer.sol";
import {LensRegistry} from "lens/contracts/src/LensRegistry.sol";

contract YourContract is LensConsumer {
    uint64 private immutable SOURCE_KEY;

    constructor(LensRegistry lens, uint64 sourceKey) LensConsumer(lens) {
        SOURCE_KEY = sourceKey;
    }

    function _defaultChainKey() internal view override returns (uint64) {
        return SOURCE_KEY;
    }

    function reserves(bytes32 feedId) external view returns (uint256) {
        return _latestUint(feedId, 300);   // refuses if older than 300 source blocks
    }
}
```

Every read carries a freshness bound and there is no version that does not. A function
returning a value without one would be used, and it would defeat the design in a line.

**Resolve `sourceKey` from Creditcoin's ChainInfo for the environment you deploy to, at
deployment time.** Chain keys are local to one Attestcoin environment: Ethereum mainnet is
key 3 on CC3 testnet and key 1 on CC3 mainnet, where key 1 on testnet is Sepolia. Never
copy a key from another environment or from an example. The registry itself resolves and
asserts its keys at construction (`LensRegistry.sourceOf(key)` returns the native chain
id it was bound to), and `templates/create-lens-feed` scaffolds a consumer with the key
looked up for you.

## Already written against `AggregatorV3Interface`?

`LensAggregatorV3` exposes one Lens feed through the familiar `AggregatorV3Interface`, so
a contract already written against that interface can consume slow-moving or
time-averaged cross-chain state with minimal integration work:

```solidity
AggregatorV3Interface feed = AggregatorV3Interface(LENS_AGGREGATOR);
(, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
require(block.timestamp - updatedAt <= maxAge, "stale");
```

Two deliberate differences from Chainlink, both toward safety:

- **A stale feed reverts** rather than being handed back for the caller to notice. A
  protocol that forgot to check is protected by the feed instead of by its own diligence.
- **`getRoundData` for a past round refuses.** The registry keeps only the newest
  observation, so there is no honest answer; returning the current value under an old
  round id would be a lie a market could liquidate on.

`updatedAt` is the **source chain's** clock. Your staleness check therefore measures the
real age of the number, not how recently it happened to arrive on Creditcoin.

**What this is not for.** The value arrives minutes after the source block, so the adapter
is for feeds whose meaning survives that lag: exchange rates, reserves, time-averaged
inputs, checkpointed state. It is not intended for block-sensitive spot pricing, perp
marks or fast liquidation engines, and a feed carried from Chainlink keeps Chainlink's own
trust assumptions — Lens removes the need for a trusted cross-chain reporter, nothing more.

## From JavaScript

The SDK is in `sdk/` of this repository (not on npm yet: `npm install ./lens/sdk`).

```js
import { Lens } from '@jennycruzy/lens-sdk';
const lens = new Lens(CREDITCOIN_RPC, REGISTRY);

const rate = await lens.readValue(
  1,                           // native chain id — never a chain key
  STETH, 'getPooledEthByShares(uint256) returns (uint256)', ['1000000000000000000'], 2400,
);
```

## Choosing `maxAge`

Age is in **blocks of the source chain**. The frontier trails the head by 30–40 blocks, so
**any bound below about 50 can never be satisfied**. That is the floor, not a target.

| Feed class | Suggested bound | Why |
|---|---|---|
| 30-minute TWAP | 150–300 blocks (30–60 min) | The average already spans longer than the lag |
| Liquid-staking rate | 600–2400 blocks (2–8 h) | Moves basis points per day |
| Reserves, supply | 600–1800 blocks | Checkpoints, not ticks |
| Governance weight at a snapshot | 5000+ blocks | The snapshot block is fixed; only the proof's age matters |
| Access lists, pause flags | 300–900 blocks | Change deliberately and rarely |

Two rules worth keeping:

**Pick the bound from what the value means, not from how fresh you would like it to be.**
A tight bound on a slow-moving value buys nothing and guarantees outages.

**Never widen a bound to make a revert go away.** The revert is the feed telling you it no
longer describes what you think it describes.

## Handling refusal

`_latest` reverts with four distinct errors, and they call for different responses:

| Error | Means | Do |
|---|---|---|
| `FeedUnavailable` | never proven | ask a prober, or fund the feed's escrow |
| `FeedReadFailed` | proven, and the source read failed | the target cannot answer this call |
| `FeedTruncated` | the answer is a prefix | the target returns more than a probe carries |
| `FeedStale` | outside your bound | wait, or reconsider the bound |

Use `_tryLatest` where you would rather degrade than revert. It returns `ok` and the age
and never carries a value when it refuses, so a refused read cannot be used by accident.

## Checking rather than trusting

```
node tools/differential.mjs
```

Reads what Creditcoin holds for every feed and calls the same contract with the same
calldata on the source chain at the exact height that was proven. The SDK exposes the same
comparison as `lens.verify(...)`, and the web app runs it in the browser. If any of them
ever disagree, nothing else in this repository is worth reading.

## Before you go live

- Read the Limits section of the README. If your value must be current within a block,
  Lens is the wrong tool.
- Make sure something keeps your feed fresh — `prober/keep.mjs`, or fund `FeedEscrow` so
  anyone is paid to.
- Decide what your protocol does when a feed refuses, and test that path. It will happen.
