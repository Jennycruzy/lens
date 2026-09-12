/**
 * Proves several source transactions to Creditcoin under one shared continuity proof.
 *
 *   node prober/prove-batch.mjs <chain-id> <tx-hash> <tx-hash> ...
 *
 * This is the path `submitProof` cannot take. Each transaction carries its own Merkle
 * proof, but the continuity chain that anchors them is built once and paid for once, so
 * the cost of a query falls as the batch grows. The precompile accepts ten.
 *
 * The transactions must be in ascending block order and inside the range one continuity
 * chain can span, which is why the builder is asked for a batch rather than for each
 * proof separately.
 */
import { Contract } from 'ethers';
import {
  env, chainKeyFor, sourceProvider, creditcoin, creditcoinWallet, registryContract,
  computeFeedId, callDataFor, decodeFor, feeds, sources, CHAIN_INFO, probeContract,
  builderAttestedHeight, proofBuilderHosts, localProofBuilder,
} from './lib/config.mjs';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };

const [chainIdArg, ...hashes] = process.argv.slice(2);
if (!chainIdArg || hashes.length < 1) {
  console.error('usage: node prober/prove-batch.mjs <chain-id> <tx-hash> [<tx-hash> ...]');
  process.exit(2);
}
const chainId = Number(chainIdArg);
if (!Number.isSafeInteger(chainId) || !sources[chainId]) throw new Error('unsupported source chain id: ' + chainId);
const uniqueHashes = [...new Map(hashes.map((hash) => [hash.toLowerCase(), hash])).values()];
if (uniqueHashes.length > 10) throw new Error('batch accepts at most 10 unique transactions');
const chainKey = await chainKeyFor(chainId);
const provider = sourceProvider(chainId);
const chainInfo = new Contract(CHAIN_INFO, chainInfoAbi, creditcoin);

const receipts = [];
const receiptByHash = new Map();
for (const h of uniqueHashes) {
  const r = await provider.getTransactionReceipt(h);
  if (!r) throw new Error(`no such transaction on ${sources[chainId].label}: ${h}`);
  if (r.status !== 1) throw new Error(`${h} reverted; there is nothing worth proving`);
  receipts.push(r);
  receiptByHash.set(h.toLowerCase(), r);
}
receipts.sort((a, b) => a.blockNumber - b.blockNumber);
const probe = probeContract(chainId);
const eventsFrom = (receipt) => receipt.logs.map((log) => {
  try { const parsed = probe.interface.parseLog(log); return parsed?.name === 'Probed' ? parsed : null; } catch { return null; }
}).filter(Boolean);
const expectedEvents = receipts.flatMap((receipt) => eventsFrom(receipt).map((event) => ({ receiptHash: receipt.hash.toLowerCase(), height: receipt.blockNumber, target: event.args.target, callHash: event.args.callHash, success: event.args.success, truncated: event.args.truncated, returnData: event.args.returnData })));
if (expectedEvents.length === 0) throw new Error('source transactions contain no Probed events');
const highest = receipts[receipts.length - 1].blockNumber;

console.log(`\n${sources[chainId].label}, key ${chainKey} here`);
console.log(`  ${receipts.length} transactions, blocks ${receipts.map((r) => r.blockNumber).join(', ')}`);

// Every transaction in the batch must be attested, so wait on the highest.
const deadline = Date.now() + 20 * 60 * 1000;
for (;;) {
  const latest = await chainInfo.get_latest_attestation_height_and_hash(chainKey);
  const onChain = latest.exists ? Number(latest.height) : 0;
  const builderState = await builderAttestedHeight(chainKey);
  const builder = builderState.height;
  if (onChain >= highest && builder >= highest) {
    console.log(`  attested: precompile ${onChain}, builder ${builder}`);
    break;
  }
  const unavailable = builderState.attempts
    .filter((attempt) => attempt.status === 'unreachable' || attempt.kind)
    .map((attempt) => `${attempt.host}=${attempt.status === 'unreachable' ? 'unreachable' : attempt.kind}`);
  if (unavailable.length) console.log(`  builders: ${unavailable.join(', ')}`);
  if (Date.now() > deadline) throw new Error('timed out waiting for attestation');
  console.log(`  waiting: precompile ${onChain}, builder ${builder}, need ${highest}`);
  await new Promise((r) => setTimeout(r, 30000));
}

