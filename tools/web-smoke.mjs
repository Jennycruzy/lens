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
import { JsonRpcProvider, Contract, AbiCoder, keccak256 } from 'ethers';

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

  // The verify button's comparison, run here.
  const provider = new JsonRpcProvider(C.sources[feed.chainId].rpc, undefined, { staticNetwork: true });
  const onSource = await provider.call({
    to: feed.target,
    data: feed.calldata,
    blockTag: Number(o.probeHeight),
  });

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
];
for (const [label, address, fragment] of cards) {
  try {
    const c = new Contract(address, [fragment], creditcoin);
    const name = fragment.match(/function (\w+)/)[1];
    const result = await c[name]();
    say(true, `${label} — ${Array.isArray(result) ? result.join(', ') : result}`);
  } catch (e) {
    say(false, `${label} — ${e.shortMessage ?? e.message}`);
  }
}

console.log(`\n${failures ? `${failures} problem(s)` : 'every read the page makes resolves against the live chains'}\n`);
process.exit(failures ? 1 : 0);
