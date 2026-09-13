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
import { proofProvider as uscProofProvider, chainInfo as uscChainInfo } from '@gluwa/usc-sdk';

const root = new URL('../../', import.meta.url);

export const env = Object.fromEntries(
  readFileSync(new URL('.env', root), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

export const CHAIN_INFO = '0x0000000000000000000000000000000000000fd3';

/**
 * Compiled artifacts, loaded on first use rather than on import.
 *
 * Loading them eagerly meant every tool died on a clean clone before `forge build`, with
 * a stack trace about a missing JSON file — including the tools that never touch an
 * artifact. Now only the tools that need one pay for it, and the error says what to do.
 */
const artifactCache = {};
const loadArtifact = (name) => {
  if (artifactCache[name]) return artifactCache[name];
  const path = new URL(`out/${name}.sol/${name}.json`, root);
  try {
    artifactCache[name] = JSON.parse(readFileSync(path));
  } catch {
    throw new Error(`no compiled artifact for ${name}. Run: forge build`);
  }
  return artifactCache[name];
};

export const artifacts = {
  get registry() {
    return loadArtifact('LensRegistry');
  },
  get probe() {
    return loadArtifact('StateProbe');
  },
};

/**
 * Deployed addresses come from a committed file, not from .env.
 *
 * They are public facts about a public chain, so keeping them in .env meant a clean clone
 * had none of them and anything derived from them differed from what was committed. .env
 * still wins where it sets one, which is how a fork points at its own deployment.
 */
export const deployments = JSON.parse(readFileSync(new URL('deployments.json', root), 'utf8'));

export const addresses = {
  registry: env.LENS_REGISTRY || deployments.creditcoin.registry,
  probe: env.LENS_PROBE || deployments.sources['11155111']?.probe,
  aggregator: env.LENS_AGGREGATOR_ETHUSD || deployments.creditcoin.aggregatorEthUsd,
  reserveMonitor: env.LENS_RESERVE_MONITOR || deployments.creditcoin.reserveMonitor,
  market: env.LENS_MARKET || deployments.creditcoin.market,
  votePort: env.LENS_VOTEPORT || deployments.creditcoin.votePort,
  snapshotProver: env.LENS_SNAPSHOT || deployments.creditcoin.snapshotProver,
  breaker: env.LENS_BREAKER || deployments.creditcoin.breaker,
  escrow: env.LENS_ESCROW || deployments.creditcoin.escrow,
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

/** Uses the configured archive endpoint only for historical comparisons. */
export function historicalProvider(chainId) {
  const s = sources[chainId];
  const rpc = Number(chainId) === 1 ? (env.ETHEREUM_ARCHIVE_RPC || s?.rpc) : s?.rpc;
  if (!s || !rpc) throw new Error(`no historical RPC configured for chain id ${chainId}`);
  return new JsonRpcProvider(rpc, undefined, { staticNetwork: true });
}

export function proberWallet(chainId) {
  return new Wallet(env.PROBER_PRIVATE_KEY, sourceProvider(chainId));
}

export function creditcoinWallet() {
  return new Wallet(env.CC3_PRIVATE_KEY, creditcoin);
}

export function probeAddress(chainId) {
  const address = env[`LENS_PROBE_${chainId}`] || deployments.sources[String(chainId)]?.probe || env.LENS_PROBE;
  if (!address) throw new Error(`LENS_PROBE_${chainId} missing from .env/deployments.json`);
  return address;
}

export function proofBuilderHosts() {
  return [...new Set([
    env.PROOF_BUILDER_URL,
    env.PROOF_BUILDER_FALLBACK_URL,
    env.PROOF_BUILDER_LOCAL_URL,
  ].filter(Boolean))];
}

const localBuilders = new Map();

export function localProofBuilder(chainId, chainKey) {
  const cacheKey = chainId + ':' + chainKey;
  if (!localBuilders.has(cacheKey)) {
    const blockProvider = new uscProofProvider.raw.blockProvider.SimpleBlockProvider(sourceProvider(chainId));
    const chainInfoProvider = new uscChainInfo.PrecompileChainInfoProvider(creditcoin, CHAIN_INFO);
    localBuilders.set(cacheKey, new uscProofProvider.raw.RawProofBuilder(
      chainKey, blockProvider, chainInfoProvider, uscProofProvider.raw.EncodingVersion.V1,
    ));
  }
  return localBuilders.get(cacheKey);
}

export async function builderAttestedHeight(chainKey) {
  let height = 0;
  const attempts = [];
  try {
    const latest = await new Contract(CHAIN_INFO, chainInfoAbi, creditcoin).get_latest_attestation_height_and_hash(chainKey);
    const observed = latest.exists ? Number(latest.height) : 0;
    if (Number.isFinite(observed)) height = Math.max(height, observed);
    attempts.push({ host: 'local-sdk', status: 'on-chain', height: observed });
  } catch (e) {
    attempts.push({ host: 'local-sdk', status: 'unreachable', error: e.message });
  }
  for (const host of proofBuilderHosts()) {
    try {
      const response = await fetch(`${host}/api/v1/attested-height/${chainKey}`, {
        signal: AbortSignal.timeout(12000),
      });
      if (!response.ok) {
        attempts.push({
          host,
          status: response.status,
          kind: response.status === 404 ? 'not-found' : response.status === 422 ? 'unprocessable' : 'http',
        });
        continue;
      }
      const body = await response.json();
      const observed = Number(body.attestedHeight ?? body.data?.attestedHeight ?? body.height ?? 0);
      if (Number.isFinite(observed)) height = Math.max(height, observed);
      attempts.push({ host, status: response.status, height: observed });
    } catch (e) {
      attempts.push({ host, status: 'unreachable', error: e.message });
    }
  }
  return { height, attempts };
}

export function registryContract(runner = creditcoin) {
  if (!addresses.registry) throw new Error('LENS_REGISTRY missing from .env');
  return new Contract(addresses.registry, artifacts.registry.abi, runner);
}

export function probeContract(chainId, runner) {
  return new Contract(probeAddress(chainId), artifacts.probe.abi, runner ?? sourceProvider(chainId));
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
  {
    // Access and compliance: who holds a privileged role on the source chain. Every RWA
    // and permissioned-asset design on Creditcoin needs this shape and none can get it
    // today. Aave's ACLManager on Sepolia is a real deployment with real role holders.
    name: 'sepolia.aave.isPoolAdmin',
    chainId: 11155111,
    target: '0x7F2bE3b178deeFF716CD6Ff03Ef79A1dFf360ddD',
    signature: 'function isPoolAdmin(address) view returns (bool)',
    args: ['0xfA0e305E0f46AB04f00ae6b5f4560d61a2183E00'],
    describe: (v) => (v ? 'holds pool admin' : 'does not hold pool admin'),
  },
  {
    // The same question about an address that holds nothing. A feed whose honest answer
    // is false is worth proving too: a consumer must be able to tell "not authorised"
    // apart from "never checked", and only a proven false does that.
    name: 'sepolia.aave.isPoolAdminStranger',
    chainId: 11155111,
    target: '0x7F2bE3b178deeFF716CD6Ff03Ef79A1dFf360ddD',
    signature: 'function isPoolAdmin(address) view returns (bool)',
    args: ['0x000000000000000000000000000000000000dEaD'],
    describe: (v) => (v ? 'holds pool admin' : 'does not hold pool admin'),
  },

  // --- Ethereum mainnet, chain key 3 on CC3 testnet -------------------------
  // The reason a testnet deployment is worth anything: these are real mainnet
  // values, proven onto a testnet, because CC3 testnet attests Ethereum.
  {
    name: 'mainnet.steth.rate',
    chainId: 1,
    target: '0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84',
    signature: 'function getPooledEthByShares(uint256) view returns (uint256)',
    args: ['1000000000000000000'],
    describe: (v) => `${(Number(v) / 1e18).toFixed(9)} ETH per stETH share`,
  },
  {
    // Historical state with no storage proof: ENS answers about its own past.
    name: 'mainnet.ens.pastSupply',
    chainId: 1,
    target: '0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72',
    signature: 'function getPastTotalSupply(uint256) view returns (uint256)',
    args: [25948230],
    describe: (v) => `${(Number(v) / 1e18).toLocaleString()} ENS voting supply`,
  },
  {
    // A variable-length return: two dynamic arrays. This is the shape that tests
    // how much data survives the proof path, and it is the feed class the lag
    // was designed around, since a thirty-minute average read late is still one.
    name: 'mainnet.uniswap.ethUsdcTwap',
    chainId: 1,
    target: '0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640',
    signature: 'function observe(uint32[]) view returns (int56[], uint160[])',
    args: [[1800, 0]],
    describe: (v) => `tick cumulatives ${v[0]}, ${v[1]}`,
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
