/**
 * Deploys a Chainlink-shaped adapter over one Lens feed.
 *
 *   node tools/deploy-aggregator.mjs <feed-name> <decimals> <max-age-blocks> [--broadcast]
 *
 * The age limit is in blocks of the source chain, not seconds and not Creditcoin
 * blocks, because that is the only measure that describes how far behind the value is.
 */
import { readFileSync } from 'node:fs';
import { ContractFactory, Contract } from 'ethers';
import {
  env, feedByName, callDataFor, chainKeyFor, computeFeedId,
  creditcoin, creditcoinWallet, addresses,
} from '../prober/lib/config.mjs';

const [name, decimalsArg, maxAgeArg] = process.argv.slice(2);
const broadcast = process.argv.includes('--broadcast');
if (!name || !decimalsArg || !maxAgeArg) {
  console.error('usage: node tools/deploy-aggregator.mjs <feed-name> <decimals> <max-age-blocks> [--broadcast]');
  process.exit(2);
}

const feed = feedByName(name);
const chainKey = await chainKeyFor(feed.chainId);
const feedId = computeFeedId(chainKey, feed.target, callDataFor(feed));
const decimals = Number(decimalsArg);
const maxAge = BigInt(maxAgeArg);

const artifact = JSON.parse(
  readFileSync(new URL('../out/LensAggregatorV3.sol/LensAggregatorV3.json', import.meta.url)),
);

console.log(`\n  feed        ${feed.name}`);
console.log(`  registry    ${addresses.registry}`);
console.log(`  chain key   ${chainKey}`);
console.log(`  feed id     ${feedId}`);
console.log(`  decimals    ${decimals}`);
console.log(`  max age     ${maxAge} source blocks (about ${(Number(maxAge) * 12) / 60} minutes)`);

if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

const factory = new ContractFactory(artifact.abi, artifact.bytecode.object, creditcoinWallet());
const aggregator = await factory.deploy(
  addresses.registry, chainKey, feedId, decimals, maxAge, feed.name,
);
console.log(`\n  deployment tx ${aggregator.deploymentTransaction().hash}`);
await aggregator.waitForDeployment();
const address = await aggregator.getAddress();
console.log(`  aggregator    ${address}`);

// Read it back through the Chainlink interface, exactly as a consumer would.
const asChainlink = new Contract(
  address,
  [
    'function decimals() view returns (uint8)',
    'function description() view returns (string)',
    'function version() view returns (uint256)',
    'function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)',
    'function ageInBlocks() view returns (uint256)',
  ],
  creditcoin,
);

console.log('\n  read back through AggregatorV3Interface:');
console.log(`    description ${await asChainlink.description()}`);
console.log(`    decimals    ${await asChainlink.decimals()}`);
console.log(`    version     ${await asChainlink.version()}`);
try {
  const [roundId, answer, startedAt, updatedAt] = await asChainlink.latestRoundData();
  const age = await asChainlink.ageInBlocks();
  console.log(`    roundId     ${roundId} (the source height the read happened at)`);
  console.log(`    answer      ${answer}  ->  ${feed.describe(answer)}`);
  console.log(`    updatedAt   ${updatedAt} (${new Date(Number(updatedAt) * 1000).toISOString()}, source clock)`);
  console.log(`    startedAt   ${startedAt}`);
  console.log(`    age         ${age} source blocks`);
} catch (e) {
  console.log(`    latestRoundData refused: ${e.shortMessage ?? e.message}`);
  console.log('    that is the feed failing closed, which is the intended behaviour');
}
console.log('');
