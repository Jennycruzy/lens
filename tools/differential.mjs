/**
 * Compares every value Lens holds against the source contract that produced it.
 *
 *   node tools/differential.mjs [--json]
 *
 * For each feed the registry knows about, this reads the observation from Creditcoin and
 * calls the same target with the same calldata on the source chain, at the exact height
 * that was proven. Any divergence is a hard failure: it would mean a value on Creditcoin
 * that the source chain does not agree with, which is the one outcome that makes the
 * whole design worthless.
 *
 * This is deliberately not a test against a fixture. It runs against whatever is live.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { Contract } from 'ethers';
import {
  feeds, callDataFor, decodeFor, chainKeyFor, computeFeedId,
  creditcoin, sourceProvider, registryContract, addresses, sources,
} from '../prober/lib/config.mjs';

const registry = registryContract();
const rows = [];

for (const feed of feeds) {
  const chainKey = await chainKeyFor(feed.chainId);
  const callData = callDataFor(feed);
  const feedId = computeFeedId(chainKey, feed.target, callData);
  const row = { feed: feed.name, chainId: feed.chainId, chainKey, target: feed.target, feedId };

  if (!(await registry.hasObservation(feedId))) {
    rows.push({ ...row, status: 'absent', note: 'never proven, so nothing to compare' });
    continue;
  }

  const o = await registry.observationOf(feedId);
  row.probeHeight = Number(o.probeHeight);
  row.onCreditcoin = o.returnData;
  row.callSucceeded = o.callSucceeded;

  if (!o.callSucceeded) {
    rows.push({ ...row, status: 'failed-read', note: 'recorded as a failed source read' });
    continue;
  }

  // The comparison. Same target, same calldata, same height.
  const provider = sourceProvider(feed.chainId);
  let onSource;
  try {
    onSource = await provider.call({ to: feed.target, data: callData, blockTag: row.probeHeight });
  } catch (e) {
    rows.push({ ...row, status: 'unreachable', note: e.shortMessage ?? e.message });
    continue;
  }

  row.onSource = onSource;
  row.agrees = onSource === o.returnData;
  row.status = row.agrees ? 'match' : 'DIVERGED';
  if (row.agrees) {
    try {
      row.value = feed.describe(decodeFor(feed, o.returnData));
    } catch { /* a feed without a decoder still counts as matching bytes */ }
  }
  rows.push(row);
}

const compared = rows.filter((r) => r.status === 'match' || r.status === 'DIVERGED');
const diverged = rows.filter((r) => r.status === 'DIVERGED');
const unreachable = rows.filter((r) => r.status === 'unreachable');

const report = {
  generatedAt: new Date().toISOString(),
  registry: addresses.registry,
  creditcoinHeight: await creditcoin.getBlockNumber(),
  compared: compared.length,
  diverged: diverged.length,
  unreachable: unreachable.length,
  rows,
};

mkdirSync('docs/evidence', { recursive: true });
writeFileSync('docs/evidence/differential.json', JSON.stringify(report, null, 2) + '\n');

if (process.argv.includes('--json')) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log(`\nDifferential run  ${report.generatedAt}`);
  console.log(`registry ${addresses.registry}, Creditcoin height ${report.creditcoinHeight}\n`);
  for (const r of rows) {
    const mark = r.status === 'match' ? 'match ' : r.status === 'DIVERGED' ? 'DIVERGE' : r.status.padEnd(6);
    console.log(`  ${mark}  ${r.feed}`);
    if (r.probeHeight) console.log(`          ${sources[r.chainId].label} block ${r.probeHeight}`);
    if (r.status === 'match') console.log(`          ${r.value ?? r.onCreditcoin.slice(0, 26) + '…'}`);
    if (r.status === 'DIVERGED') {
      console.log(`          Creditcoin ${r.onCreditcoin}`);
      console.log(`          source     ${r.onSource}`);
    }
    if (r.note) console.log(`          ${r.note}`);
  }
  console.log(`\n${compared.length} compared, ${diverged.length} diverged, ${unreachable.length} unreachable  ->  docs/evidence/differential.json\n`);
}

process.exit(diverged.length || unreachable.length ? 1 : 0);
