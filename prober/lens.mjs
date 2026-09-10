#!/usr/bin/env node
/**
 * The Lens command line.
 *
 *   lens probe <feed>…      read on the source chain and emit the result
 *   lens prove <tx> <chain> prove that read to Creditcoin and compare
 *   lens verify [<feed>]    check a held value against the contract that produced it
 *   lens watch              show feeds ageing, before a consumer starts refusing
 *   lens doctor             check an integration end to end and say what is wrong
 *   lens bench              measured gas and lag, from transactions that happened
 *   lens keep               probe and prove on a cycle, unattended
 */
import { spawn } from 'node:child_process';

const commands = {
  probe: 'probe.mjs',
  prove: 'prove.mjs',
  verify: 'verify.mjs',
  watch: 'watch.mjs',
  doctor: 'doctor.mjs',
  bench: 'bench.mjs',
  keep: 'keep.mjs',
};

const [command, ...rest] = process.argv.slice(2);
if (!command || !commands[command]) {
  console.error('usage: lens <command> [args]\n');
  for (const c of Object.keys(commands)) console.error(`  lens ${c}`);
  console.error('\nSee the header of this file, or docs/INTEGRATING.md.');
  process.exit(command ? 2 : 0);
}

const script = new URL(commands[command], import.meta.url).pathname;
spawn(process.execPath, [script, ...rest], { stdio: 'inherit' }).on('close', (code) => process.exit(code ?? 0));
