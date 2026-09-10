/**
 * Proves a probe transaction to Creditcoin and records the observation.
 *
 *   node prober/prove.mjs <source-tx-hash> <source-chain-id>
 *
 * Waits for the block to be attested, builds the proof, submits it to the registry,
 * then reads the value back off Creditcoin and compares it to a direct read of the
 * source contract at the same height. The comparison is the point: a value that does
 * not match its source is worse than no value.
 */
import { Contract } from 'ethers';
import {
  env, chainKeyFor, sourceProvider, creditcoin, creditcoinWallet, registryContract,
  computeFeedId, callDataFor, decodeFor, feeds, sources, CHAIN_INFO,
} from './lib/config.mjs';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };

const [txHash, chainIdArg] = process.argv.slice(2);
if (!txHash || !chainIdArg) {
  console.error('usage: node prober/prove.mjs <source-tx-hash> <source-chain-id>');
  process.exit(2);
}
const chainId = Number(chainIdArg);
const chainKey = await chainKeyFor(chainId);
const provider = sourceProvider(chainId);
const chainInfo = new Contract(CHAIN_INFO, chainInfoAbi, creditcoin);

const receipt = await provider.getTransactionReceipt(txHash);
if (!receipt) throw new Error(`no such transaction on ${sources[chainId].label}: ${txHash}`);
if (receipt.status !== 1) throw new Error('that probe transaction reverted; there is nothing worth proving');

const height = receipt.blockNumber;
console.log(`\n${sources[chainId].label}  block ${height}, key ${chainKey} here`);

/**
 * Two different answers to "is it attested yet", and both have to be yes.
 *
 * The precompile is the authority the registry checks against. The proof builder keeps
 * its own cache and trails it, so a proof requested on the strength of the precompile
 * alone comes back missing. Waiting on the slower of the two is the only way to avoid
 * mistaking "not indexed yet" for "no such transaction".
 */
async function waitUntilProvable() {
  const deadline = Date.now() + 20 * 60 * 1000;
  for (;;) {
    const latest = await chainInfo.get_latest_attestation_height_and_hash(chainKey);
    const onChain = latest.exists ? Number(latest.height) : 0;

    let builder = 0;
    try {
      const res = await fetch(`${env.PROOF_BUILDER_URL}/api/v1/attested-height/${chainKey}`, {
        signal: AbortSignal.timeout(12000),
      });
      if (res.ok) builder = Number((await res.json()).attestedHeight ?? 0);
    } catch {
      /* treated as "not yet", never as "absent" */
    }

    if (onChain >= height && builder >= height) {
      console.log(`  attested: precompile at ${onChain}, builder at ${builder}`);
      return;
    }
    if (Date.now() > deadline) throw new Error('timed out waiting for attestation');
    console.log(`  waiting: precompile ${onChain}, builder ${builder}, need ${height} (${height - Math.min(onChain, builder)} blocks to go)`);
    await new Promise((r) => setTimeout(r, 30000));
  }
}

await waitUntilProvable();

/**
 * Ask each builder in turn, and keep the reasons apart.
 *
 * A 404, an unreachable host and a malformed request arrive looking similar and mean
 * completely different things. Collapsing them is how a transient outage gets recorded
 * as "that transaction does not exist" and an update is silently dropped.
 */
async function getProof() {
  const hosts = [env.PROOF_BUILDER_URL, env.PROOF_BUILDER_FALLBACK_URL].filter(Boolean);
  const failures = [];
  for (const host of hosts) {
    const url = `${host}/api/v1/proof-by-tx/${chainKey}/${txHash}`;
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(60000) });
      if (res.ok) {
        console.log(`  proof from ${host}`);
        return await res.json();
      }
      failures.push(`${host} -> HTTP ${res.status} ${(await res.text()).slice(0, 120)}`);
    } catch (e) {
      failures.push(`${host} -> unreachable: ${e.message}`);
    }
  }
  throw new Error('no builder produced a proof:\n    ' + failures.join('\n    '));
}

