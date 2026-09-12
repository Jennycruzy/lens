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
import { JsonRpcProvider, Contract, Interface } from 'ethers';
import { env, creditcoin, sourceProvider, probeAddress, addresses, artifacts } from '../prober/lib/config.mjs';

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
  { label: 'StateProbe (current)', address: probeAddress(11155111), on: sepolia, chain: 'Sepolia' },
  { label: 'StateProbe (mainnet)', address: probeAddress(1), on: mainnet, chain: 'Ethereum mainnet' },
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
  const ok = named && (c.precompile ? true : hasCode);
  check(
    `${c.label} on ${c.chain}`,
    ok,
    `${c.address} — ${c.precompile ? 'native precompile' : `${(code.length - 2) / 2} bytes`}` +
      (named ? ', named in docs' : ', NOT named in docs'),
  );
}

// --- transaction hashes the documentation names ------------------------------
console.log('\nTransactions named in the documentation\n');
const providers = { 'CC3 testnet': creditcoin, Sepolia: sepolia, 'Ethereum mainnet': mainnet };
const transactions = new Map();
const addTransaction = (hash, name) => {
  if (providers[name]) transactions.set(`${name}:${hash.toLowerCase()}`, { hash, name, provider: providers[name] });
};
for (const row of docs.matchAll(/^\|.*\|\s*(CC3 testnet|Sepolia|Ethereum mainnet)\s*\|.*?(0x[a-fA-F0-9]{64})/gm)) addTransaction(row[2], row[1]);
for (const link of docs.matchAll(/https?:\/\/([^/\s)]+)\/tx\/(0x[a-fA-F0-9]{64})/g)) {
  const host = link[1].toLowerCase();
  const name = { 'creditcoin-testnet.blockscout.com': 'CC3 testnet', 'sepolia.etherscan.io': 'Sepolia', 'etherscan.io': 'Ethereum mainnet' }[host];
  if (name) addTransaction(link[2], name);
  else check('documented transaction link has a recognized chain', false, link[0]);
}
let txSucceeded = 0;
for (const tx of transactions.values()) {
  let receipt;
  try { receipt = await tx.provider.getTransactionReceipt(tx.hash); }
  catch (e) { check(`transaction on ${tx.name}`, false, `${tx.hash.slice(0, 20)}… ${e.shortMessage ?? e.message}`); continue; }
  const succeeded = Boolean(receipt) && receipt.status === 1;
  if (succeeded) txSucceeded++;
  check(`transaction on ${tx.name}`, succeeded, receipt ? `${tx.hash.slice(0, 20)}… block ${receipt.blockNumber}, status ${receipt.status}` : `${tx.hash.slice(0, 20)}… not found`);
}
check('every documented transaction was located and succeeded', txSucceeded === transactions.size && transactions.size > 0, `${txSucceeded}/${transactions.size} succeeded`);

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
// everywhere" is a claim about code rather than accidentally reusing one address.
const sepoliaProbe = probeAddress(11155111);
const mainnetProbe = probeAddress(1);
const sepoliaCode = await sepolia.getCode(sepoliaProbe);
const mainnetCode = await mainnet.getCode(mainnetProbe);
check(
  'the probe is identical bytecode on Sepolia and Ethereum mainnet',
  sepoliaCode === mainnetCode && sepoliaCode !== '0x',
  `${(sepoliaCode.length - 2) / 2} bytes on both`,
);

const topic = await registry.PROBED_SIGNATURE();
check(
  'the event topic in docs matches the deployed registry',
  docs.toLowerCase().includes(topic.toLowerCase()),
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
    const staleError = new Interface(['error FeedStale(bytes32,uint256,uint256)']);
    const data = e.data ?? e.info?.error?.data ?? e.error?.data;
    let stale = false;
    if (typeof data === 'string') {
      try { stale = staleError.parseError(data)?.name === 'FeedStale'; } catch {}
    }
    check(
      stale ? 'aggregator refuses a stale observation' : 'aggregator readable',
      stale,
      stale ? `the adapter failed closed with FeedStale (${data.slice(0, 14)}…)` : e.shortMessage ?? e.message,
    );
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