// The builder produces one continuity proof spanning the whole batch, plus a Merkle
// proof per transaction. Asking for each proof separately would give continuity chains
// that do not share an anchor, which is the thing being amortised.
// Path and body shape taken from the SDK's own client, not guessed: the hashes go as a
// bare array rather than wrapped in an object.
const failures = [];
let batch;
for (const host of proofBuilderHosts()) {
  try {
    const response = await fetch(`${host}/api/v1/proof-batch-by-tx/${chainKey}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(uniqueHashes),
      signal: AbortSignal.timeout(90000),
    });
    if (response.ok) {
      batch = await response.json();
      console.log(`  batch proof from ${host}`);
      break;
    }
    const detail = (await response.text()).slice(0, 200);
    const kind = response.status === 404 ? 'not-found' : response.status === 422 ? 'unprocessable' : 'http';
    failures.push(`${host} -> ${kind} (HTTP ${response.status}) ${detail}`);
  } catch (e) {
    failures.push(`${host} -> unreachable: ${e.message}`);
  }
}
if (!batch) {
  try {
    const local = await localProofBuilder(chainId, chainKey).getBatchProof(uniqueHashes);
    if (local.success) {
      batch = { data: local.data };
      console.log('  batch proof from local SDK raw builder');
    } else {
      failures.push('local-sdk -> ' + (local.error ?? 'unknown error'));
    }
  } catch (e) {
    failures.push('local-sdk -> unreachable: ' + e.message);
  }
}
if (!batch) {
  console.error('\n  no builder produced a batch proof:');
  console.error('    ' + failures.join('\n    '));
  process.exit(1);
}

const body = batch.data ?? batch;
if (!body?.continuityProof || !Array.isArray(body.continuityProof.roots) || !body.merkleProofs) throw new Error('builder response missing continuityProof or merkleProofs');
console.log(`  fromHeader ${body.fromHeader}, toHeader ${body.toHeader}, continuity roots ${body.continuityProof?.roots?.length}`);

// Flatten the builder's per-height, per-index map into the arrays the precompile takes,
// keeping heights and proofs in the same order.
const heights = [];
const txBytes = [];
const merkleProofs = [];
const requestedSet = new Set(uniqueHashes.map((hash) => hash.toLowerCase()));
const seen = new Set();
const heightEntries = body.merkleProofs instanceof Map ? [...body.merkleProofs.entries()] : Object.entries(body.merkleProofs ?? {});
for (const [height, byIndex] of heightEntries.sort((a, b) => Number(a[0]) - Number(b[0]))) {
  const heightNumber = Number(height);
  if (!Number.isSafeInteger(heightNumber)) throw new Error('builder returned an invalid block height: ' + height);
  if (!byIndex || typeof byIndex !== 'object') throw new Error('builder returned an invalid proof map at height ' + height);
  const indexEntries = byIndex instanceof Map ? [...byIndex.entries()] : Object.entries(byIndex);
  for (const [, entry] of indexEntries.sort((a, b) => Number(a[0]) - Number(b[0]))) {
    const txHash = typeof entry?.txHash === 'string' ? entry.txHash.toLowerCase() : '';
    if (!requestedSet.has(txHash)) throw new Error('builder returned an unrequested transaction: ' + (entry?.txHash ?? '<missing>'));
    if (seen.has(txHash)) throw new Error('builder returned a duplicate transaction: ' + txHash);
    const receipt = receiptByHash.get(txHash);
    if (!receipt || receipt.blockNumber !== heightNumber) throw new Error('builder height does not match receipt for ' + txHash);
    if (!entry.txBytes || !entry.merkleProof?.root || !Array.isArray(entry.merkleProof.siblings)) throw new Error('builder returned an incomplete Merkle proof for ' + txHash);
    heights.push(heightNumber);
    txBytes.push(entry.txBytes);
    merkleProofs.push({
      root: entry.merkleProof.root,
      siblings: entry.merkleProof.siblings.map((s) => ({ hash: s.hash, isLeft: s.isLeft })),
    });
    seen.add(txHash);
  }
}
console.log(`  ${heights.length} queries under one continuity proof`);
if (seen.size !== requestedSet.size) {
  throw new Error('builder returned ' + seen.size + ' of ' + requestedSet.size + ' requested transactions');
}
if (heights.length === 0 || heights.length > 10) {
  throw new Error(`builder returned ${heights.length} queries; registry cap is 10`);
}

const registry = registryContract(creditcoinWallet());
const args = [
  chainKey,
  heights,
  txBytes,
  merkleProofs,
  { lowerEndpointDigest: body.continuityProof.lowerEndpointDigest, roots: body.continuityProof.roots },
];

try {
  const would = await registry.submitBatch.staticCall(...args);
  console.log(`  the batch would record ${would} observation(s)`);
} catch (e) {
  const data = e.data ?? e.info?.error?.data;
  let parsedName = '';
  if (data && data !== '0x') {
    try { parsedName = registry.interface.parseError(data)?.name ?? ''; } catch { /* raw below */ }
  }
  if (/QueryAlreadyConsumed|ObservationNotNewer/.test(parsedName)) {
    console.log(`  batch already recorded by another prober (${parsedName}); treating as idempotent success`);
    process.exit(0);
  }
  console.error('\n  the registry rejected the batch');
  console.error('  ' + (parsedName || data || e.shortMessage || e.message));
  process.exit(1);
}

let estimatedGas;
try {
  estimatedGas = await registry.submitBatch.estimateGas(...args);
} catch (e) {
  console.error(`\n  gas estimation refused; nothing was sent: ${e.shortMessage ?? e.message}`);
  process.exit(1);
}
console.log(`  measured submission gas ${estimatedGas}`);

const tx = await registry.submitBatch(...args, { gasLimit: estimatedGas });
console.log(`  sent ${tx.hash}`);
const submitted = await tx.wait();
if (submitted?.status !== 1) {
  console.error('  the Creditcoin batch submission reverted on chain');
  process.exit(1);
}
console.log(`  recorded in Creditcoin block ${submitted.blockNumber}, ${submitted.gasUsed} gas`);
console.log(`  ${submitted.gasUsed / BigInt(heights.length)} gas per query\n`);
const recordedEvents = submitted.logs.map((log) => {
  try { const parsed = registry.interface.parseLog(log); return parsed?.name === 'ObservationRecorded' ? parsed : null; } catch { return null; }
}).filter(Boolean);
let mismatch = recordedEvents.length !== expectedEvents.length;
if (mismatch) console.error('  registry recorded ' + recordedEvents.length + ' observation(s), expected ' + expectedEvents.length);
const matched = new Set();
for (const event of recordedEvents) {
  const feedId = event.args.feedId;
  const probeHeight = Number(event.args.probeHeight);
  const index = expectedEvents.findIndex((expected, i) => !matched.has(i) && expected.height === probeHeight && expected.target.toLowerCase() === event.args.target.toLowerCase() && computeFeedId(chainKey, expected.target, expected.callHash) === feedId);
  if (index < 0) { console.error('    registry event does not match a requested source event'); mismatch = true; continue; }
  matched.add(index);
  const expected = expectedEvents[index];
  if (event.args.callSucceeded !== expected.success || event.args.returnData.toLowerCase() !== expected.returnData.toLowerCase()) { console.error('    registry event bytes/status differ from source Probed event'); mismatch = true; continue; }
  const feed = feeds.find((candidate) => candidate.chainId === chainId && computeFeedId(chainKey, candidate.target, callDataFor(candidate)) === feedId);
  if (!feed) { console.error('    no local feed matches ' + feedId); mismatch = true; continue; }
  if (!expected.success || expected.truncated) { console.log('    source call failed or returndata was truncated; no value comparison attempted'); continue; }
  try {
    const direct = await provider.call({ to: expected.target, data: callDataFor(feed), blockTag: probeHeight });
    if (direct.toLowerCase() !== expected.returnData.toLowerCase()) { console.error('    MISMATCH between source Probed bytes and direct source read'); mismatch = true; } else console.log('    ' + feed.name + ' byte-equal at source block ' + probeHeight);
  } catch (e) { console.error('    source state could not be read at the proven height: ' + (e.shortMessage ?? e.message)); mismatch = true; }
}
if (matched.size !== expectedEvents.length) {
  console.error('  matched ' + matched.size + ' source event(s), expected ' + expectedEvents.length);
  mismatch = true;
}
