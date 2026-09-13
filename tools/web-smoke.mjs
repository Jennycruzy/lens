/**
 * Runs the web app's own read logic outside the browser.
 *
 *   node tools/web-smoke.mjs
 *
 * The page has no server, so nothing about it can be tested by requesting a URL. What
 * can be tested is that the addresses, ABI fragments, feed identifiers and decoders it
 * ships actually resolve against the live chains — which is every way the page can be
 * wrong apart from its layout.
 */
import { readFileSync, existsSync } from 'node:fs';
import { JsonRpcProvider, Contract, AbiCoder, Interface, keccak256 } from 'ethers';

// Load the page's config by evaluating it the way the browser would.
const src = readFileSync(new URL('../web/config.js', import.meta.url), 'utf8');
const window = {};
new Function('window', src)(window);
const C = window.LENS;

const creditcoin = new JsonRpcProvider(C.creditcoinRpc, undefined, { staticNetwork: true });
const REGISTRY_ABI = [
  'function observationOf(bytes32) view returns ((bytes returnData,uint256 probeHeight,uint64 sourceTimestamp,uint64 recordedAt,bool callSucceeded,bool truncated,address prober))',
  'function hasObservation(bytes32) view returns (bool)',
  'function frontierOf(uint64) view returns (uint64)',
];
const CHAIN_INFO_ABI = [
  'function get_supported_chains() view returns ((uint64 chainKey,uint64 chainId,bytes chainName,uint8 chainEncoding)[])',
];
const registry = new Contract(C.registry, REGISTRY_ABI, creditcoin);
const chainInfo = new Contract('0x0000000000000000000000000000000000000fd3', CHAIN_INFO_ABI, creditcoin);
const coder = AbiCoder.defaultAbiCoder();

const freshnessInterface = new Interface([
  'error FeedUnavailable(bytes32)',
  'error FeedStale(bytes32,uint256,uint256)',
]);
const freshnessSelectors = Object.fromEntries(
  ['FeedUnavailable', 'FeedStale'].map((name) => [freshnessInterface.getError(name).selector.toLowerCase(), name]),
);
const marketInterface = new Interface(['error StalePrice(uint256,uint256)']);
freshnessSelectors[marketInterface.getError('StalePrice').selector.toLowerCase()] = 'StalePrice';
// ReserveMonitor refuses with its own error when either leg of the ratio is unavailable.
freshnessSelectors['0xbad04e0e'] = 'CannotDetermineSolvency';
function revertData(error) {
  for (const candidate of [error?.data, error?.revert?.data, error?.info?.error?.data, error?.error?.data]) {
    if (typeof candidate === 'string' && candidate.startsWith('0x')) return candidate;
  }
  return '';
}
function failClosedReason(error) {
  const data = revertData(error);
  return freshnessSelectors[data.slice(0, 10).toLowerCase()] ?? null;
}

const chains = await chainInfo.get_supported_chains();
const keyOf = Object.fromEntries(chains.map((c) => [Number(c.chainId), Number(c.chainKey)]));

