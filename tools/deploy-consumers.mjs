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

const artifact = (name, file) =>
  JSON.parse(readFileSync(new URL(`../out/${file ?? name + '.sol'}/${name}.json`, import.meta.url)));

const deployed = {};

async function deploy(label, art, args) {
  if (!broadcast) {
    console.log(`  would deploy ${label}`);
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

const R = artifact('RegistryFeed');
const backingFeed = await deploy('feed: aave backing', R, [addresses.registry, chainKey, backing, RESERVE_MAX_AGE, 'WETH backing aWETH']);
const issuedFeed = await deploy('feed: aweth issued', R, [addresses.registry, chainKey, issued, RESERVE_MAX_AGE, 'aWETH issued']);

const ratioArt = artifact('RatioFeed', 'LensComposer.sol');
const ratio = broadcast
  ? await deploy('ratio: backing/issued', ratioArt, [deployed['feed: aave backing'], deployed['feed: aweth issued'], 10n ** 18n, 'aWETH backing ratio'])
  : await deploy('ratio: backing/issued', ratioArt, []);

// 1e18 is exactly covered; a reserve below that is under-collateralised.
await deploy('ReserveMonitor', artifact('ReserveMonitor', 'consumers/ReserveMonitor.sol'),
  broadcast ? [deployed['ratio: backing/issued'], 10n ** 18n, 'Aave Sepolia aWETH backing'] : []);

const aggregator = addresses.aggregator;
await deploy('LensMarket', artifact('LensMarket', 'consumers/LensMarket.sol'),
  // 150% collateral, 10% liquidation bonus, price no older than an hour of wall clock.
  broadcast ? [aggregator, 15000n, 1000n, 3600n] : []);

await deploy('CircuitBreaker', artifact('CircuitBreaker'),
  // 5% between updates, and a hard age limit twice the aggregator's.
  broadcast ? [addresses.registry, chainKey, ethUsd, 500n, PRICE_MAX_AGE * 2n] : []);

await deploy('FeedEscrow', artifact('FeedEscrow'), broadcast ? [addresses.registry] : []);

// The governance consumers point at a source-chain token that keeps checkpoints.
const VOTES_TOKEN = '0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830';
await deploy('VotePort', artifact('VotePort', 'consumers/VotePort.sol'),
  broadcast ? [addresses.registry, chainKey, VOTES_TOKEN, 5000n] : []);
await deploy('SnapshotProver', artifact('SnapshotProver', 'consumers/SnapshotProver.sol'),
  broadcast ? [addresses.registry, chainKey, 5000n] : []);

if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

writeFileSync(new URL('../docs/evidence/deployments.json', import.meta.url), JSON.stringify(deployed, null, 2) + '\n');
console.log(`\n  written to docs/evidence/deployments.json\n`);
