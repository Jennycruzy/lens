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
  env, feedByName, callDataFor, decodeFor, chainKeyFor, computeFeedId,
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
let readHeight = head;
let finalizedHeight = null;
try {
  const finalized = await provider.getBlock('finalized');
  if (finalized?.number !== undefined) finalizedHeight = finalized.number;
} catch {
  /* use the configured depth fallback below */
}
if (finalizedHeight !== null) {
  readHeight = finalizedHeight;
  console.log(`source finality: finalized block ${readHeight} (head ${head})`);
} else {
  const depth = Number(env[`SOURCE_FINALITY_BLOCKS_${chainId}`] ?? (chainId === 1 ? 64 : 12));
  readHeight = Math.max(0, head - depth);
  console.log(`source finality: no finalized tag; pinned ${depth} blocks behind head at ${readHeight}`);
}
const targets = [];
const datas = [];
const expected = [];

for (const feed of selected) {
  const data = callDataFor(feed);
  const raw = await provider.call({ to: feed.target, data, blockTag: readHeight });
  const value = decodeFor(feed, raw);
  targets.push(feed.target);
  datas.push(data);
  expected.push({ feed, data, raw, value, callHash: keccak256(data) });
  console.log(`  ${feed.name}`);
  console.log(`    direct read at block ${readHeight}: ${feed.describe(value)}`);
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

/**
 * Refuse to spend above a configured gas price, and queue instead.
 *
 * Every feed class here tolerates hours of lag by design, so waiting for a cheaper block
 * costs almost nothing while probing through a spike costs real money. Exiting 75 rather
 * than 1 lets a caller tell "too expensive right now, try later" from "this is broken",
 * and the keeper treats it as a skip rather than a failure.
 */
const ceilingGwei = Number(env[`MAX_GAS_GWEI_${chainId}`] ?? env.MAX_GAS_GWEI ?? (chainId === 1 ? 20 : 1000));
const feeNow = await provider.getFeeData();
const gweiNow = Number(feeNow.gasPrice ?? 0n) / 1e9;
if (gweiNow > ceilingGwei) {
  console.error(`\n  gas is ${gweiNow.toFixed(3)} gwei, above the ${ceilingGwei} gwei ceiling for chain ${chainId}`);
  console.error('  nothing was sent. These feeds tolerate the wait; a spike is not worth paying through.');
  console.error(`  raise MAX_GAS_GWEI_${chainId} in .env to override.`);
  process.exit(75);
}

/**
 * Probe a block the source chain is unlikely to reorg away.
 *
 * A probe in a block that is later reorged out is a read of a chain that no longer
 * exists: the proof would fail, or worse, describe a state nobody agrees with. Waiting
 * for finality costs a minute against feeds measured in hours.
 */
console.log(`  direct reads were pinned before probing at source block ${readHeight}`);

// The probe catches target reverts, so its own estimate can be lower than the gas
// required for a target that actually succeeds: the EVM sees a successful wrapper
// even when the inner call ran out of the wrapper's forwarded gas. Measure the target
// calls directly from the probe address, then add a measured wrapper baseline from
// no-code calls. This is deliberately not a fixed multiplier or a guessed constant.
const maxProbeGas = await probe.MAX_PROBE_GAS();
const noCode = '0x0000000000000000000000000000000000000001';
const baselineTargets = targets.map(() => noCode);
const baselineDatas = datas.map(() => '0x');
const wrapperBaseline = await probe[call.fn].estimateGas(...(
  single ? [noCode, '0x'] : [baselineTargets, baselineDatas]
));
const targetGas = [];
for (const item of expected) {
  try {
    const measured = await provider.estimateGas({ from: probe.target, to: item.feed.target, data: item.data });
    targetGas.push(measured > maxProbeGas ? maxProbeGas : measured);
  } catch (e) {
    targetGas.push(maxProbeGas);
    console.log(`    target gas estimate unavailable for ${item.feed.name}; reserving the ${maxProbeGas} gas cap (${e.shortMessage ?? e.message})`);
  }
}
const forwardedGas = targetGas.reduce((sum, measured) => sum + ((measured * 64n + 62n) / 63n), 0n);
const measuredModel = wrapperBaseline + forwardedGas;
const observedEstimate = await probe[call.fn].estimateGas(...call.args);
const gas = observedEstimate > measuredModel ? observedEstimate : measuredModel;
console.log(`  measured gas model: wrapper baseline ${wrapperBaseline}, target gas [${targetGas.join(', ')}], transaction limit ${gas}`);
const fee = await provider.getFeeData();
console.log(`\n  ${call.fn}: ${gas} gas at ${Number(fee.gasPrice ?? 0n) / 1e9} gwei`);

const tx = await probe[call.fn](...call.args, { gasLimit: gas });
console.log(`  sent ${tx.hash}`);
const receipt = await tx.wait();

if (receipt.status !== 1) {
  console.error('  the probe transaction reverted on chain');
  process.exit(1);
}

console.log(`  mined in block ${receipt.blockNumber}, ${receipt.gasUsed} gas used`);

// Confirm the block is still the one the chain agrees on. A reorg between mining and
// proving would leave a proof for a transaction that is no longer in the canonical chain.
const minedBlock = await provider.getBlock(receipt.blockNumber);
if (minedBlock?.hash !== receipt.blockHash) {
  console.error(`\n  the block this was mined in has been reorged away`);
  console.error(`  mined in ${receipt.blockHash}, chain now has ${minedBlock?.hash}`);
  console.error('  do not prove this transaction; probe again.');
  process.exit(1);
}
console.log(`  block hash still canonical\n`);

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
