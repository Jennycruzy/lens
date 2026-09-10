/**
 * Measures what Lens costs and how far behind it runs, right now.
 *
 *   node prober/bench.mjs
 *
 * Reads gas from transactions that actually happened rather than estimating, and lag from
 * the frontier against the live source head. Nothing here is a projection.
 */
import { formatUnits } from 'ethers';
import {
  creditcoin, sourceProvider, sources, registryContract, supportedChains, addresses,
} from './lib/config.mjs';

const registry = registryContract();

console.log('\nAttestation lag, measured now\n');
const lags = [];
for (const c of await supportedChains()) {
  if (!sources[c.chainId]) continue;
  const frontier = Number(await registry.frontierOf(c.chainKey));
  const head = await sourceProvider(c.chainId).getBlockNumber();
  const lag = head - frontier;
  lags.push({ chain: sources[c.chainId].label, frontier, head, lag });
  console.log(`  ${sources[c.chainId].label.padEnd(18)} ${String(lag).padStart(4)} blocks behind  (~${((lag * 12) / 60).toFixed(1)} min)`);
}

console.log('\nGas, from transactions that happened\n');
// Each of these is a real transaction on the chain named; the receipt is the measurement.
const samples = [
  ['probe, one feed', 'sepolia', '0xc81f990f33fd6053b66ae5906b6e19dc081f12270430aa70ae7de0f3cc1af013'],
  ['probeMany, three feeds', 'sepolia', '0x98e6f374ccf71fe9481c3f65751d211e1df5f4f4aa9390aaffa3ca86b41fe92b'],
  ['probeMany, three mainnet feeds', 'mainnet', '0x328ecec676aef660e30bb878353f7d3a10bfde5288377892378943abe68f40c7'],
  ['prove one feed', 'creditcoin', '0xd9290d8dc006cead38f120e9edc5bd241d810dd412a79f92e16b37821ed22668'],
  ['prove two feeds, shared continuity proof', 'creditcoin', '0x82653274dbb461627b6c5d96f6ba9d37681ce7a21145a4c5da7e9b95ce3c8f6d'],
  ['prove and claim through the escrow', 'creditcoin', '0x6458a17105e489dfe2cf352b3e6b095f56d2c000dd83cd4dda30ed7821987a23'],
];
const providerFor = { creditcoin, sepolia: sourceProvider(11155111), mainnet: sourceProvider(1) };
const gas = {};
for (const [label, chain, hash] of samples) {
  try {
    const r = await providerFor[chain].getTransactionReceipt(hash);
    if (!r) { console.log(`  ${label.padEnd(42)} not found on ${chain}`); continue; }
    gas[label] = Number(r.gasUsed);
    console.log(`  ${label.padEnd(42)} ${String(r.gasUsed).padStart(8)} gas  (${chain})`);
  } catch (e) {
    console.log(`  ${label.padEnd(42)} unreadable: ${e.shortMessage ?? e.message}`);
  }
}

const one = gas['prove one feed'];
const two = gas['prove two feeds, shared continuity proof'];
if (one && two) {
  const marginal = two - one;
  console.log(`\n  marginal cost of a feed inside a shared proof: ${marginal} gas`);
  console.log(`  ten feeds under one proof would approach ${Math.round((one + 9 * marginal) / 10)} gas each,`);
  console.log(`  against ${one} proven one at a time`);
}

console.log('\nWhat that costs\n');
for (const [chain, label] of [['mainnet', 'Ethereum mainnet'], ['sepolia', 'Sepolia'], ['creditcoin', 'Creditcoin']]) {
  try {
    const fee = await providerFor[chain].getFeeData();
    console.log(`  ${label.padEnd(18)} ${formatUnits(fee.gasPrice ?? 0n, 'gwei')} gwei`);
  } catch { /* a chain that will not answer is not worth failing over */ }
}
console.log('');
