/**
 * Keeps every feed inside its freshness bound, unattended.
 *
 *   node prober/keep.mjs [--once] [--interval <seconds>]
 *
 * One cycle: probe every feed for a chain in a single transaction, wait for the block to
 * be attested and ingested by the builder, prove them all under one shared continuity
 * proof, then compare each recorded value against its source.
 *
 * Failures are survivable by design. A cycle that cannot complete logs why and the next
 * one starts fresh, because a prober going quiet must never be able to put a wrong value
 * on chain — the worst it can do is leave the last correct one to age out, at which
 * point every consumer refuses.
 */
import { spawn } from 'node:child_process';
import { feeds } from './lib/config.mjs';

const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
};
const once = process.argv.includes('--once');
const intervalMs = Number(arg('--interval', 900)) * 1000;

const stamp = () => new Date().toISOString().replace('T', ' ').slice(0, 19);
let cycleRunning = false;
const log = (...a) => console.log(`[${stamp()}]`, ...a);

function run(script, args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [script, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('close', (code) => resolve({ code, out }));
  });
}

async function cycle() {
  if (cycleRunning) {
    log('cycle skipped: previous cycle still running');
    return;
  }
  cycleRunning = true;
  try {
  const byChain = feeds.reduce((m, f) => ((m[f.chainId] ??= []).push(f.name), m), {});

  for (const [chainId, names] of Object.entries(byChain)) {
    log(`probing ${names.length} feed(s) on chain ${chainId}`);
    const probe = await run('prober/probe.mjs', names);

    // 75 is the gas ceiling refusing, which is the guard working rather than a fault.
    // These feeds tolerate hours; waiting for a cheaper block costs nothing.
    if (probe.code === 75) {
      log('  priced out: gas above the ceiling, so nothing was sent. Trying again next cycle.');
      continue;
    }
    if (probe.code !== 0) {
      log(`  probe failed, leaving the previous values to age out\n${probe.out.trim().split('\n').slice(-3).join('\n')}`);
      continue;
    }

    const hash = probe.out.match(/sent (0x[a-fA-F0-9]{64})/)?.[1];
    if (!hash) {
      log('  probe produced no transaction hash, so there is nothing to prove');
      continue;
    }
    log(`  probed in ${hash}`);

    // The wait is the attestation frontier catching up, and it is not optional.
    // probe.mjs emits one source transaction, even when it carries many feeds; a single
    // source transaction is therefore proved through submitProof, which records all its logs.
    const proofScript = 'prober/prove.mjs';
    const proofArgs = [hash, chainId];
    const prove = await run(proofScript, proofArgs);
    const matched = (prove.out.match(/byte-equal/gi) ?? []).length;
    const diverged = (prove.out.match(/MISMATCH/gi) ?? []).length;

    if (prove.out.includes('already recorded by someone else') || prove.out.includes('already recorded by another prober')) {
      log('  another prober got there first; the feed is fresh either way');
    } else if (prove.code === 0 && diverged === 0) {
      log('  proof completed through submitProof (' + matched + ' direct comparisons)');
    } else {
      log(`  proof cycle did not complete cleanly (${diverged} divergence(s))`);
      log(prove.out.trim().split('\n').slice(-4).join('\n'));
    }
    }
  } finally {
    cycleRunning = false;
  }
}

log(`keeper starting, ${feeds.length} feed(s), ${once ? 'one cycle' : `every ${intervalMs / 1000}s`}`);
await cycle();
if (!once) {
  setInterval(() => {
    cycle().catch((e) => log('cycle threw:', e.message));
  }, intervalMs);
}
