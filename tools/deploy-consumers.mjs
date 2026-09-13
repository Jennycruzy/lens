/**
 * Deploys the composition layer and the four consumers against live feeds.
 *
 *   node tools/deploy-consumers.mjs [--broadcast] [--redeploy]
 *
 * Every address it needs is derived: feed identifiers from the calldata the prober
 * uses, chain keys from the precompile. Nothing is written down twice, so a feed
 * definition and the contract reading it cannot drift apart. A recorded deployment is
 * reused only when its runtime bytecode still matches the artifact; --redeploy is an
 * explicit opt-in for replacing a reviewed deployment.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { ContractFactory, Contract, keccak256 } from 'ethers';
import {

  feedByName, callDataFor, chainKeyFor, computeFeedId,
  creditcoin, creditcoinWallet, deployments,
} from '../prober/lib/config.mjs';

/** Reads a compiled artifact, and says what to do when the project has not been built. */
function readArtifact(url) {
  try {
    return JSON.parse(readFileSync(url));
  } catch {
    console.error('\n  no compiled artifact. Run: forge build\n');
    process.exit(2);
  }
}


const broadcast = process.argv.includes('--broadcast');
const redeploy = process.argv.includes('--redeploy');
const wallet = creditcoinWallet();

/// Foundry keys `out/` by source filename alone, not by path, so a contract declared
/// in another file is found under that file's name rather than its directory.
const artifact = (name, file) =>
  readArtifact(new URL(`../out/${file ?? name + '.sol'}/${name}.json`, import.meta.url));

const evidenceUrl = new URL('../docs/evidence/deployments.json', import.meta.url);
let previous = {};
try { previous = JSON.parse(readFileSync(evidenceUrl)); } catch {}

const stripMetadata = (hex) => {
  if (!hex || hex === '0x') return hex;
  const body = hex.slice(2);
  const metadataLength = parseInt(body.slice(-4), 16);
  if (!metadataLength || metadataLength * 2 + 4 > body.length) return hex;
  return '0x' + body.slice(0, body.length - (metadataLength * 2 + 4));
};

const maskImmutables = (hex, refs) => {
  const body = hex.slice(2).split('');
  for (const slots of Object.values(refs ?? {})) {
    for (const { start, length } of slots) {
      for (let i = start * 2; i < (start + length) * 2 && i < body.length; i++) body[i] = '0';
    }
  }
  return '0x' + body.join('');
};

async function matchesArtifact(address, art) {
  const code = await creditcoin.getCode(address);
  if (code === '0x' || !art.deployedBytecode?.object) return false;
  const expected = keccak256(maskImmutables(stripMetadata(art.deployedBytecode.object), art.deployedBytecode.immutableReferences));
  const actual = keccak256(maskImmutables(stripMetadata(code), art.deployedBytecode.immutableReferences));
  return expected === actual;
}

const deployed = {};

async function deploy(label, art, argsFn) {
  const args = argsFn();
  if (!broadcast) {
    console.log(`  would deploy ${label.padEnd(26)} ${args.map(String).map((a) => (a.length > 20 ? a.slice(0, 12) + '…' : a)).join('  ')}`);
    deployed[label] = `0x${label.length.toString(16).padStart(40, '0')}`; // placeholder for the dry run
    return null;
  }
  const recorded = previous[label];
  if (recorded && !redeploy) {
    if (!(await matchesArtifact(recorded, art))) {
      throw new Error(`${label} is recorded at ${recorded}, but its bytecode is absent or stale; rerun with --redeploy after reviewing the change`);
    }
    deployed[label] = recorded;
    console.log(`  ${label.padEnd(26)} reused ${recorded}`);
    return new Contract(recorded, art.abi, wallet);
  }
  const factory = new ContractFactory(art.abi, art.bytecode.object, wallet);
  const deployRequest = await factory.getDeployTransaction(...args);
  const gasLimit = await creditcoin.estimateGas({ ...deployRequest, from: wallet.address });
  const fee = await creditcoin.getFeeData();
  const feePerGas = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const balance = await creditcoin.getBalance(wallet.address);
  const maxCost = gasLimit * feePerGas;
  console.log(`  ${label.padEnd(26)} measured gas ${gasLimit}, max cost ${maxCost} wei, balance ${balance} wei`);
  if (feePerGas === 0n) throw new Error('provider returned no usable gas price');
  if (balance < maxCost) throw new Error(`${label} needs at most ${maxCost} wei but deployer has ${balance}`);
  const c = await factory.deploy(...args, { gasLimit });
  const deploymentTx = c.deploymentTransaction();
  if (!deploymentTx) throw new Error(`${label} deployment transaction was not created`);
  console.log(`  ${label.padEnd(26)} tx ${deploymentTx.hash}`);
  const receipt = await deploymentTx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`${label} deployment reverted`);
  const address = await c.getAddress();
  if (!(await matchesArtifact(address, art))) throw new Error(`${label} deployed code does not match the compiled artifact`);
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

