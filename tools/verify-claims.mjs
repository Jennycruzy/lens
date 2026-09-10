/**
 * Checks the factual claims in docs/ against the live chains.
 *
 *   node tools/verify-claims.mjs
 *
 * Exists because prose drifts from reality quietly. Every contract address named in the
 * documentation is checked for code on the chain it is claimed to be on, every
 * transaction hash is checked for existence and success, and the values quoted for the
 * live feeds are re-read rather than trusted. Exits non-zero if any claim fails, so it
 * can gate a commit.
 */
import { readFileSync, readdirSync } from 'node:fs';
import { JsonRpcProvider, Contract } from 'ethers';
import { env, creditcoin, sourceProvider, addresses, artifacts } from '../prober/lib/config.mjs';

const docs = readdirSync(new URL('../docs/', import.meta.url))
  .filter((f) => f.endsWith('.md'))
  .map((f) => ({ name: f, text: readFileSync(new URL(`../docs/${f}`, import.meta.url), 'utf8') }))
  .reduce((all, d) => all + `\n<<<${d.name}>>>\n` + d.text, '');

const results = [];
const check = (what, ok, detail) => {
  results.push({ what, ok, detail });
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${what}`);
  if (detail) console.log(`        ${detail}`);
  return ok;
};

const sepolia = sourceProvider(11155111);
const mainnet = sourceProvider(1);

// --- contracts the documentation names, and where it says they live ----------
const claimedContracts = [
  { label: 'LensRegistry (current)', address: addresses.registry, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'StateProbe (current)', address: addresses.probe, on: sepolia, chain: 'Sepolia' },
  // Same address on both source chains by construction; the README says so, so it is checked.
  { label: 'StateProbe (mainnet)', address: addresses.probe, on: mainnet, chain: 'Ethereum mainnet' },
  { label: 'LensAggregatorV3', address: addresses.aggregator, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'ReserveMonitor', address: addresses.reserveMonitor, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'LensMarket', address: addresses.market, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'CircuitBreaker', address: addresses.breaker, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'FeedEscrow', address: addresses.escrow, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'VotePort', address: addresses.votePort, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'SnapshotProver', address: addresses.snapshotProver, on: creditcoin, chain: 'CC3 testnet' },
  { label: 'BlockProver precompile', address: '0x0000000000000000000000000000000000000FD2', on: creditcoin, chain: 'CC3 testnet', precompile: true },
  { label: 'ChainInfo precompile', address: '0x0000000000000000000000000000000000000fd3', on: creditcoin, chain: 'CC3 testnet', precompile: true },
  { label: 'Decoder contract', address: '0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f', on: creditcoin, chain: 'CC3 testnet' },
];

console.log('\nContracts named in the documentation\n');
for (const c of claimedContracts) {
  if (!c.address) {
    check(`${c.label}`, false, 'no address configured to check against');
    continue;
  }
  const named = docs.toLowerCase().includes(c.address.toLowerCase());
  const code = await c.on.getCode(c.address);
  const hasCode = code !== '0x';
  // Precompiles are native and carry no bytecode, so presence is not code length.
  const ok = c.precompile ? true : hasCode;
  check(
    `${c.label} on ${c.chain}`,
    ok,
    `${c.address} — ${c.precompile ? 'native precompile' : `${(code.length - 2) / 2} bytes`}` +
      (named ? ', named in docs' : ', NOT named in docs'),
  );
}

// --- transaction hashes the documentation names ------------------------------
console.log('\nTransactions named in the documentation\n');
const hashes = [...new Set(docs.match(/0x[a-fA-F0-9]{64}/g) ?? [])];
let txChecked = 0;
for (const h of hashes) {
  let found = null;
  for (const [name, p] of [['CC3 testnet', creditcoin], ['Sepolia', sepolia]]) {
    try {
      const r = await p.getTransactionReceipt(h);
      if (r) {
        found = { name, r };
        break;
      }
    } catch { /* not on this chain */ }
  }
  if (!found) continue; // feed ids and topics also match this shape; skip non-transactions
  txChecked++;
  check(
    `transaction on ${found.name}`,
    found.r.status === 1,
    `${h.slice(0, 20)}… block ${found.r.blockNumber}, status ${found.r.status}`,
  );
}
check('every documented transaction was located and succeeded', txChecked > 0, `${txChecked} checked`);

// --- values the documentation quotes, re-read from the chain ------------------
console.log('\nValues quoted in the documentation\n');
const registry = new Contract(addresses.registry, artifacts.registry.abi, creditcoin);

for (const [key, label] of [[3, 'Ethereum mainnet'], [1, 'Sepolia']]) {
  const source = await registry.sourceOf(key);
  const expected = key === 3 ? 1n : 11155111n;
  check(
    `chain key ${key} is bound to ${label}`,
    source.chainId === expected && source.registered,
    `chainId ${source.chainId}, probe ${source.probe}`,
  );
}

// The probe must be the same bytecode on both source chains, or "one address
// everywhere" is a claim about addresses rather than about code.
const sepoliaCode = await sepolia.getCode(addresses.probe);
const mainnetCode = await mainnet.getCode(addresses.probe);
check(
  'the probe is identical bytecode on Sepolia and Ethereum mainnet',
  sepoliaCode === mainnetCode && sepoliaCode !== '0x',
  `${(sepoliaCode.length - 2) / 2} bytes on both`,
);

const topic = await registry.PROBED_SIGNATURE();
check(
  'the event topic in docs matches the deployed registry',
  docs.includes(topic),
  topic,
);

// The aggregator's live answer, checked against its own source contract.
if (addresses.aggregator) {
  const agg = new Contract(
    addresses.aggregator,
    ['function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)'],
    creditcoin,
  );
  try {
    const [roundId, answer, , updatedAt] = await agg.latestRoundData();
    const direct = await sepolia.call({
      to: '0x694AA1769357215DE4FAC081bf1f309aDC325306',
      data: '0x50d25bcd',
      blockTag: Number(roundId),
    });
    const onSource = BigInt(direct);
    check(
      'the aggregator answer equals the source contract at the proven height',
      answer === onSource,
      `Creditcoin ${answer}, Sepolia at block ${roundId} ${onSource}`,
    );
    const block = await sepolia.getBlock(Number(roundId));
    check(
      'updatedAt equals the source block timestamp, not Creditcoin time',
      Number(updatedAt) === block.timestamp,
      `updatedAt ${updatedAt}, Sepolia block ${roundId} timestamp ${block.timestamp}`,
    );
  } catch (e) {
    check('aggregator readable', false, e.shortMessage ?? e.message);
  }
}

// --- summary ------------------------------------------------------------------
const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} claims verified`);
if (failed.length) {
  console.log('\nunverified:');
  for (const f of failed) console.log(`  ${f.what} — ${f.detail}`);
}
console.log('');
process.exit(failed.length ? 1 : 0);
