# @lens/sdk

Read verified cross-chain state from Lens on Creditcoin.

```js
import { Lens } from '@lens/sdk';

const lens = new Lens('https://rpc.cc3-testnet.creditcoin.network', REGISTRY_ADDRESS);

// A value read on Ethereum Sepolia, proven to Creditcoin.
const price = await lens.readValue(
  11155111,                                       // native chain id, never a chain key
  '0x694AA1769357215DE4FAC081bf1f309aDC325306',
  'latestAnswer() returns (int256)',
  [],
  600,                                            // largest acceptable age, in source blocks
);
```

## Two things worth knowing

**Chain keys are environment-local.** The same integer means different chains on
different Attestcoin environments: Ethereum mainnet is key 3 on CC3 testnet and key 1 on
CC3 mainnet, where key 1 on testnet is Sepolia. Nothing in this package takes a chain key
as input — you pass a native chain id and the key is resolved from the precompile, so
code written against this cannot report the wrong chain's state.

**Age is measured in blocks of the source chain**, not seconds and not Creditcoin
heights. It is how far behind the attested head of the source chain a value sits. Pass
the largest age you can tolerate; anything older is refused.

## Refusing rather than guessing

`read` never returns a value it cannot stand behind, and says which kind of refusal it is:

| Refusal | Means | What to do |
|---|---|---|
| `missing` | never proven | ask a prober to probe it |
| `call-reverted` | proven, and the source read failed | the target cannot answer this |
| `truncated` | the answer is a prefix | the target returns more than the probe carries |
| `stale` | outside the age you allowed | wait, or widen the bound if the feed permits |

`readValue` decodes and throws instead, for callers that would rather not branch.

## Checking rather than trusting

```js
const { verified, onLens, onSource, atHeight } = await lens.verify(
  11155111, target, callData, 'https://ethereum-sepolia-rpc.publicnode.com',
);
```

Calls the same contract with the same calldata on the source chain, at the exact height
that was proven, and compares the bytes. This is the claim Lens rests on, offered as a
function so you can check it rather than take it on trust.