const registryAddress = deployments.creditcoin.registry;
const aggregatorAddress = deployments.creditcoin.aggregatorEthUsd;
if (!registryAddress) throw new Error('creditcoin.registry missing from deployments.json');
if (!aggregatorAddress) throw new Error('creditcoin.aggregatorEthUsd missing from deployments.json');
console.log(`\n  registry  ${registryAddress}`);
console.log(`  chain key ${chainKey} (Sepolia)`);
console.log(`  feeds     ethUsd ${ethUsd.slice(0, 12)}…  backing ${backing.slice(0, 12)}…  issued ${issued.slice(0, 12)}…\n`);

// Ages are in source-chain blocks. The frontier trails the head by roughly 40, so
// anything under that is unreachable; these are chosen well above it.
const PRICE_MAX_AGE = 300n; // about an hour of Sepolia
const RESERVE_MAX_AGE = 900n; // reserves move slowly, so a wider window is honest

const R = artifact('RegistryFeed');
await deploy('feed.aaveBacking', R, () => [registryAddress, chainKey, backing, RESERVE_MAX_AGE, 'WETH backing aWETH']);
await deploy('feed.awethIssued', R, () => [registryAddress, chainKey, issued, RESERVE_MAX_AGE, 'aWETH issued']);

await deploy('ratio.backingOverIssued', artifact('RatioFeed', 'LensComposer.sol'),
  () => [deployed['feed.aaveBacking'], deployed['feed.awethIssued'], 10n ** 18n, 'aWETH backing ratio']);

// 1e18 is exactly covered; below that the reserve does not cover what was issued.
await deploy('ReserveMonitor', artifact('ReserveMonitor'),
  () => [deployed['ratio.backingOverIssued'], 10n ** 18n, 'Aave Sepolia aWETH backing']);

// 150% collateral, 10% liquidation bonus, a price no older than an hour of wall clock.
await deploy('LensMarket', artifact('LensMarket'),
  () => [aggregatorAddress, 15000n, 1000n, 3600n]);

// 5% between updates, and a hard age limit twice the aggregator's.
await deploy('CircuitBreaker', artifact('CircuitBreaker'),
  () => [registryAddress, chainKey, ethUsd, 500n, PRICE_MAX_AGE * 2n]);

await deploy('FeedEscrow', artifact('FeedEscrow'), () => [registryAddress]);

// The governance consumers read a source-chain token that keeps checkpoints.
const VOTES_TOKEN = feedByName('sepolia.lvote.pastVotes').target;
await deploy('VotePort', artifact('VotePort'),
  () => [registryAddress, chainKey, VOTES_TOKEN, '0x3a46b1a8', 5000n]);
await deploy('SnapshotProver', artifact('SnapshotProver'),
  () => [registryAddress, chainKey, 5000n]);

if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

writeFileSync(new URL('../docs/evidence/deployments.json', import.meta.url), JSON.stringify(deployed, null, 2) + '\n');
console.log(`\n  written to docs/evidence/deployments.json\n`);
const nextDeployments = {
  ...deployments,
  creditcoin: {
    ...deployments.creditcoin,
    reserveMonitor: deployed.ReserveMonitor,
    market: deployed.LensMarket,
    breaker: deployed.CircuitBreaker,
    escrow: deployed.FeedEscrow,
    votePort: deployed.VotePort,
    snapshotProver: deployed.SnapshotProver,
  },
};
writeFileSync(new URL('../deployments.json', import.meta.url), JSON.stringify(nextDeployments, null, 2) + '\n');
console.log('  dependent addresses written to deployments.json\n');
