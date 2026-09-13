# Setting up

Requires [Foundry](https://getfoundry.sh) and Node 20 or newer.

```
npm install                              # Creditcoin contracts package and SDK
forge install foundry-rs/forge-std --no-git   # test library, not vendored into this repo
cp .env.example .env                     # then fill in the keys
forge build && forge test
```

Dependencies are installed rather than committed, so everything in this repository's
history is work written for it. `@gluwa/asc-contracts` and `@gluwa/usc-sdk` come from npm
and carry the precompile interfaces and proof tooling; `forge-std` is the Foundry test
library.

## Checking the deployment without deploying anything

```
node tools/verify-infra.mjs    # every dependency, re-derived from the live network
node tools/balances.mjs        # what the key holds on each chain
```

`verify-infra` exits non-zero if any check fails and writes its findings to
`docs/evidence/infra-verification.json`.

## Running the loop end to end

```
node prober/probe.mjs sepolia.weth.totalSupply     # read on the source chain, emit it
node prober/prove.mjs <tx-hash> 11155111           # prove it to Creditcoin, compare
```

The second command waits for attestation, which takes about eight minutes.

## Continuous checks

`.circleci/config.yml` and `.github/workflows/tests.yml` run the same commands: the
offline suites, the generated page config and the page's static shape on every push;
the fork tests, the live infrastructure, claim, page and differential checks nightly.
Neither needs a secret. Set `ETHEREUM_ARCHIVE_RPC` in the CI project to make the
nightly mainnet comparisons conclusive; without it they are reported as inconclusive.
