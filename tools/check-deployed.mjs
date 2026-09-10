/**
 * Checks that deployed bytecode still matches the source in this repository.
 *
 *   node tools/check-deployed.mjs
 *
 * Two things have to be masked before the comparison means anything, and getting either
 * wrong produces a false alarm:
 *
 *   Immutables are written into the runtime code at construction, so the artifact holds
 *   zeros where the deployed contract holds a constructor argument.
 *
 *   Solidity appends a CBOR metadata hash that changes when any source file in the
 *   project changes, including files the contract does not use.
 *
 * Masking both leaves the code that actually executes.
 */
import { readFileSync } from 'node:fs';
import { keccak256 } from 'ethers';
import { env, creditcoin, sourceProvider, addresses
} from '../prober/lib/config.mjs';

const stripMetadata = (hex) => {
  if (!hex || hex === '0x') return hex;
  const b = hex.slice(2);
  const len = parseInt(b.slice(-4), 16);
  if (!len || len * 2 + 4 > b.length) return hex;
  return '0x' + b.slice(0, b.length - (len * 2 + 4));
};

/** Blank every immutable slot, in both, so a constructor argument is not a difference. */
const maskImmutables = (hex, refs) => {
  let b = hex.slice(2).split('');
  for (const slots of Object.values(refs ?? {})) {
    for (const { start, length } of slots) {
      for (let i = start * 2; i < (start + length) * 2 && i < b.length; i++) b[i] = '0';
    }
  }
  return '0x' + b.join('');
};

const targets = [
  ['LensRegistry', addresses.registry, creditcoin],
  ['LensAggregatorV3', addresses.aggregator, creditcoin],
  ['CircuitBreaker', addresses.breaker, creditcoin],
  ['FeedEscrow', addresses.escrow, creditcoin],
  ['VotePort', addresses.votePort, creditcoin],
  ['SnapshotProver', addresses.snapshotProver, creditcoin],
  ['LensMarket', addresses.market, creditcoin],
  ['ReserveMonitor', addresses.reserveMonitor, creditcoin],
  ['StateProbe', addresses.probe, sourceProvider(11155111)],
  ['StateProbe (mainnet)', addresses.probe, sourceProvider(1)],
];

let stale = 0;
console.log('');
for (const [label, address, provider] of targets) {
  const name = label.split(' ')[0];
  if (!address) { console.log(`  skip  ${label}: no address configured`); continue; }
  let art;
  try {
    art = JSON.parse(readFileSync(new URL(`../out/${name}.sol/${name}.json`, import.meta.url)));
  } catch {
    console.error(`\n  no compiled artifact for ${name}. Run: forge build\n`);
    process.exit(2);
  }
  const refs = art.deployedBytecode.immutableReferences;

  const local = keccak256(maskImmutables(stripMetadata(art.deployedBytecode.object), refs));
  const onChain = keccak256(maskImmutables(stripMetadata(await provider.getCode(address)), refs));

  if (local === onChain) console.log(`  ok    ${label.padEnd(22)} matches the source in this repository`);
  else { stale++; console.log(`  STALE ${label.padEnd(22)} deployed code is not this source — redeploy or check out the commit it was built from`); }
}
console.log(`\n${stale ? `${stale} deployment(s) stale` : 'every deployment matches the source here'}\n`);
process.exit(stale ? 1 : 0);
