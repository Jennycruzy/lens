/**
 * Verifies every piece of Creditcoin/Attestcoin infrastructure Lens depends on,
 * against the live network, and writes a timestamped evidence record.
 *
 * Nothing about the deployment is taken on trust from documentation: each fact
 * is re-derived from a runtime call and compared against what the docs claim.
 *
 *   node tools/verify-infra.mjs [--json]
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { JsonRpcProvider, Contract, toUtf8String } from 'ethers';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };
import blockProverAbi from '@gluwa/usc-sdk/dist/block-prover/block_prover.json' with { type: 'json' };

const CC3_TESTNET_RPC = process.env.CC3_TESTNET_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network';
const ETHEREUM_RPC = process.env.ETHEREUM_RPC ?? 'https://ethereum-rpc.publicnode.com';
const SEPOLIA_RPC = process.env.SEPOLIA_RPC ?? 'https://ethereum-sepolia-rpc.publicnode.com';

const CHAIN_INFO = '0x0000000000000000000000000000000000000fd3';
const BLOCK_PROVER = '0x0000000000000000000000000000000000000FD2';
const DECODER = '0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f';
const CC3_TESTNET_CHAIN_ID = 102031n;

// What the documentation claims, so the runtime can contradict it.
const DOC_CLAIMS = {
  supportedChains: [
    { chainKey: 3, chainId: 1, label: 'Ethereum mainnet' },
    { chainKey: 1, chainId: 11155111, label: 'Ethereum Sepolia' },
  ],
};

// Source-chain RPCs keyed by the *native* chain id, never by chain key: a chain
// key is an Attestcoin-environment-local label and means different chains on
// different environments. See docs/VERIFIED.md row 5.
const SOURCE_RPC_BY_CHAIN_ID = { 1: ETHEREUM_RPC, 11155111: SEPOLIA_RPC };
const BLOCK_TIME_SECONDS = { 1: 12, 11155111: 12 };

const results = [];
const record = (id, what, status, detail, evidence) => {
  results.push({ id, what, status, detail, evidence });
  return status === 'pass';
};

async function main() {
  const cc3 = new JsonRpcProvider(CC3_TESTNET_RPC, undefined, { staticNetwork: true });

  // --- the chain we are actually talking to -------------------------------
  const net = await cc3.getNetwork();
  record(
    'rpc',
    'CC3 testnet RPC reachable and is chain 102031',
    net.chainId === CC3_TESTNET_CHAIN_ID ? 'pass' : 'fail',
    `eth_chainId = ${net.chainId}`,
    { rpc: CC3_TESTNET_RPC, chainId: Number(net.chainId), height: await cc3.getBlockNumber() },
  );

  // --- ChainInfo precompile ------------------------------------------------
  const chainInfo = new Contract(CHAIN_INFO, chainInfoAbi, cc3);
  const raw = await chainInfo.get_supported_chains();
  const chains = raw.map((c) => ({
    chainKey: Number(c[0]),
    chainId: Number(c[1]),
    chainName: toUtf8String(c[2]), // ABI type is `bytes`, despite the SDK typing it `string`
    chainEncoding: Number(c[3]),
  }));
  record('chaininfo', 'ChainInfo precompile answers get_supported_chains', 'pass',
    chains.map((c) => `key ${c.chainKey} -> chainId ${c.chainId} (${c.chainName})`).join('; '),
    { address: CHAIN_INFO, chains });

  // --- the chain-key trap --------------------------------------------------
  // A hardcoded key verifies every proof while reporting the wrong chain, so the
  // binding that matters is chainKey -> native chainId, resolved at runtime.
  for (const claim of DOC_CLAIMS.supportedChains) {
    const live = chains.find((c) => c.chainKey === claim.chainKey);
    const ok = live && live.chainId === claim.chainId;
    record(`chainkey-${claim.chainKey}`,
      `chain key ${claim.chainKey} really is ${claim.label} (chainId ${claim.chainId})`,
      ok ? 'pass' : 'fail',
      live ? `runtime says chainId ${live.chainId} "${live.chainName}"` : 'key absent at runtime',
      { claimed: claim, observed: live ?? null });
  }

  // --- attestation frontier, depth and measured lag ------------------------
  const frontier = {};
  for (const c of chains) {
    const [attH, attHash, , attExists] = await chainInfo.get_latest_attestation_height_and_hash(c.chainKey);
    const [ckH, , , ckExists] = await chainInfo.get_latest_checkpoint_height_and_hash(c.chainKey);
    const genesis = await chainInfo.get_attestation_genesis_height(c.chainKey);

    let head = null, lagBlocks = null, lagSeconds = null;
    const srcRpc = SOURCE_RPC_BY_CHAIN_ID[c.chainId];
    if (srcRpc) {
      try {
        head = await new JsonRpcProvider(srcRpc, undefined, { staticNetwork: true }).getBlockNumber();
        lagBlocks = head - Number(attH);
        lagSeconds = lagBlocks * (BLOCK_TIME_SECONDS[c.chainId] ?? 12);
      } catch (e) {
        head = `unreachable: ${e.shortMessage ?? e.message}`;
      }
    }

    frontier[c.chainKey] = {
      chainId: c.chainId, chainName: c.chainName,
      latestAttestation: Number(attH), latestAttestationHash: attHash, attestationExists: attExists,
      latestCheckpoint: Number(ckH), checkpointExists: ckExists,
      attestationGenesisHeight: Number(genesis),
      sourceHead: head, lagBlocks, lagSeconds,
    };

    record(`frontier-${c.chainKey}`,
      `attestation frontier readable for ${c.chainName}`,
      attExists ? 'pass' : 'fail',
      `attested to ${attH}, source head ${head}, lag ${lagBlocks} blocks (~${lagSeconds}s); provable from height ${genesis}`,
      frontier[c.chainKey]);
  }

  // --- BlockProver precompile ---------------------------------------------
  // Precompiles carry no bytecode, so presence is proven by behaviour: a
  // well-formed call with a bogus proof must be *rejected*, not silently accepted.
  const prover = new Contract(BLOCK_PROVER, blockProverAbi, cc3);
  const someKey = chains[0].chainKey;
  let proverDetail, proverStatus;
  try {
    const accepted = await prover.getFunction(
      'verify(uint64,uint64,bytes,(bytes32,(bytes32,bool)[]),(bytes32,bytes32[]))',
    ).staticCall(
      someKey, 1n, '0xdeadbeef',
      { root: '0x' + '00'.repeat(32), siblings: [] },
      { lowerEndpointDigest: '0x' + '00'.repeat(32), roots: [] },
    );
    proverStatus = accepted === false ? 'pass' : 'fail';
    proverDetail = `verify() returned ${accepted} for a bogus proof`;
  } catch (e) {
    const msg = (e.shortMessage ?? e.message ?? '').slice(0, 200);
    // A revert from the precompile is a rejection, and is the stronger outcome.
    // A local ABI or encoding error means the call never left this process and
    // proves nothing, so it must not be scored as one.
    const neverReachedTheChain = /no matching function|unconfigured name|invalid|incorrect data length|types\/values length mismatch/i.test(msg);
    proverStatus = neverReachedTheChain ? 'fail' : 'pass';
    proverDetail = neverReachedTheChain
      ? `inconclusive: the call never reached the precompile (${msg})`
      : `verify() rejected a bogus proof by reverting: ${msg}`;
  }
  record('blockprover', 'BlockProver precompile is live and rejects a forged proof',
    proverStatus, proverDetail, { address: BLOCK_PROVER });

  // --- decoder contract ----------------------------------------------------
  const decoderCode = await cc3.getCode(DECODER);
  record('decoder', 'Decoder contract is deployed on CC3 testnet',
    decoderCode !== '0x' ? 'pass' : 'fail',
    `${(decoderCode.length - 2) / 2} bytes of code at ${DECODER}`,
    { address: DECODER, codeSize: (decoderCode.length - 2) / 2 });

  // --- proof builder hosts, primary and failover ---------------------------
  const hosts = [
    'https://prover.cc3-testnet.creditcoin.network',
    'https://proof-gen-api.cc3-testnet.creditcoin.network',
  ];
  const probes = [];
  for (const host of hosts) {
    for (const path of ['/', '/swagger/index.html', '/api-docs', '/openapi.json', '/health']) {
      try {
        const res = await fetch(host + path, { redirect: 'follow', signal: AbortSignal.timeout(12000) });
        probes.push({ host, path, status: res.status, contentType: res.headers.get('content-type') });
      } catch (e) {
        probes.push({ host, path, status: 'unreachable', error: e.message });
      }
    }
  }
  const reachable = probes.filter((p) => typeof p.status === 'number' && p.status < 500);
  record('proofbuilder', 'At least two independent proof builder hosts answer',
    new Set(reachable.map((p) => p.host)).size >= 2 ? 'pass' : 'fail',
    reachable.map((p) => `${p.host}${p.path} -> ${p.status}`).join('; ') || 'none reachable',
    { probes });

  // --- report --------------------------------------------------------------
  const passed = results.filter((r) => r.status === 'pass').length;
  const evidence = {
    generatedAt: new Date().toISOString(),
    creditcoinHeight: await cc3.getBlockNumber(),
    summary: `${passed}/${results.length} checks passed`,
    chains, frontier, results,
  };
  mkdirSync('docs/evidence', { recursive: true });
  writeFileSync('docs/evidence/infra-verification.json', JSON.stringify(evidence, null, 2) + '\n');

  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(evidence, null, 2));
  } else {
    console.log(`\nLens infrastructure verification  ${evidence.generatedAt}`);
    console.log(`CC3 testnet height ${evidence.creditcoinHeight}\n`);
    for (const r of results) {
      console.log(`  ${r.status === 'pass' ? 'PASS' : 'FAIL'}  ${r.what}`);
      console.log(`        ${r.detail}`);
    }
    console.log(`\n${evidence.summary}  ->  docs/evidence/infra-verification.json\n`);
  }
  process.exit(results.every((r) => r.status === 'pass') ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(2); });