let failures = 0;
const say = (ok, line) => {
  if (!ok) failures++;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${line}`);
};

// The page's static shape: every file it loads exists, every feed carries what the page
// reads, and the generated file is the generator's output.
console.log('\nThe page itself\n');
const html = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
for (const ref of ['./styles.css', './app.js', './config.js', './assets/lens-flow.svg']) {
  const present = existsSync(new URL(`../web/${ref.slice(2)}`, import.meta.url));
  say(html.includes(ref) && present, `${ref} is referenced by index.html and exists`);
}
say(C.feeds.every((f) => f.title && f.signature && f.note !== undefined && typeof f.decode === 'function'),
  'every feed carries a title, a signature, a note and a decoder');
say(C.feeds.filter((f) => f.featured).length === 4, 'four feeds are featured');
say(Object.values(C.sources).every((s) => /^0x[0-9a-fA-F]{40}$/.test(s.probe)), 'every source chain names its probe');
say(!C.feeds.find((f) => f.name.includes('uniswap')).decode('0x' + '00'.repeat(256)).includes('$'),
  'the Uniswap observe() feed is never rendered as a dollar price');

console.log('\nFeeds the page shows\n');
for (const feed of C.feeds) {
  const chainKey = keyOf[feed.chainId];
  if (chainKey === undefined) {
    say(false, `${feed.name}: chain ${feed.chainId} is not attested here`);
    continue;
  }
  const id = keccak256(
    coder.encode(['uint64', 'address', 'bytes32'], [chainKey, feed.target, keccak256(feed.calldata)]),
  );
  if (!(await registry.hasObservation(id))) {
    say(false, `${feed.name}: no observation for the identifier the page derives (${id.slice(0, 14)}…)`);
    continue;
  }
  const o = await registry.observationOf(id);
  const frontier = Number(await registry.frontierOf(chainKey));
  if (Number(o.probeHeight) > frontier) {
    say(false, feed.name + ': refused because frontier ' + frontier + ' regressed below observation ' + o.probeHeight);
    continue;
  }

  // The verify button's comparison, run here: the main endpoint, then the public archive
  // endpoints the page carries. A node that will not serve state at that height has said
  // nothing about agreement, so only when every endpoint declines is the row inconclusive.
  const src = C.sources[feed.chainId];
  let onSource;
  let refused = false;
  let lastMessage = '';
  for (const rpc of [src.rpc, ...(src.archiveRpcs ?? [])]) {
    try {
      onSource = await new JsonRpcProvider(rpc, undefined, { staticNetwork: true }).call({
        to: feed.target,
        data: feed.calldata,
        blockTag: Number(o.probeHeight),
      });
      break;
    } catch (e) {
      const msg = [e.shortMessage, e.message, e.info?.responseBody].filter(Boolean).join(' ');
      if (/archive|personal token|missing revert data|state.*not available|403/i.test(msg)) refused = true;
      lastMessage = (e.shortMessage ?? e.message ?? '').slice(0, 90);
    }
  }
  if (onSource === undefined) {
    console.log(`  ${refused ? 'note' : 'FAIL'}  ${feed.name} — ${refused ? 'every endpoint declined the historical block, so no comparison was possible' : lastMessage}`);
    if (!refused) failures++;
    continue;
  }

  let decoded = '(no decoder)';
  try {
    decoded = feed.decode(o.returnData);
  } catch (e) {
    say(false, `${feed.name}: decoder threw — ${e.message}`);
  }
  say(onSource === o.returnData, `${feed.name} — ${decoded}, byte-equal at block ${o.probeHeight}`);
}

console.log('\nConsumer cards\n');
const cards = [
  ['Reserve backing', C.reserveMonitor, 'function ratio() view returns (uint256,uint256)'],
  ['Lending market price', C.market, 'function price() view returns (uint256)'],
  ['Circuit breaker', C.breaker, 'function status() view returns (bool,uint8)'],
  ['Governance', C.votePort, 'function proposalCount() view returns (uint256)'],
  ['Snapshot claims', C.snapshotProver, 'function campaignCount() view returns (uint256)'],
  ['Feed escrow', C.escrow, 'function fundingOf(bytes32) view returns ((uint256,uint256,uint64,uint64,address,uint64))'],
];
for (const [label, address, fragment] of cards) {
  try {
    const c = new Contract(address, [fragment], creditcoin);
    const name = fragment.match(/function (\w+)/)[1];
    const result = name === 'fundingOf'
      ? await c[name]('0x2c73f71f50a0b9d99ad60eec631f085b9c725adcf52e7e02011d2d197411b610')
      : await c[name]();
    say(true, `${label} — ${Array.isArray(result) ? result.join(', ') : result}`);
  } catch (e) {
    const closed = failClosedReason(e);
    if (closed && ['Reserve backing', 'Lending market price'].includes(label)) {
      say(true, `${label} — failed closed with ${closed}; a fresh observation is required`);
    } else {
      say(false, `${label} — ${e.shortMessage ?? e.message}`);
    }
  }
}

// --- the feed builder's arithmetic ------------------------------------------
// The page derives a feed identifier in the browser. If that ever disagreed with the
// registry, a visitor would be told a live feed does not exist, or the reverse.
console.log('\nFeed builder\n');
{
  const target = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';
  const iface = new (await import('ethers')).Interface(['function totalSupply() view returns (uint256)']);
  const calldata = iface.encodeFunctionData('totalSupply', []);
  const chainKey = keyOf[11155111];
  const inBrowser = keccak256(
    coder.encode(['uint64', 'address', 'bytes32'], [chainKey, target, keccak256(calldata)]),
  );
  const onChain = await new Contract(
    C.registry,
    ['function feedId(uint64,address,bytes) pure returns (bytes32)'],
    creditcoin,
  ).feedId(chainKey, target, calldata);
  say(inBrowser === onChain, `identifier the builder derives matches the registry (${inBrowser.slice(0, 14)}…)`);

  // It must refuse a call the target does not answer. Note that the call succeeding is
  // not the test: a contract with a fallback — WETH's is `deposit` — returns empty for an
  // unknown selector instead of reverting. Only decoding catches it, which is what the
  // builder does and what this checks.
  {
    const bad = new (await import('ethers')).Interface(['function notAFunction() view returns (uint256)']);
    const provider = new JsonRpcProvider(C.sources[11155111].rpc, undefined, { staticNetwork: true });
    let offered = false;
    try {
      const raw = await provider.call({ to: target, data: bad.encodeFunctionData('notAFunction', []) });
      bad.decodeFunctionResult('notAFunction', raw);
      offered = true;
    } catch { /* rejected, which is correct */ }
    say(!offered, 'a call the target cannot answer is rejected before a feed is offered');
  }
}

// --- the latency panel -------------------------------------------------------
console.log('\nLatency panel\n');
for (const [chainId, src] of Object.entries(C.sources)) {
  const chainKey = keyOf[chainId];
  if (chainKey === undefined) { say(true, `${src.label}: not attested here, shown as such`); continue; }
  try {
    const frontier = Number(await registry.frontierOf(chainKey));
    const head = await new JsonRpcProvider(src.rpc, undefined, { staticNetwork: true }).getBlockNumber();
    const lag = head - frontier;
    say(lag >= 0 && lag < 5000, `${src.label}: ${lag} blocks behind (~${((lag * 12) / 60).toFixed(1)} min)`);
  } catch (e) {
    say(false, `${src.label}: ${e.shortMessage ?? e.message}`);
  }
}

console.log(`\n${failures ? `${failures} problem(s)` : 'every read the page makes resolves against the live chains'}\n`);
process.exit(failures ? 1 : 0);
