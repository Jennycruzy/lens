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
  computeFeedId, callDataFor, decodeFor, feeds, sources, CHAIN_INFO,
} from './lib/config.mjs';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };

const [chainIdArg, ...hashes] = process.argv.slice(2);
if (!chainIdArg || hashes.length < 2) {
  console.error('usage: node prober/prove-batch.mjs <chain-id> <tx-hash> <tx-hash> [...]');
  process.exit(2);
}
const chainId = Number(chainIdArg);
const chainKey = await chainKeyFor(chainId);
const provider = sourceProvider(chainId);
const chainInfo = new Contract(CHAIN_INFO, chainInfoAbi, creditcoin);

const receipts = [];
for (const h of hashes) {
  const r = await provider.getTransactionReceipt(h);
  if (!r) throw new Error(`no such transaction on ${sources[chainId].label}: ${h}`);
  if (r.status !== 1) throw new Error(`${h} reverted; there is nothing worth proving`);
  receipts.push(r);
}
receipts.sort((a, b) => a.blockNumber - b.blockNumber);
const highest = receipts[receipts.length - 1].blockNumber;

console.log(`\n${sources[chainId].label}, key ${chainKey} here`);
console.log(`  ${receipts.length} transactions, blocks ${receipts.map((r) => r.blockNumber).join(', ')}`);

// Every transaction in the batch must be attested, so wait on the highest.
for (;;) {
  const latest = await chainInfo.get_latest_attestation_height_and_hash(chainKey);
  const onChain = latest.exists ? Number(latest.height) : 0;
  let builder = 0;
  try {
    const res = await fetch(`${env.PROOF_BUILDER_URL}/api/v1/attested-height/${chainKey}`, {
      signal: AbortSignal.timeout(12000),
    });
    if (res.ok) builder = Number((await res.json()).attestedHeight ?? 0);
  } catch { /* treated as not yet */ }
  if (onChain >= highest && builder >= highest) {
    console.log(`  attested: precompile ${onChain}, builder ${builder}`);
    break;
  }
  console.log(`  waiting: precompile ${onChain}, builder ${builder}, need ${highest}`);
  await new Promise((r) => setTimeout(r, 30000));
}

// The builder produces one continuity proof spanning the whole batch, plus a Merkle
// proof per transaction. Asking for each proof separately would give continuity chains
// that do not share an anchor, which is the thing being amortised.
// Path and body shape taken from the SDK's own client, not guessed: the hashes go as a
// bare array rather than wrapped in an object.
const url = `${env.PROOF_BUILDER_URL}/api/v1/proof-batch-by-tx/${chainKey}`;
let batch;
const res = await fetch(url, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(hashes),
  signal: AbortSignal.timeout(90000),
});
if (res.ok) {
  batch = await res.json();
  console.log(`  batch proof from ${env.PROOF_BUILDER_URL}`);
} else {
  console.error(`\n  the builder would not produce a batch proof: HTTP ${res.status}`);
  console.error(`  ${(await res.text()).slice(0, 200)}`);
  process.exit(1);
}

const body = batch.data ?? batch;
console.log(`  fromHeader ${body.fromHeader}, toHeader ${body.toHeader}, continuity roots ${body.continuityProof?.roots?.length}`);

// Flatten the builder's per-height, per-index map into the arrays the precompile takes,
// keeping heights and proofs in the same order.
const heights = [];
const txBytes = [];
const merkleProofs = [];
for (const [height, byIndex] of Object.entries(body.merkleProofs ?? {})) {
  for (const entry of Object.values(byIndex)) {
    heights.push(Number(height));
    txBytes.push(entry.txBytes);
    merkleProofs.push({
      root: entry.merkleProof.root,
      siblings: entry.merkleProof.siblings.map((s) => ({ hash: s.hash, isLeft: s.isLeft })),
    });
  }
}
console.log(`  ${heights.length} queries under one continuity proof`);

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
  console.error('\n  the registry rejected the batch');
  const data = e.data ?? e.info?.error?.data;
  if (data && data !== '0x') {
    try { console.error('  ' + registry.interface.parseError(data)?.name); } catch { console.error('  ' + data); }
  } else {
    console.error('  ' + (e.shortMessage ?? e.message));
  }
  process.exit(1);
}

const tx = await registry.submitBatch(...args, { gasLimit: 8_000_000 });
console.log(`  sent ${tx.hash}`);
const submitted = await tx.wait();
console.log(`  recorded in Creditcoin block ${submitted.blockNumber}, ${submitted.gasUsed} gas`);
console.log(`  ${submitted.gasUsed / BigInt(heights.length)} gas per query\n`);
