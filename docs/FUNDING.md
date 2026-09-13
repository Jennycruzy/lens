# Getting the key funded

Lens needs gas on three chains, and only two of them are free. Check the position at
any time:

```
node tools/balances.mjs
```

The address is in `.env` as `LENS_ADDRESS`. The private key sits in the same file, which
is ignored by git and readable only by the owner. It is a testnet key: never send mainnet
funds to it.

---

## tCTC on Creditcoin CC3 testnet — needed to deploy anything

There is no web form. The faucet is a Discord bot.

1. Join the Creditcoin Discord: <https://discord.gg/creditcoin>
2. Open the **`token-faucet`** channel.
3. Send, with the EVM address exactly as it appears in `.env`:

   ```
   /faucet address:0x...
   ```

4. The bot replies "CTC faucet submitted", then "CTC Faucet successful" in a thread it
   creates. Balance arrives at the second message.

The same command and channel serve both Substrate and EVM addresses — the bot decides
from the address format, so the EVM address is all that is needed here.

Confirm it landed with `node tools/balances.mjs`, or on Blockscout:
<https://creditcoin-testnet.blockscout.com/address/0x...>

## Sepolia ETH — needed for the free source chain

Any of these work; they are listed in the order worth trying, and all were reachable on
2026-09-10. Most ask for a signed-in account or a mainnet balance to deter draining, so
having one that works matters more than which.

| Faucet | Notes |
|---|---|
| <https://cloud.google.com/application/web3/faucet/ethereum/sepolia> | Google account, no mainnet balance required — usually the least friction |
| <https://www.alchemy.com/faucets/ethereum-sepolia> | free Alchemy account; the same account also gives the archive RPC needed later |
| <https://faucets.chain.link/sepolia> | wallet sign-in |
| <https://faucet.quicknode.com/ethereum/sepolia> | wants a small mainnet balance |
| <https://sepolia-faucet.pk910.de/> | mines in-browser, slow but needs no account at all |

About 0.1 SepoliaETH is plenty: it covers deploying the probe and a long run of reads.

## Real ETH on Ethereum mainnet — optional, and last

Not needed for anything to work. It buys the part that cannot be argued with: live
mainnet values on a Creditcoin testnet deployment.

Reads are cheap. Three real feeds in one transaction measured **143,660 gas** on mainnet
(tx `0x2e0728…`, 2026-09-13; the fork test estimates 155,260 for a different set of three),
so at 10 gwei a batch costs on the order of 0.0015 ETH. A few hundredths of an ETH funds weeks of
reads. The prober refuses to send above a configured gas-price ceiling and
queues instead, so a spike cannot quietly drain the key.

Fund this one only when the rest is working end to end, and keep the balance small — it
is a hot key on a server by definition.

---

## What unblocks what

| Have | Can do |
|---|---|
| nothing | everything already built: contracts, the full test suite, the mainnet fork tests |
| tCTC | deploy the registry and consumer standard, verify them on Blockscout |
| tCTC + Sepolia | the complete path end to end — probe, prove, record, read — at zero cost |
| the above + mainnet ETH | the same path carrying live Ethereum mainnet values |
