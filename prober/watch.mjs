/**
 * Watches feeds age, and says when one is about to stop being readable.
 *
 *   node prober/watch.mjs [--interval 30] [--warn 400]
 *
 * A prober that only reports failures reports them too late. Age is visible here as it
 * grows, so the moment a feed crosses a consumer's bound is something you saw coming
 * rather than something you find out from a revert.
 */
import {
  feeds, callDataFor, chainKeyFor, computeFeedId, registryContract, sources,
} from './lib/config.mjs';

const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i === -1 ? d : Number(process.argv[i + 1]); };
const intervalMs = arg('interval', 30) * 1000;
const warnAt = arg('warn', 400);

const registry = registryContract();
const resolved = [];
for (const feed of feeds) {
  const chainKey = await chainKeyFor(feed.chainId);
  resolved.push({ feed, chainKey, id: computeFeedId(chainKey, feed.target, callDataFor(feed)) });
}

const stamp = () => new Date().toISOString().replace('T', ' ').slice(11, 19);
const previous = {};

async function tick() {
  const frontiers = {};
  const lines = [];
  for (const { feed, chainKey, id } of resolved) {
    frontiers[chainKey] ??= Number(await registry.frontierOf(chainKey));
    if (!(await registry.hasObservation(id))) {
      lines.push(`  ${feed.name.padEnd(32)}     —  never proven`);
      continue;
    }
    const o = await registry.observationOf(id);
    const age = frontiers[chainKey] > Number(o.probeHeight) ? frontiers[chainKey] - Number(o.probeHeight) : 0;

    // A value that changed is worth seeing, not just an age that grew.
    const changed = previous[id] !== undefined && previous[id] !== o.returnData;
    previous[id] = o.returnData;

    const mark = age > warnAt ? 'AGEING' : '      ';
    lines.push(`  ${feed.name.padEnd(32)} ${String(age).padStart(5)}  ${mark}${changed ? '  value changed' : ''}`);
  }
  console.log(`\n[${stamp()}] age in source blocks` +
    Object.entries(frontiers).map(([k, v]) => `   key ${k} frontier ${v}`).join(''));
  console.log(lines.join('\n'));
}

console.log(`watching ${resolved.length} feed(s) every ${intervalMs / 1000}s; warning above ${warnAt} blocks`);
console.log(`chains: ${[...new Set(feeds.map((f) => sources[f.chainId].label))].join(', ')}`);
await tick();
setInterval(() => tick().catch((e) => console.error(`[${stamp()}] ${e.shortMessage ?? e.message}`)), intervalMs);