const proof = await getProof();
const body = proof.data ?? proof;
const { txBytes, merkleProof, continuityProof } = body;
if (!txBytes || !merkleProof || !continuityProof) {
  throw new Error('builder response missing proof fields: ' + JSON.stringify(Object.keys(body)));
}

console.log(`  transaction bytes ${(txBytes.length - 2) / 2}, merkle siblings ${merkleProof.siblings.length}, continuity roots ${continuityProof.roots.length}`);

const registry = registryContract(creditcoinWallet());
const args = [
  chainKey,
  body.headerNumber ?? height,
  txBytes,
  { root: merkleProof.root, siblings: merkleProof.siblings.map((s) => ({ hash: s.hash, isLeft: s.isLeft })) },
  { lowerEndpointDigest: continuityProof.lowerEndpointDigest, roots: continuityProof.roots },
];

// Call before estimating. Creditcoin returns a bare revert with no data from
// eth_estimateGas, so an estimate that fails says nothing about why.
try {
  const would = await registry.submitProof.staticCall(...args);
  console.log(`  submission would record ${would} observation(s)`);
} catch (e) {
  console.error('\n  the registry rejected this proof');
  console.error('  ' + describeRevert(e));
  process.exit(1);
}

/**
 * Turns a revert into something an operator can act on.
 *
 * ethers reports a custom error it cannot match as "unknown custom error", and the
 * parsed result prints as [object Object] if handed straight to console. Neither tells
 * anyone which of the registry's checks refused, which is the only thing worth knowing.
 */
function describeRevert(e) {
  const data = e.data ?? e.info?.error?.data ?? e.error?.data;
  if (!data || data === '0x') return e.shortMessage ?? e.message;
  try {
    const parsed = registry.interface.parseError(data);
    if (parsed) {
      const args = parsed.fragment.inputs
        .map((input, i) => `${input.name}=${parsed.args[i]}`)
        .join(', ');
      return args ? `${parsed.name}(${args})` : parsed.name;
    }
  } catch {
    /* fall through to the raw selector, which is still traceable */
  }
  return `unrecognised revert, selector ${data.slice(0, 10)}, data ${data}`;
}

const tx = await registry.submitProof(...args, { gasLimit: 3_000_000 });
console.log(`  sent ${tx.hash}`);
const submitted = await tx.wait();
console.log(`  recorded in Creditcoin block ${submitted.blockNumber}, ${submitted.gasUsed} gas\n`);

// Read the value back off Creditcoin and hold it against the source.
//
// This is the only check that matters to a consumer: the bytes recorded on Creditcoin
// must equal what the source contract returns at the height that was proven. Anything
// less is a number of unknown provenance.
let mismatch = false;

for (const log of submitted.logs) {
  let parsed;
  try {
    parsed = registry.interface.parseLog(log);
  } catch {
    continue;
  }
  if (parsed?.name !== 'ObservationRecorded') continue;

  const feedId = parsed.args.feedId;
  const target = parsed.args.target;
  const probeHeight = Number(parsed.args.probeHeight);

  // Identify which feed this is by recomputing the identifier, rather than by
  // matching on the target: one target can carry many feeds.
  const feed = feeds.find(
    (f) => f.chainId === chainId && computeFeedId(chainKey, f.target, callDataFor(f)) === feedId,
  );

  const observation = await registryContract().observationOf(feedId);
  console.log(`  feed ${feed?.name ?? feedId}`);
  console.log(`    height ${observation.probeHeight}, succeeded ${observation.callSucceeded}, truncated ${observation.truncated}`);
  console.log(`    prober ${observation.prober}`);
  console.log(`    on Creditcoin : ${observation.returnData}`);

  if (!feed) {
    console.log('    no local definition for this feed, so no comparison was made');
    continue;
  }

  const direct = await provider.call({ to: target, data: callDataFor(feed), blockTag: probeHeight });
  console.log(`    on the source : ${direct}`);

  if (observation.returnData === direct) {
    console.log(`    byte-equal, and the value is ${feed.describe(decodeFor(feed, observation.returnData))}`);
  } else {
    console.log('    MISMATCH between Creditcoin and the source');
    mismatch = true;
  }
}

console.log('');
process.exit(mismatch ? 1 : 0);
