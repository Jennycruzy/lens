/**
 * Deploys StateProbe separately to each source chain and records the addresses.
 *
 *   node tools/deploy-probes.mjs [--chain <chain-id>] [--broadcast]
 *
 * A registry binds each environment-local chain key to an emitter address. The
 * addresses therefore belong in deployments.json, not in a single shared variable.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { ContractFactory } from 'ethers';
import {
  env, deployments, proberWallet, sourceProvider,
} from '../prober/lib/config.mjs';

const broadcast = process.argv.includes('--broadcast');
const chainIndex = process.argv.indexOf('--chain');
const chainIds = chainIndex === -1 ? [1, 11155111] : [Number(process.argv[chainIndex + 1])];
if (chainIds.some((chainId) => !Number.isSafeInteger(chainId) || ![1, 11155111].includes(chainId))) {
  throw new Error('source chain must be 1 (Ethereum mainnet) or 11155111 (Sepolia)');
}

let artifact;
try {
  artifact = JSON.parse(readFileSync(new URL('../out/StateProbe.sol/StateProbe.json', import.meta.url)));
} catch {
  console.error('\n  no compiled artifact. Run: forge build\n');
  process.exit(2);
}

const updates = {};
const persist = () => {
  const nextDeployments = { ...deployments, sources: { ...deployments.sources } };
  for (const [sourceChainId, probe] of Object.entries(updates)) {
    nextDeployments.sources[sourceChainId] = { ...nextDeployments.sources[sourceChainId], probe };
  }
  writeFileSync(new URL('../deployments.json', import.meta.url), JSON.stringify(nextDeployments, null, 2) + '\n');
};

for (const chainId of chainIds) {
  const provider = sourceProvider(chainId);
  const wallet = proberWallet(chainId);
  const network = await provider.getNetwork();
  if (network.chainId !== BigInt(chainId)) throw new Error('RPC chain id ' + network.chainId + ' does not match requested source ' + chainId);
  const balance = await provider.getBalance(wallet.address);
  const fee = await provider.getFeeData();
  const gwei = Number(fee.gasPrice ?? 0n) / 1e9;
  console.log('  ' + (chainId === 1 ? 'Ethereum mainnet' : 'Ethereum Sepolia') + '  deployer ' + wallet.address);
  console.log('    balance ' + balance + ' wei, gas ' + gwei + ' gwei');
  const ceiling = Number(env['MAX_GAS_GWEI_' + chainId] ?? (chainId === 1 ? 20 : Number.POSITIVE_INFINITY));
  const factory = new ContractFactory(artifact.abi, artifact.bytecode.object, wallet);
  const deployRequest = await factory.getDeployTransaction();
  const gasLimit = await provider.estimateGas({ ...deployRequest, from: wallet.address });
  const feePerGas = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const maxCost = gasLimit * feePerGas;
  console.log('    estimated gas ' + gasLimit + ', max cost ' + maxCost + ' wei');

  const configured = env['LENS_PROBE_' + chainId] || deployments.sources[String(chainId)]?.probe;
  const runtime = artifact.deployedBytecode?.object?.toLowerCase();
  let alreadyCurrent = false;
  if (configured) {
    const code = await provider.getCode(configured);
    alreadyCurrent = Boolean(runtime) && code.toLowerCase() === runtime;
    console.log('    configured probe ' + configured + ' — ' + (alreadyCurrent ? 'matches artifact' : code === '0x' ? 'no code' : 'stale artifact'));
  }
  if (alreadyCurrent) {
    updates[String(chainId)] = configured;
    continue;
  }
  if (!broadcast) continue;
  if (gwei > ceiling) throw new Error('gas ' + gwei + ' gwei exceeds MAX_GAS_GWEI_' + chainId + '=' + ceiling);
  if (balance < maxCost) throw new Error('balance ' + balance + ' is below estimated maximum deployment cost ' + maxCost);
  if (feePerGas === 0n) throw new Error('provider returned no usable gas price');

  const probe = await factory.deploy({ gasLimit });
  const deploymentTx = probe.deploymentTransaction();
  if (!deploymentTx) throw new Error('deployment transaction was not created');
  console.log('    deployment tx ' + deploymentTx.hash);
  const receipt = await deploymentTx.wait();
  if (!receipt || receipt.status !== 1) throw new Error('probe deployment reverted');
  const address = await probe.getAddress();
  if ((await provider.getCode(address)) === '0x') throw new Error('no code at deployed probe ' + address);
  updates[String(chainId)] = address;
  console.log('    probe ' + address);
  persist();
}

if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

persist();
console.log('\n  probe addresses written to deployments.json\n');
