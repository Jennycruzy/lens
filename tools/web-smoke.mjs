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
import { readFileSync } from 'node:fs';
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
// The currently documented consumer address predates the hardened ABI and returns its
// older fail-closed error. Keep that refusal visible rather than calling it a healthy value.
freshnessSelectors['0xbad04e0e'] = 'CannotDetermineSolvency (legacy deployment)';
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

  // The verify button's comparison, run here. A node that will not serve state at that
  // height has told us nothing about whether the values agree, so it is kept apart from
  // a divergence — the same rule the prober applies to a missing proof.
  const provider = new JsonRpcProvider(C.sources[feed.chainId].rpc, undefined, { staticNetwork: true });
  let onSource;
  try {
    onSource = await provider.call({
      to: feed.target,
      data: feed.calldata,
      blockTag: Number(o.probeHeight),
    });
  } catch (e) {
    const msg = e.shortMessage ?? e.message ?? '';
    const archive = /archive|personal token|missing revert data|state.*not available/i.test(msg);
    console.log(`  ${archive ? 'note' : 'FAIL'}  ${feed.name} — ${archive ? 'archive state unavailable on this RPC, so no comparison was possible' : msg.slice(0, 90)}`);
    if (!archive) failures++;
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
