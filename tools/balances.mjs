/**
 * Reports the funding position of the Lens key on every chain it needs to act on.
 *
 *   node tools/balances.mjs
 *
 * Reads the address from LENS_ADDRESS in .env and never touches the private key.
 */
import { readFileSync } from 'node:fs';
import { JsonRpcProvider, formatEther } from 'ethers';

const env = Object.fromEntries(
  readFileSync(new URL('../.env', import.meta.url), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

const address = env.LENS_ADDRESS;
if (!address) throw new Error('LENS_ADDRESS missing from .env');

// What each chain is for, and roughly what it takes to be useful.
const chains = [
  { name: 'Creditcoin CC3 testnet', rpc: env.CC3_TESTNET_RPC, symbol: 'tCTC', need: 1n, why: 'deploy the registry, submit proofs' },
  { name: 'Ethereum Sepolia', rpc: env.SEPOLIA_RPC, symbol: 'SepoliaETH', need: 2n * 10n ** 16n, why: 'deploy the probe, run free reads' },
  { name: 'Ethereum mainnet', rpc: env.ETHEREUM_RPC, symbol: 'ETH', need: 0n, why: 'optional, real reads cost real gas' },
];

console.log(`\nLens key ${address}\n`);
for (const c of chains) {
  if (!c.rpc) { console.log(`  ${c.name.padEnd(24)} no RPC configured`); continue; }
  try {
    const balance = await new JsonRpcProvider(c.rpc, undefined, { staticNetwork: true }).getBalance(address);
    const enough = c.need === 0n ? null : balance >= c.need;
    const mark = enough === null ? '  --  ' : enough ? '  ok  ' : ' EMPTY';
    console.log(`${mark} ${c.name.padEnd(24)} ${formatEther(balance).padStart(20)} ${c.symbol}`);
    console.log(`       ${c.why}`);
  } catch (e) {
    console.log(`  FAIL ${c.name.padEnd(24)} ${(e.shortMessage ?? e.message).slice(0, 70)}`);
  }
}
console.log('');
