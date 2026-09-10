/**
 * Deploys the composition layer and the four consumers against live feeds.
 *
 *   node tools/deploy-consumers.mjs [--broadcast]
 *
 * Every address it needs is derived: feed identifiers from the calldata the prober
 * uses, chain keys from the precompile. Nothing is written down twice, so a feed
 * definition and the contract reading it cannot drift apart.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { ContractFactory, Contract } from 'ethers';
import {
  feedByName, callDataFor, chainKeyFor, computeFeedId,
  creditcoin, creditcoinWallet, addresses,
} from '../prober/lib/config.mjs';

const broadcast = process.argv.includes('--broadcast');
const wallet = creditcoinWallet();

/// Foundry keys `out/` by source filename alone, not by path, so a contract declared
/// in another file is found under that file's name rather than its directory.
const artifact = (name, file) =>
  JSON.parse(readFileSync(new URL(`../out/${file ?? name + '.sol'}/${name}.json`, import.meta.url)));

const deployed = {};

async function deploy(label, art, argsFn) {
  const args = argsFn();
  if (!broadcast) {
    console.log(`  would deploy ${label.padEnd(26)} ${args.map(String).map((a) => (a.length > 20 ? a.slice(0, 12) + '…' : a)).join('  ')}`);
    deployed[label] = `0x${label.length.toString(16).padStart(40, '0')}`; // placeholder for the dry run
    return null;
  }
  const factory = new ContractFactory(art.abi, art.bytecode.object, wallet);
  const c = await factory.deploy(...args);
  await c.waitForDeployment();
  const address = await c.getAddress();
  deployed[label] = address;
  console.log(`  ${label.padEnd(26)} ${address}`);
  return new Contract(address, art.abi, wallet);
}

const chainKey = await chainKeyFor(11155111);
const feedIdOf = async (name) => {
  const f = feedByName(name);
  return computeFeedId(await chainKeyFor(f.chainId), f.target, callDataFor(f));
};

const ethUsd = await feedIdOf('sepolia.chainlink.ethUsd');
const backing = await feedIdOf('sepolia.aave.wethBacking');
const issued = await feedIdOf('sepolia.aave.awethIssued');

console.log(`\n  registry  ${addresses.registry}`);
console.log(`  chain key ${chainKey} (Sepolia)`);
console.log(`  feeds     ethUsd ${ethUsd.slice(0, 12)}…  backing ${backing.slice(0, 12)}…  issued ${issued.slice(0, 12)}…\n`);

// Ages are in source-chain blocks. The frontier trails the head by roughly 40, so
// anything under that is unreachable; these are chosen well above it.
const PRICE_MAX_AGE = 300n; // about an hour of Sepolia
const RESERVE_MAX_AGE = 900n; // reserves move slowly, so a wider window is honest

if (!addresses.aggregator) throw new Error('LENS_AGGREGATOR_ETHUSD missing from .env');

const R = artifact('RegistryFeed');
await deploy('feed.aaveBacking', R, () => [addresses.registry, chainKey, backing, RESERVE_MAX_AGE, 'WETH backing aWETH']);
await deploy('feed.awethIssued', R, () => [addresses.registry, chainKey, issued, RESERVE_MAX_AGE, 'aWETH issued']);

await deploy('ratio.backingOverIssued', artifact('RatioFeed', 'LensComposer.sol'),
  () => [deployed['feed.aaveBacking'], deployed['feed.awethIssued'], 10n ** 18n, 'aWETH backing ratio']);

// 1e18 is exactly covered; below that the reserve does not cover what was issued.
await deploy('ReserveMonitor', artifact('ReserveMonitor'),
  () => [deployed['ratio.backingOverIssued'], 10n ** 18n, 'Aave Sepolia aWETH backing']);

// 150% collateral, 10% liquidation bonus, a price no older than an hour of wall clock.
await deploy('LensMarket', artifact('LensMarket'),
  () => [addresses.aggregator, 15000n, 1000n, 3600n]);

// 5% between updates, and a hard age limit twice the aggregator's.
await deploy('CircuitBreaker', artifact('CircuitBreaker'),
  () => [addresses.registry, chainKey, ethUsd, 500n, PRICE_MAX_AGE * 2n]);

await deploy('FeedEscrow', artifact('FeedEscrow'), () => [addresses.registry]);

// The governance consumers read a source-chain token that keeps checkpoints.
const VOTES_TOKEN = '0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830';
await deploy('VotePort', artifact('VotePort'),
  () => [addresses.registry, chainKey, VOTES_TOKEN, 5000n]);
await deploy('SnapshotProver', artifact('SnapshotProver'),
  () => [addresses.registry, chainKey, 5000n]);

if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

writeFileSync(new URL('../docs/evidence/deployments.json', import.meta.url), JSON.stringify(deployed, null, 2) + '\n');
console.log(`\n  written to docs/evidence/deployments.json\n`);
