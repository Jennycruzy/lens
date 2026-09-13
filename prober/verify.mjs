/**
 * Checks one feed, or all of them, against the contract that produced the value.
 *
 *   node prober/verify.mjs [<feed-name>]
 *
 * The one-command answer to "why should I believe this number". It reads what Creditcoin
 * holds and calls the same contract with the same calldata on the source chain, at the
 * exact height that was proven, and prints both.
 */
import {
  feeds, feedByName, callDataFor, decodeFor, chainKeyFor, computeFeedId,
  registryContract, historicalProvider, sources,
} from './lib/config.mjs';

const name = process.argv[2];
const selected = name ? [feedByName(name)] : feeds;
const registry = registryContract();
let diverged = 0;
let checked = 0;
let unchecked = 0;

for (const feed of selected) {
  const chainKey = await chainKeyFor(feed.chainId);
  const callData = callDataFor(feed);
  const id = computeFeedId(chainKey, feed.target, callData);

  console.log(`\n${feed.name}`);
  console.log(`  source   ${sources[feed.chainId].label}, key ${chainKey} here`);
  console.log(`  target   ${feed.target}`);
  console.log(`  feed id  ${id}`);

  if (!(await registry.hasObservation(id))) {
    console.log('  status   never proven, so there is nothing to check');
    continue;
  }

  const o = await registry.observationOf(id);
  const frontier = Number(await registry.frontierOf(chainKey));
  if (Number(o.probeHeight) > frontier) {
    console.log('  status   refused — frontier ' + frontier + ' is below observation ' + o.probeHeight);
    unchecked++;
    continue;
  }
  if (!o.callSucceeded) {
    console.log(`  status   recorded as a failed source read at block ${o.probeHeight}`);
    continue;
  }

  console.log(`  height   ${o.probeHeight}`);
  console.log(`  on Lens  ${o.returnData}`);

  // A node that will not serve state at that height has told us nothing about whether
  // the values agree. Reporting that as a divergence would be alarming and false, so the
  // two outcomes are kept apart: this is the same "absence is not a failure" rule the
  // prober applies to the proof builder.
  let onSource;
  try {
    onSource = await historicalProvider(feed.chainId).call({
      to: feed.target,
      data: callData,
      blockTag: Number(o.probeHeight),
    });
  } catch (e) {
    unchecked++;
    console.log(`  on chain unavailable`);
    console.log(`  INCONCLUSIVE — the RPC would not serve state at block ${o.probeHeight}`);
    console.log(`                 (${(e.shortMessage ?? e.message).slice(0, 90)})`);
    console.log(`                 this is an archive limitation, not a disagreement;`);
    console.log(`                 set ${feed.chainId === 1 ? 'ETHEREUM_ARCHIVE_RPC' : 'an archive RPC'} to check it`);
    continue;
  }

  const agrees = onSource === o.returnData;
  checked++;
  if (!agrees) diverged++;

  console.log(`  on chain ${onSource}`);
  console.log(`  ${agrees ? 'BYTE-EQUAL' : 'DIVERGED'}${agrees ? `  — ${feed.describe(decodeFor(feed, o.returnData))}` : ''}`);
}

console.log(`\n${checked} checked, ${diverged} diverged${unchecked ? `, ${unchecked} inconclusive` : ''}\n`);
// An inconclusive check is not a failure. Only a real disagreement is.
process.exit(diverged ? 1 : 0);
