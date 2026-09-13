/**
 * Deploys LensRegistry to Creditcoin.
 *
 *   node tools/deploy-registry.mjs [--broadcast]
 *
 * Without --broadcast this resolves and prints what it would deploy, and sends nothing.
 *
 * This is a script rather than a `forge script` for two reasons, both properties of
 * pallet-evm rather than choices:
 *
 *   - Creditcoin's precompiles are native code with no bytecode, so a local EVM fork
 *     cannot execute them. A `forge script` that reads ChainInfo reverts with
 *     "call to non-contract address 0x...fD3" before it ever reaches the network.
 *   - CC3 block headers carry no `prevrandao`, which Foundry's header validation
 *     requires from Paris onward.
 *
 * The transaction therefore goes to the node, where the precompiles exist. The chain
 * keys are resolved from ChainInfo on that same node first, so the arguments are
 * derived from the environment being deployed to rather than written down here.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { JsonRpcProvider, Wallet, ContractFactory, Contract, toUtf8String } from 'ethers';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };

/** Reads a compiled artifact, and says what to do when the project has not been built. */
function readArtifact(url) {
  try {
    return JSON.parse(readFileSync(url));
  } catch {
    console.error('\n  no compiled artifact. Run: forge build\n');
    process.exit(2);
  }
}


const env = Object.fromEntries(
  readFileSync(new URL('../.env', import.meta.url), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

const deployments = JSON.parse(readFileSync(new URL('../deployments.json', import.meta.url), 'utf8'));
const CHAIN_INFO = '0x0000000000000000000000000000000000000fd3';
// Probe addresses are facts per source chain. A single address is only a fallback for
// deployments made at the same nonce on both chains.
const probeFor = (chainId) => env[`LENS_PROBE_${chainId}`] || deployments.sources[String(chainId)]?.probe || env.LENS_PROBE;

// The native chain ids we want, never the keys. Keys are environment-local.
const WANTED = [
  { chainId: 1n, label: 'Ethereum mainnet' },
  { chainId: 11155111n, label: 'Ethereum Sepolia' },
];

const broadcast = process.argv.includes('--broadcast');
const artifact = readArtifact(new URL('../out/LensRegistry.sol/LensRegistry.json', import.meta.url));

const provider = new JsonRpcProvider(env.CC3_TESTNET_RPC, undefined, { staticNetwork: true });
const expectedCreditcoinChainId = BigInt(env.CC3_CHAIN_ID ?? 102031);
const actualCreditcoinChainId = (await provider.getNetwork()).chainId;
if (actualCreditcoinChainId !== expectedCreditcoinChainId) throw new Error('RPC chain id ' + actualCreditcoinChainId + ' does not match CC3 testnet ' + expectedCreditcoinChainId);
const wallet = new Wallet(env.CC3_PRIVATE_KEY, provider);

const chainInfo = new Contract(CHAIN_INFO, chainInfoAbi, provider);
const supported = (await chainInfo.get_supported_chains()).map((c) => ({
  chainKey: c[0],
  chainId: c[1],
  chainName: toUtf8String(c[2]),
}));

const keys = [];
const ids = [];
const probes = [];
for (const want of WANTED) {
  const found = supported.find((c) => c.chainId === want.chainId);
  if (!found) throw new Error(`${want.label} (chain id ${want.chainId}) is not attested on this environment`);
  const probe = probeFor(want.chainId);
  if (!probe) throw new Error(`no probe address for source chain ${want.chainId}; deploy it first`);
  console.log(`  ${want.label.padEnd(18)} chain id ${String(found.chainId).padEnd(9)} -> key ${found.chainKey}  "${found.chainName}"`);
  keys.push(found.chainKey);
  ids.push(found.chainId);
  probes.push(probe);
}

console.log(`\n  deployer ${wallet.address}`);
console.log(`  probes   ${probes.join(", ")}`);
const balance = await provider.getBalance(wallet.address);
const fee = await provider.getFeeData();
const feePerGas = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
const factory = new ContractFactory(artifact.abi, artifact.bytecode.object, wallet);
const deployRequest = await factory.getDeployTransaction(keys, ids, probes);
const gasLimit = await provider.estimateGas({ ...deployRequest, from: wallet.address });
const maxCost = gasLimit * feePerGas;
console.log('  balance  ' + balance + ' wei, estimated gas ' + gasLimit + ', max cost ' + maxCost + ' wei');

if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

if (feePerGas === 0n) throw new Error('provider returned no usable gas price');
if (balance < maxCost) throw new Error('balance ' + balance + ' is below estimated maximum deployment cost ' + maxCost);
const registry = await factory.deploy(keys, ids, probes, { gasLimit });
console.log(`\n  deployment tx ${registry.deploymentTransaction().hash}`);
const deploymentTx = registry.deploymentTransaction();
if (!deploymentTx) throw new Error('deployment transaction was not created');
const receipt = await deploymentTx.wait();
if (!receipt || receipt.status !== 1) throw new Error('registry deployment reverted');
const address = await registry.getAddress();
console.log(`  registry      ${address}`);

// Read the binding back off the chain rather than trusting the arguments we sent.
const deployed = new Contract(address, artifact.abi, provider);
console.log('\n  bindings as the chain reports them:');
for (const key of await deployed.chainKeys()) {
  const s = await deployed.sourceOf(key);
  console.log(`    key ${key} -> chain id ${s.chainId}, probe ${s.probe}`);
}
console.log('');
const nextDeployments = { ...deployments, creditcoin: { ...deployments.creditcoin, registry: address } };
writeFileSync(new URL('../deployments.json', import.meta.url), JSON.stringify(nextDeployments, null, 2) + '\n');
console.log('  registry address written to deployments.json\n');
