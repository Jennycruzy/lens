# Evidence

Every address and transaction behind a claim in this repository. Nothing here is a
plan; each row is on a public chain and can be checked without asking us.

## Deployed

| What | Chain | Address | Status |
|---|---|---|---|
| `StateProbe` | Ethereum Sepolia (chain key 1) | [`0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe`](https://sepolia.etherscan.io/address/0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe) | live, 1,042 bytes |
| `StateProbe` | Ethereum mainnet (chain key 3) | `0xf9902F4CfEDF6fFDC4B8987e9132Fa968ADB70fe` | same address, awaiting funding |

The probe is deployed through the standard deterministic deployer with the salt
`keccak256("lens.state-probe.v1")`, so its address is a property of its bytecode rather
than of who deployed it or when. Anyone can verify the address without trusting us:

```
cast compute-address --create2 \
  --salt $(cast keccak "lens.state-probe.v1") \
  --init-code-hash 0x405e87ce05c732afa93d801edefea825cf7c1847bdab009a21a6a51b7b9290b5 \
  0x4e59b44847b379578588920cA78FbF26c0B4956C
```

That also means the mainnet probe is already pinned: when the key is funded, the same
bytecode lands at the same address, and the registry needs no change.

### Transactions

| What | Chain | Hash |
|---|---|---|
| `StateProbe` deployment | Sepolia | [`0x00534c2a78f3b7ec070aa9376ed9029ed50fa37a8a55ce2f3dffac1b9751d967`](https://sepolia.etherscan.io/tx/0x00534c2a78f3b7ec070aa9376ed9029ed50fa37a8a55ce2f3dffac1b9751d967) |

### Deployed state, read back from the chain

| Call | Answer |
|---|---|
| `MAX_RETURN_BYTES()` | 8192 |
| `MAX_PROBE_GAS()` | 2000000 |

## Measured

| Measurement | Value | Where |
|---|---|---|
| Attestation lag, Ethereum mainnet | 39 blocks, about 7.8 minutes | `VERIFIED.md` |
| Attestation lag, Sepolia | 41 blocks, about 8.2 minutes | `VERIFIED.md` |
| Three real mainnet feeds in one probe transaction | 155,260 gas | `READ-PATH.md` |
| `StateProbe` deployment | 385,849 gas, 0.00094 ETH at 1.2 gwei | this file |
