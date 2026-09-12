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
  computeFeedId, callDataFor, decodeFor, feeds, sources, CHAIN_INFO, addresses,
  builderAttestedHeight, proofBuilderHosts, localProofBuilder, probeContract,
} from './lib/config.mjs';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };

const [txHash, chainIdArg] = process.argv.slice(2);
if (!txHash || !chainIdArg) {
  console.error('usage: node prober/prove.mjs <source-tx-hash> <source-chain-id> [--claim <feedId>]');
  process.exit(2);
}
// Routing through the escrow instead of straight to the registry: the escrow submits the
// same proof and pays the caller for it in the same transaction, so an earned fee cannot
// be taken by somebody else between proving and claiming.
const claimIndex = process.argv.indexOf('--claim');
const claimFeedId = claimIndex === -1 ? null : process.argv[claimIndex + 1];
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

    const builderState = await builderAttestedHeight(chainKey);
    const builder = builderState.height;
    const unavailable = builderState.attempts
      .filter((attempt) => attempt.status === 'unreachable' || attempt.kind === 'http' || attempt.kind === 'not-found' || attempt.kind === 'unprocessable')
      .map((attempt) => `${attempt.host}=${attempt.status === 'unreachable' ? 'unreachable' : attempt.kind ?? attempt.status}`);
    if (unavailable.length) console.log(`  builders: ${unavailable.join(', ')}`);

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
  const hosts = proofBuilderHosts();
  const failures = [];
  for (const host of hosts) {
    const url = `${host}/api/v1/proof-by-tx/${chainKey}/${txHash}`;
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(60000) });
      if (res.ok) {
        console.log(`  proof from ${host}`);
        return await res.json();
      }
      const detail = (await res.text()).slice(0, 120);
      const kind = res.status === 404 ? 'not-found' : res.status === 422 ? 'unprocessable' : 'http';
      failures.push(`${host} -> ${kind} (HTTP ${res.status}) ${detail}`);
    } catch (e) {
      failures.push(`${host} -> unreachable: ${e.message}`);
    }
  }
  try {
    const local = await localProofBuilder(chainId, chainKey).getProof(txHash);
    if (local.success) {
      console.log('  proof from local SDK raw builder');
      return local.data;
    }
    failures.push('local-sdk -> ' + (local.error ?? 'unknown error'));
  } catch (e) {
    failures.push('local-sdk -> unreachable: ' + e.message);
  }

  throw new Error('no builder produced a proof:\n    ' + failures.join('\n    '));
}

const proof = await getProof();
const body = proof.data ?? proof;
const { txBytes, merkleProof, continuityProof } = body;
if (!txBytes || !merkleProof || !continuityProof) {
  throw new Error('builder response missing proof fields: ' + JSON.stringify(Object.keys(body)));
}
const proofHeight = Number(body.headerNumber ?? height);
if (!Number.isSafeInteger(proofHeight) || proofHeight !== height) {
  throw new Error('builder proof height ' + body.headerNumber + ' does not match receipt block ' + height);
}

console.log(`  transaction bytes ${(txBytes.length - 2) / 2}, merkle siblings ${merkleProof.siblings.length}, continuity roots ${continuityProof.roots.length}`);

const wallet = creditcoinWallet();
const registry = registryContract(wallet);
const args = [
  chainKey,
  proofHeight,
  txBytes,
  { root: merkleProof.root, siblings: merkleProof.siblings.map((s) => ({ hash: s.hash, isLeft: s.isLeft })) },
  { lowerEndpointDigest: continuityProof.lowerEndpointDigest, roots: continuityProof.roots },
];

// Call before estimating. Creditcoin returns a bare revert with no data from
// eth_estimateGas, so an estimate that fails says nothing about why.
if (claimFeedId && !addresses.escrow) {
  console.error('\n  --claim was given but LENS_ESCROW is missing from .env');
  process.exit(2);
}

// Routing through the escrow rather than straight to the registry. The escrow submits
// the same proof and pays the caller in the same transaction, so a fee that was earned
// cannot be taken by somebody else between proving and claiming.
const escrow = claimFeedId
  ? new Contract(
      addresses.escrow,
      [
        'function submitAndClaim(uint64 chainKey,uint64 blockHeight,bytes encodedTransaction,(bytes32 root,(bytes32 hash,bool isLeft)[] siblings) merkleProof,(bytes32 lowerEndpointDigest,bytes32[] roots) continuityProof,bytes32 feedId) returns (uint256 recorded,uint256 paid)',
        'function payableNow(bytes32,uint64) view returns (uint256)',
      ],
      wallet,
    )
  : null;

