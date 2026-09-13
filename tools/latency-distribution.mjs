/**
 * The end-to-end latency distribution, from the indexer's record of every observation.
 *
 *   node tools/latency-distribution.mjs
 *
 * For each proven observation in docs/evidence/observations.json this takes the source
 * block's timestamp (the moment the value was read) and the Creditcoin block's timestamp
 * (the moment it became readable) and reports the difference. That is the number a
 * consumer cares about: how long after a source block a value can be acted on.
 *
 * It includes the keeper's own polling interval and the proof builder's lag, not only the
 * attestation lag, and it says so. Every row names its two blocks, so any figure here can
 * be re-derived from the chains.
 */
import { readFileSync } from 'node:fs';
import { creditcoin, sourceProvider, supportedChains } from '../prober/lib/config.mjs';

const store = JSON.parse(readFileSync(new URL('../docs/evidence/observations.json', import.meta.url), 'utf8'));
const chains = await supportedChains();
const chainIdOf = Object.fromEntries(chains.map((c) => [c.chainKey, c.chainId]));

// One proof transaction carries several feeds probed in one source block; measure each
// (source block, Creditcoin block) pair once.
const pairs = new Map();
for (const o of store.observations) {
  if (!o.callSucceeded) continue;
  const key = `${o.chainKey}:${o.probeHeight}:${o.creditcoinBlock}`;
  if (!pairs.has(key)) pairs.set(key, { chainKey: o.chainKey, probeHeight: o.probeHeight, creditcoinBlock: o.creditcoinBlock, tx: o.creditcoinTx });
}

const stamps = new Map();
async function timestamp(provider, label, height) {
  const k = `${label}:${height}`;
  if (!stamps.has(k)) stamps.set(k, (await provider.getBlock(height)).timestamp);
  return stamps.get(k);
}

const byChain = {};
for (const p of pairs.values()) {
  const chainId = chainIdOf[p.chainKey];
  if (!chainId) continue;
  const source = await timestamp(sourceProvider(chainId), chainId, p.probeHeight);
  const landed = await timestamp(creditcoin, 'cc3', p.creditcoinBlock);
  (byChain[chainId] ??= []).push({ ...p, seconds: landed - source, source, landed });
}

const pct = (xs, q) => xs[Math.min(xs.length - 1, Math.floor(q * xs.length))];
const mins = (s) => (s / 60).toFixed(1);
for (const [chainId, rows] of Object.entries(byChain)) {
  const secs = rows.map((r) => r.seconds).sort((a, b) => a - b);
  const first = Math.min(...rows.map((r) => r.source));
  const last = Math.max(...rows.map((r) => r.landed));
  const label = chains.find((c) => c.chainId === Number(chainId))?.chainName ?? chainId;
  console.log(`\n${label} (chain id ${chainId}) — ${rows.length} proof landings over ${((last - first) / 3600).toFixed(1)} hours`);
  console.log(`  from ${new Date(first * 1000).toISOString()} to ${new Date(last * 1000).toISOString()}`);
  console.log(`  source block -> readable on Creditcoin, in minutes:`);
  console.log(`  min ${mins(secs[0])}   p50 ${mins(pct(secs, 0.5))}   p90 ${mins(pct(secs, 0.9))}   p95 ${mins(pct(secs, 0.95))}   max ${mins(secs[secs.length - 1])}`);
  const slowest = rows.sort((a, b) => b.seconds - a.seconds)[0];
  console.log(`  slowest: source block ${slowest.probeHeight} -> CC3 block ${slowest.creditcoinBlock} (${mins(slowest.seconds)} min), tx ${slowest.tx}`);
}
