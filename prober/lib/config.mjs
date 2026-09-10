/**
 * Shared configuration for the prober: environment, providers, contracts and feeds.
 *
 * Chain keys are never written down as constants here. They are resolved from the
 * ChainInfo precompile against the native chain id, because a key is an identifier
 * local to one Attestcoin environment and the same integer means a different chain
 * elsewhere. Everything downstream asks this module for a key rather than assuming one.
 */
import { readFileSync } from 'node:fs';
import { JsonRpcProvider, Wallet, Contract, Interface, AbiCoder, keccak256, toUtf8String } from 'ethers';
import chainInfoAbi from '@gluwa/usc-sdk/dist/chain-info/chain_info.json' with { type: 'json' };

const root = new URL('../../', import.meta.url);

export const env = Object.fromEntries(
  readFileSync(new URL('.env', root), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

export const CHAIN_INFO = '0x0000000000000000000000000000000000000fd3';

export const artifacts = {
  registry: JSON.parse(readFileSync(new URL('out/LensRegistry.sol/LensRegistry.json', root))),
  probe: JSON.parse(readFileSync(new URL('out/StateProbe.sol/StateProbe.json', root))),
};

export const addresses = {
  registry: env.LENS_REGISTRY,
  probe: env.LENS_PROBE,
  aggregator: env.LENS_AGGREGATOR_ETHUSD,
};

export const creditcoin = new JsonRpcProvider(env.CC3_TESTNET_RPC, undefined, { staticNetwork: true });

/** Source chains, keyed by native chain id — the only environment-independent name. */
export const sources = {
  11155111: { label: 'Ethereum Sepolia', rpc: env.SEPOLIA_RPC },
  1: { label: 'Ethereum mainnet', rpc: env.ETHEREUM_RPC },
};

export function sourceProvider(chainId) {
  const s = sources[chainId];
  if (!s?.rpc) throw new Error(`no RPC configured for chain id ${chainId}`);
  return new JsonRpcProvider(s.rpc, undefined, { staticNetwork: true });
}

export function proberWallet(chainId) {
  return new Wallet(env.PROBER_PRIVATE_KEY, sourceProvider(chainId));
}

export function creditcoinWallet() {
  return new Wallet(env.CC3_PRIVATE_KEY, creditcoin);
}

export function registryContract(runner = creditcoin) {
  if (!addresses.registry) throw new Error('LENS_REGISTRY missing from .env');
  return new Contract(addresses.registry, artifacts.registry.abi, runner);
}

export function probeContract(chainId, runner) {
  if (!addresses.probe) throw new Error('LENS_PROBE missing from .env');
  return new Contract(addresses.probe, artifacts.probe.abi, runner ?? sourceProvider(chainId));
}

let chainCache = null;

/** Every chain this Creditcoin environment attests, read from the precompile. */
export async function supportedChains() {
  if (chainCache) return chainCache;
  const raw = await new Contract(CHAIN_INFO, chainInfoAbi, creditcoin).get_supported_chains();
  chainCache = raw.map((c) => ({
    chainKey: Number(c[0]),
    chainId: Number(c[1]),
    chainName: toUtf8String(c[2]), // ABI type is bytes, despite the SDK typing it string
  }));
  return chainCache;
}

/** The key this environment uses for a native chain id. Throws rather than defaulting. */
export async function chainKeyFor(chainId) {
  const found = (await supportedChains()).find((c) => c.chainId === Number(chainId));
  if (!found) throw new Error(`chain id ${chainId} is not attested on this environment`);
  return found.chainKey;
}

const coder = AbiCoder.defaultAbiCoder();

/** Must match LensRegistry.feedId exactly: keccak256(abi.encode(chainKey, target, keccak256(data))). */
export function computeFeedId(chainKey, target, callData) {
  return keccak256(coder.encode(['uint64', 'address', 'bytes32'], [chainKey, target, keccak256(callData)]));
}

/**
 * The feeds this prober maintains.
 *
 * Every one is either time-averaged or a slowly-moving accumulator, because the
 * attestation frontier trails the source head by roughly eight minutes and a feed is
 * only honest if its meaning survives that lag.
 */
export const feeds = [
  {
    name: 'sepolia.weth.totalSupply',
    chainId: 11155111,
    target: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    signature: 'function totalSupply() view returns (uint256)',
    args: [],
    describe: (v) => `${(Number(v) / 1e18).toLocaleString()} WETH`,
  },
  {
    // Aave V3 on Sepolia: the WETH actually held against the aWETH issued against it.
    // A genuine backing relationship rather than an invented one, which is what makes
    // the solvency ratio worth publishing.
    name: 'sepolia.aave.wethBacking',
    chainId: 11155111,
    target: '0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c', // WETH used by Aave on Sepolia
    signature: 'function balanceOf(address) view returns (uint256)',
    args: ['0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830'], // the aWETH token
    describe: (v) => `${(Number(v) / 1e18).toLocaleString()} WETH held as backing`,
  },
  {
    name: 'sepolia.aave.awethIssued',
    chainId: 11155111,
    target: '0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830',
    signature: 'function totalSupply() view returns (uint256)',
    args: [],
    describe: (v) => `${(Number(v) / 1e18).toLocaleString()} aWETH issued`,
  },
  {
    // The governance read VotePort needs: a holder's checkpointed weight at a past
    // block. The block is part of the calldata, so it is part of the feed identity.
    name: 'sepolia.lvote.pastVotes',
    chainId: 11155111,
    target: '0x99E1749Fd45Bb14CF59139b04Cc387981f3ef66e',
    signature: 'function getPastVotes(address,uint256) view returns (uint256)',
    args: ['0xcf7a68bF1585c36F0Cc0077Ce16888F6388FC359', 11676782],
    describe: (v) => `${(Number(v) / 1e18).toLocaleString()} LVOTE of voting weight`,
  },
  {
    name: 'sepolia.chainlink.ethUsd',
    chainId: 11155111,
    target: '0x694AA1769357215DE4FAC081bf1f309aDC325306',
    signature: 'function latestAnswer() view returns (int256)',
    args: [],
    describe: (v) => `$${(Number(v) / 1e8).toFixed(2)} per ETH`,
  },
];

export function callDataFor(feed) {
  return new Interface([feed.signature]).encodeFunctionData(feed.signature.match(/function (\w+)/)[1], feed.args);
}

export function decodeFor(feed, data) {
  const iface = new Interface([feed.signature]);
  const name = feed.signature.match(/function (\w+)/)[1];
  return iface.decodeFunctionResult(name, data)[0];
}

export function feedByName(name) {
  const f = feeds.find((x) => x.name === name);
  if (!f) throw new Error(`unknown feed "${name}". known: ${feeds.map((x) => x.name).join(', ')}`);
  return f;
}
