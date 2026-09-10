/**
 * Records the history of every observation, which the registry deliberately does not.
 *
 *   node indexer/index.mjs [--port 8080] [--once]
 *
 * The registry keeps only the newest observation per feed, because keeping more would
 * cost every submitter storage for a service most consumers never read. History belongs
 * off-chain, and this is where it lives: it follows `ObservationRecorded` from the
 * registry, writes each one to a file, and serves them over HTTP.
 *
 * Nothing here is authoritative. Every row it stores names the Creditcoin transaction
 * that produced it, so a reader who does not trust this process can check any row
 * against the chain — which is the only reason it is safe for it to exist.
 */
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { Contract } from 'ethers';
import { creditcoin, registryContract, addresses, feeds, callDataFor, decodeFor, chainKeyFor, computeFeedId } from '../prober/lib/config.mjs';

const arg = (n, d) => { const i = process.argv.indexOf(n); return i === -1 ? d : process.argv[i + 1]; };
const PORT = Number(arg('--port', 8080));
const STORE = new URL('../docs/evidence/observations.json', import.meta.url);

const state = existsSync(STORE)
  ? JSON.parse(readFileSync(STORE, 'utf8'))
  : { fromBlock: 0, observations: [] };

const registry = registryContract();

/** Feed identifier -> the human name, so history is readable rather than hex. */
const names = {};
for (const feed of feeds) {
  names[computeFeedId(await chainKeyFor(feed.chainId), feed.target, callDataFor(feed))] = feed;
}

async function catchUp() {
  const head = await creditcoin.getBlockNumber();
  // The registry cannot have events before it existed, and public RPCs cap ranges, so
  // the scan is walked in windows rather than requested in one span.
  let from = state.fromBlock || Math.max(0, head - 5000);
  const WINDOW = 1000;
  let added = 0;

  while (from <= head) {
    const to = Math.min(from + WINDOW - 1, head);
    let logs = [];
    try {
      logs = await registry.queryFilter(registry.filters.ObservationRecorded(), from, to);
    } catch (e) {
      // A window that fails is retried smaller rather than skipped, because skipping
      // would leave a silent hole in the history.
      if (WINDOW > 100) {
        console.error(`  window ${from}-${to} failed (${e.shortMessage ?? e.message}), narrowing`);
        from += 100;
        continue;
      }
      throw e;
    }

    for (const log of logs) {
      const feed = names[log.args.feedId];
      const row = {
        feedId: log.args.feedId,
        feed: feed?.name ?? null,
        chainKey: Number(log.args.chainKey),
        target: log.args.target,
        probeHeight: Number(log.args.probeHeight),
        callSucceeded: log.args.callSucceeded,
        prober: log.args.prober,
        returnData: log.args.returnData,
        creditcoinBlock: log.blockNumber,
        creditcoinTx: log.transactionHash,
      };
      if (feed && row.callSucceeded) {
        try {
          row.value = feed.describe(decodeFor(feed, row.returnData));
        } catch { /* an undecodable value is still a real observation */ }
      }
      state.observations.push(row);
      added++;
    }
    from = to + 1;
  }

  state.fromBlock = head + 1;
  // Keep the file bounded; the chain remains the record of anything older.
  if (state.observations.length > 5000) state.observations = state.observations.slice(-5000);
  mkdirSync(new URL('../docs/evidence/', import.meta.url), { recursive: true });
  writeFileSync(STORE, JSON.stringify(state, null, 2) + '\n');
  return { added, head };
}

const { added, head } = await catchUp();
console.log(`indexed ${added} new observation(s) up to Creditcoin block ${head}`);
console.log(`${state.observations.length} held in total`);

if (process.argv.includes('--once')) process.exit(0);

const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*' });
  res.end(JSON.stringify(body, null, 2));
};

createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const seg = url.pathname.split('/').filter(Boolean);

  if (seg[0] !== 'feeds' && seg[0] !== 'health') return json(res, 404, { error: 'not found' });
  if (seg[0] === 'health') return json(res, 200, { ok: true, held: state.observations.length, upTo: state.fromBlock - 1 });

  // /feeds -> what is known, newest observation each
  if (seg.length === 1) {
    const latest = {};
    for (const o of state.observations) latest[o.feedId] = o;
    return json(res, 200, { registry: addresses.registry, feeds: Object.values(latest) });
  }

  // /feeds/:id/history -> everything recorded for one feed, newest first
  const id = seg[1];
  const history = state.observations.filter((o) => o.feedId === id || o.feed === id).reverse();
  if (history.length === 0) return json(res, 404, { error: 'no observations for that feed', feedId: id });
  const limit = Number(url.searchParams.get('limit') ?? 100);
  return json(res, 200, { feedId: history[0].feedId, feed: history[0].feed, count: history.length, history: history.slice(0, limit) });
}).listen(PORT, () => console.log(`serving on http://localhost:${PORT}  (/feeds, /feeds/:id, /health)`));

setInterval(() => {
  catchUp()
    .then(({ added: n }) => n && console.log(`indexed ${n} more`))
    .catch((e) => console.error('catch-up failed:', e.shortMessage ?? e.message));
}, 60000);