try {
  if (escrow) {
    const offered = await escrow.payableNow(claimFeedId, args[1]);
    const [recorded, paid] = await escrow.submitAndClaim.staticCall(...args, claimFeedId);
    console.log(`  through the escrow: would record ${recorded} and pay ${paid} wei (offered ${offered})`);
  } else {
    const would = await registry.submitProof.staticCall(...args);
    console.log(`  submission would record ${would} observation(s)`);
  }
} catch (e) {
  const why = describeRevert(e);

  /**
   * A query that has already been proven is not a failure.
   *
   * Two probers racing the same feed is the normal case, not an error: whoever lands
   * first records the observation and the other finds it spent. Treating that as a
   * failure would have every honest prober logging errors for doing its job, and would
   * make a retry loop hammer a query that can never succeed again.
   */
  if (/QueryAlreadyConsumed|ObservationNotNewer/.test(why)) {
    console.log(`\n  already recorded by someone else: ${why}`);
    console.log('  nothing to do; this is the normal outcome when probers overlap.');
    process.exit(0);
  }

  console.error(`\n  the ${escrow ? 'escrow' : 'registry'} rejected this proof`);
  console.error('  ' + why);
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
  // The escrow's own errors are worth naming too, not just the registry's.
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

let estimatedGas;
try {
  estimatedGas = escrow
    ? await escrow.submitAndClaim.estimateGas(...args, claimFeedId)
    : await registry.submitProof.estimateGas(...args);
} catch (e) {
  console.error(`\n  gas estimation refused; nothing was sent: ${e.shortMessage ?? e.message}`);
  process.exit(1);
}
console.log(`  measured submission gas ${estimatedGas}`);

const tx = escrow
  ? await escrow.submitAndClaim(...args, claimFeedId, { gasLimit: estimatedGas })
  : await registry.submitProof(...args, { gasLimit: estimatedGas });
console.log(`  sent ${tx.hash}`);
const submitted = await tx.wait();
console.log(`  recorded in Creditcoin block ${submitted.blockNumber}, ${submitted.gasUsed} gas\n`);

// Read the value back off Creditcoin and hold it against the source.
//
// This is the only check that matters to a consumer: the bytes recorded on Creditcoin
// must equal what the source contract returns at the height that was proven. Anything
// less is a number of unknown provenance.
let mismatch = false;

const sourceProbe = probeContract(chainId);
const expectedProbeLogs = receipt.logs
  .filter((log) => log.address.toLowerCase() === sourceProbe.target.toLowerCase())
  .map((log) => {
    try { return sourceProbe.interface.parseLog(log); } catch { return null; }
  })
  .filter((log) => log?.name === 'Probed');
const acceptedFeedIds = new Set();
if (expectedProbeLogs.length === 0) {
  console.error('  the source receipt contains no Probed event');
  process.exit(1);
}

for (const log of submitted.logs) {
  let parsed;
  try {
    parsed = registry.interface.parseLog(log);
  } catch {
    continue;
  }
  if (parsed?.name !== 'ObservationRecorded') continue;

  const feedId = parsed.args.feedId;
  if (acceptedFeedIds.has(feedId)) {
    console.error('    duplicate ObservationRecorded event for ' + feedId);
    mismatch = true;
    continue;
  }
  acceptedFeedIds.add(feedId);
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

  if (!parsed.args.callSucceeded || observation.truncated) {
    console.log('    proven result is unavailable (source call failed or returndata was truncated)');
    continue;
  }

  let direct;
  try {
    direct = await provider.call({ to: target, data: callDataFor(feed), blockTag: probeHeight });
  } catch (e) {
    console.error('    source state could not be read at the proven height: ' + (e.shortMessage ?? e.message));
    mismatch = true;
    continue;
  }
  console.log(`    on the source : ${direct}`);

  if (observation.returnData === direct) {
    console.log(`    byte-equal, and the value is ${feed.describe(decodeFor(feed, observation.returnData))}`);
  } else {
    console.log('    MISMATCH between Creditcoin and the source');
    mismatch = true;
  }
}

if (acceptedFeedIds.size !== expectedProbeLogs.length) {
  console.error('  accepted ' + acceptedFeedIds.size + ' observation(s), expected ' + expectedProbeLogs.length);
  mismatch = true;
}
console.log('');
process.exit(mismatch ? 1 : 0);
