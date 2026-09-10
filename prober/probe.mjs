/**
 * Sends a probe transaction on a source chain.
 *
 *   node prober/probe.mjs <feed-name> [<feed-name> ...]
 *
 * Feeds on the same chain are batched into one `probeMany`, so they land in one block
 * and one continuity proof covers all of them on the Creditcoin side.
 *
 * Before sending anything it performs the read locally and compares it to what the
 * probe will emit. That is not a formality: it is the value the rest of the pipeline
 * will be checked against, so it has to be captured at the same height, before the
 * transaction, from a source that is not Lens.
 */
import { keccak256 } from 'ethers';
import {
  feedByName, callDataFor, decodeFor, chainKeyFor, computeFeedId,
  sourceProvider, proberWallet, probeContract, sources,
} from './lib/config.mjs';

const names = process.argv.slice(2);
if (names.length === 0) {
  console.error('usage: node prober/probe.mjs <feed-name> [<feed-name> ...]');
  process.exit(2);
}

const selected = names.map(feedByName);
const chainIds = [...new Set(selected.map((f) => f.chainId))];
if (chainIds.length > 1) {
  console.error('all feeds in one probe must share a source chain; got ' + chainIds.join(', '));
  process.exit(2);
}

const chainId = chainIds[0];
const provider = sourceProvider(chainId);
const wallet = proberWallet(chainId);
const chainKey = await chainKeyFor(chainId);

console.log(`\n${sources[chainId].label}  (chain id ${chainId}, key ${chainKey} here)`);
console.log(`prober ${wallet.address}\n`);

// Read each target directly, at a pinned height, before probing. This is the
// independent answer every later step is measured against.
const head = await provider.getBlockNumber();
const targets = [];
const datas = [];
const expected = [];

for (const feed of selected) {
  const data = callDataFor(feed);
  const raw = await provider.call({ to: feed.target, data, blockTag: head });
  const value = decodeFor(feed, raw);
  targets.push(feed.target);
  datas.push(data);
  expected.push({ feed, data, raw, value, callHash: keccak256(data) });
  console.log(`  ${feed.name}`);
  console.log(`    direct read at block ${head}: ${feed.describe(value)}`);
  console.log(`    feed id ${computeFeedId(chainKey, feed.target, data)}`);
}

const probe = probeContract(chainId, wallet);
const single = selected.length === 1;
const call = single
  ? { fn: 'probe', args: [targets[0], datas[0]] }
  : { fn: 'probeMany', args: [targets, datas] };

// eth_call first, always. An estimate that fails gives back a bare revert with no
// reason on more than one of the chains in this project; a call gives the cause.
try {
  await probe[call.fn].staticCall(...call.args);
} catch (e) {
  console.error(`\nthe probe would revert, so nothing was sent: ${e.shortMessage ?? e.message}`);
  process.exit(1);
}

const gas = await probe[call.fn].estimateGas(...call.args);
const fee = await provider.getFeeData();
console.log(`\n  ${call.fn}: ${gas} gas at ${Number(fee.gasPrice ?? 0n) / 1e9} gwei`);

const tx = await probe[call.fn](...call.args, { gasLimit: (gas * 130n) / 100n });
console.log(`  sent ${tx.hash}`);
const receipt = await tx.wait();

if (receipt.status !== 1) {
  console.error('  the probe transaction reverted on chain');
  process.exit(1);
}

console.log(`  mined in block ${receipt.blockNumber}, ${receipt.gasUsed} gas used\n`);

// Confirm the chain emitted exactly what a direct read returns.
//
// The comparison must be made at the height the probe actually executed at, not at the
// height sampled before sending. Several feed classes are relative to the current block
// — `observe(secondsAgo)` on a Uniswap pool most obviously — so a read taken two blocks
// earlier legitimately differs, and comparing against it reports a divergence that is
// not one.
const iface = probe.interface;
const logs = receipt.logs
  .filter((l) => l.address.toLowerCase() === probe.target.toLowerCase())
  .map((l) => iface.parseLog(l))
  .filter((l) => l?.name === 'Probed');

console.log(`  ${logs.length} log(s) emitted`);
let mismatch = false;
for (const log of logs) {
  const match = expected.find(
    (e) => e.feed.target.toLowerCase() === log.args.target.toLowerCase() && e.callHash === log.args.callHash,
  );
  if (!match) {
    console.log(`    ${log.args.target}: no local feed matches this log`);
    mismatch = true;
    continue;
  }

  // Re-read at the block the probe ran in, which is the only honest comparison.
  const atProbeHeight = await provider.call({
    to: match.feed.target,
    data: match.data,
    blockTag: Number(log.args.blockNumber),
  });
  const agrees = log.args.returnData === atProbeHeight;
  if (!agrees) mismatch = true;

  console.log(`    ${match.feed.name}`);
  console.log(`      success ${log.args.success}, truncated ${log.args.truncated}, height ${log.args.blockNumber}`);
  console.log(`      emitted bytes ${agrees ? 'match a direct read at that block' : 'DO NOT MATCH a direct read at that block'}`);
  if (agrees && atProbeHeight !== match.raw) {
    console.log(`      note: the value moved between block ${head} and ${log.args.blockNumber}, which is ordinary`);
  }
}

console.log(`\nnext: node prober/prove.mjs ${receipt.hash} ${chainId}\n`);
process.exit(mismatch ? 1 : 0);
