/**
 * Checks an integration end to end and says what is wrong with it.
 *
 *   node prober/doctor.mjs
 *
 * Written to be run by somebody else against their own deployment, not only by us
 * against ours. Every check names what it looked at and what it expected, because a
 * diagnostic that only says "failed" moves the work rather than doing it.
 */
import { Contract, formatEther } from 'ethers';
import {
  env, addresses, creditcoin, sourceProvider, sources, registryContract,
  supportedChains, chainKeyFor, feeds, callDataFor, computeFeedId,
} from './lib/config.mjs';

let failures = 0;
let warnings = 0;
const ok = (what, detail) => console.log(`  ok    ${what}${detail ? `\n        ${detail}` : ''}`);
const bad = (what, detail) => { failures++; console.log(`  FAIL  ${what}${detail ? `\n        ${detail}` : ''}`); };
const warn = (what, detail) => { warnings++; console.log(`  warn  ${what}${detail ? `\n        ${detail}` : ''}`); };

console.log('\nCreditcoin\n');
try {
  const net = await creditcoin.getNetwork();
  const height = await creditcoin.getBlockNumber();
  ok(`RPC reachable, chain ${net.chainId}, height ${height}`, env.CC3_TESTNET_RPC);
} catch (e) {
  bad('Creditcoin RPC unreachable', `${env.CC3_TESTNET_RPC} — ${e.shortMessage ?? e.message}`);
  process.exit(1);
}

console.log('\nChain keys\n');
let chains = [];
try {
  chains = await supportedChains();
  ok('ChainInfo precompile answers', chains.map((c) => `key ${c.chainKey} -> chain ${c.chainId} (${c.chainName})`).join('; '));
} catch (e) {
  bad('ChainInfo precompile did not answer', e.shortMessage ?? e.message);
}

console.log('\nRegistry\n');
if (!addresses.registry) {
  bad('LENS_REGISTRY is not set in .env');
} else {
  const code = await creditcoin.getCode(addresses.registry);
  if (code === '0x') bad('no contract at LENS_REGISTRY', addresses.registry);
  else {
    ok(`registry deployed, ${(code.length - 2) / 2} bytes`, addresses.registry);
    const registry = registryContract();
    for (const key of await registry.chainKeys()) {
      const s = await registry.sourceOf(key);
      const live = chains.find((c) => c.chainKey === Number(key));
      if (!live) bad(`registry accepts key ${key}, which this environment does not attest`);
      else if (Number(s.chainId) !== live.chainId) {
        bad(`key ${key} is bound to chain ${s.chainId} but the precompile says ${live.chainId}`,
          'this registry would report another chain’s state');
      } else {
        ok(`key ${key} bound to chain ${s.chainId} (${live.chainName}), probe ${s.probe}`);
      }
      // A probe address with no code on the source chain means nothing can ever be proven.
      const provider = sources[Number(s.chainId)] ? sourceProvider(Number(s.chainId)) : null;
      if (!provider) warn(`no RPC configured for chain ${s.chainId}, so its probe was not checked`);
      else {
        const probeCode = await provider.getCode(s.probe);
        if (probeCode === '0x') bad(`no probe deployed at ${s.probe} on chain ${s.chainId}`,
          'proofs for this chain can never be accepted');
        else ok(`probe present on chain ${s.chainId}, ${(probeCode.length - 2) / 2} bytes`);
      }
    }
  }
}

console.log('\nAttestation\n');
for (const c of chains) {
  try {
    const frontier = Number(await registryContract().frontierOf(c.chainKey));
    const provider = sources[c.chainId] ? sourceProvider(c.chainId) : null;
    if (!provider) { warn(`chain ${c.chainId}: no RPC configured, lag unknown`); continue; }
    const head = await provider.getBlockNumber();
    const lag = head - frontier;
    const line = `frontier ${frontier}, head ${head}, lag ${lag} blocks (~${Math.round((lag * 12) / 60)} min)`;
    if (lag < 0) bad(`chain ${c.chainId}: frontier is ahead of the source head`, line);
    else if (lag > 200) warn(`chain ${c.chainId}: attestation is falling behind`, line);
    else ok(`chain ${c.chainId} attested`, line);
  } catch (e) {
    bad(`chain ${c.chainId}: could not read the frontier`, e.shortMessage ?? e.message);
  }
}

console.log('\nProof builders\n');
for (const host of [env.PROOF_BUILDER_URL, env.PROOF_BUILDER_FALLBACK_URL].filter(Boolean)) {
  try {
    const res = await fetch(`${host}/api/v1/attested-height/${chains[0]?.chainKey ?? 1}`, {
      signal: AbortSignal.timeout(12000),
    });
    if (!res.ok) { warn(`${host} answered HTTP ${res.status}`); continue; }
    const { attestedHeight } = await res.json();
    ok(`${host}`, `ingested to ${attestedHeight}`);
  } catch (e) {
    warn(`${host} unreachable`, e.message);
  }
}

console.log('\nFeeds\n');
for (const feed of feeds) {
  try {
    const chainKey = await chainKeyFor(feed.chainId);
    const id = computeFeedId(chainKey, feed.target, callDataFor(feed));
    const registry = registryContract();
    if (!(await registry.hasObservation(id))) { warn(`${feed.name}: never proven`, id); continue; }
    const o = await registry.observationOf(id);
    const frontier = Number(await registry.frontierOf(chainKey));
    const age = frontier > Number(o.probeHeight) ? frontier - Number(o.probeHeight) : 0;
    if (!o.callSucceeded) bad(`${feed.name}: the source read failed`, `at block ${o.probeHeight}`);
    else if (age > 600) warn(`${feed.name}: ageing`, `${age} source blocks behind`);
    else ok(`${feed.name}`, `${age} blocks old, block ${o.probeHeight}`);
  } catch (e) {
    bad(`${feed.name}: ${e.shortMessage ?? e.message}`);
  }
}

console.log('\nKeys and balances\n');
if (!env.LENS_ADDRESS) warn('LENS_ADDRESS not set, so balances were not checked');
else {
  for (const [label, provider, need] of [
    ['Creditcoin', creditcoin, 10n ** 17n],
    ...Object.entries(sources).map(([id, s]) => [s.label, sourceProvider(Number(id)), 10n ** 15n]),
  ]) {
    try {
      const balance = await provider.getBalance(env.LENS_ADDRESS);
      if (balance === 0n) warn(`${label}: empty`, 'nothing can be sent from this key here');
      else if (balance < need) warn(`${label}: ${formatEther(balance)} — low`);
      else ok(`${label}: ${formatEther(balance)}`);
    } catch { warn(`${label}: balance unreadable`); }
  }
}

console.log(`\n${failures} failure(s), ${warnings} warning(s)\n`);
process.exit(failures ? 1 : 0);
