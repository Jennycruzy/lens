/**
 * Generates web/config.js from the prober's feed definitions and .env.
 *
 *   node tools/build-web-config.mjs [--check]
 *
 * The page used to carry its own copy of the feed list, and the two drifted: three feeds
 * were live and proven while the page showed five of eight. A second list of the same
 * facts will always drift, so there is now one list and this derives the other.
 *
 * `--check` exits non-zero if the committed file is stale, so CI can catch the drift
 * rather than a reader noticing it.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { feeds, callDataFor, env, sources, addresses, deployments, publicArchiveRpcs } from '../prober/lib/config.mjs';

const OUT = new URL('../web/config.js', import.meta.url);

/** How a feed's raw bytes become something a person can read, per feed class. */
function decoderFor(feed) {
  const sig = feed.signature;
  // Dynamic returns first: observe() returns two arrays, and its name contains "ethUsd",
  // so the price decoder must not get a chance to read 256 bytes as one number.
  if (/\[\]/.test(sig)) {
    return `(hex) => {
        const words = (hex.length - 2) / 64;
        const at = (i) => BigInt('0x' + hex.slice(2 + i * 64, 2 + (i + 1) * 64));
        const signed = (v) => (v >= 2n ** 255n ? v - 2n ** 256n : v);
        // Layout: two offsets, then [len, a0, a1], then [len, b0, b1].
        if (words >= 6) return \`tick cumulatives \${signed(at(3))}, \${signed(at(4))} · \${words * 32} bytes, two arrays\`;
        return \`\${words * 32} bytes, two dynamic arrays\`;
      }`;
  }
  if (/bool/.test(sig)) {
    return `(hex) => BigInt(hex) === 1n ? 'true (proven)' : 'false (proven)'`;
  }
  if (feed.name.includes('chainlink')) {
    return `(hex) => \`$\${(Number(BigInt(hex)) / 1e8).toFixed(2)} per ETH\``;
  }
  if (feed.name.includes('steth')) {
    return `(hex) => \`\${(Number(BigInt(hex)) / 1e18).toFixed(9)} ETH per share\``;
  }
  if (feed.name.includes('pastVotes')) {
    return `(hex) => \`\${(Number(BigInt(hex)) / 1e18).toLocaleString()} LVOTE\``;
  }
  if (feed.name.includes('pastSupply')) {
    return `(hex) => \`\${(Number(BigInt(hex)) / 1e18).toLocaleString()} ENS\``;
  }
  const unit = feed.name.includes('aweth') ? 'aWETH' : 'WETH';
  return `(hex) => \`\${(Number(BigInt(hex)) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 3 })} ${unit}\``;
}

/** One line per feed for the page. Titles are what a reader sees; notes say why it matters. */
const TITLES = {
  'sepolia.weth.totalSupply': 'WETH total supply',
  'sepolia.aave.wethBacking': 'Aave WETH backing',
  'sepolia.aave.awethIssued': 'Aave aWETH issued',
  'sepolia.lvote.pastVotes': 'Voting weight at a past block',
  'sepolia.chainlink.ethUsd': 'Chainlink ETH/USD, carried',
  'sepolia.aave.isPoolAdmin': 'Aave pool admin role',
  'sepolia.aave.isPoolAdminStranger': 'Aave pool admin role, a stranger',
  'mainnet.steth.rate': 'stETH exchange rate',
  'mainnet.ens.pastSupply': 'ENS voting supply at a past block',
  'mainnet.uniswap.ethUsdcTwap': 'Uniswap ETH/USDC 30-minute observation',
};
const NOTES = {
  'sepolia.weth.totalSupply': 'an ordinary ERC-20 read',
  'sepolia.aave.wethBacking': 'WETH actually held against the aWETH issued',
  'sepolia.aave.awethIssued': 'the other leg of the backing ratio',
  'sepolia.lvote.pastVotes': 'a checkpointed value, read from the contract that keeps it',
  'sepolia.chainlink.ethUsd': 'the original feed\u2019s trust stays; only the cross-chain reporter is gone',
  'sepolia.aave.isPoolAdmin': 'a proven true',
  'sepolia.aave.isPoolAdminStranger': 'a proven false — different from never checked',
  'mainnet.steth.rate': 'a real Ethereum mainnet value, on a testnet deployment',
  'mainnet.ens.pastSupply': 'ENS answering about its own past, at a fixed block',
  'mainnet.uniswap.ethUsdcTwap': 'observe([1800, 0]) returns TWAP inputs, not a price',
};
/** Which feeds the page puts first, in this order; the rest sit in the full table. */
const FEATURED = ['mainnet.steth.rate', 'mainnet.ens.pastSupply', 'sepolia.aave.wethBacking', 'sepolia.aave.isPoolAdmin'];
const CLASS = {
  'sepolia.weth.totalSupply': 'supply',
  'sepolia.aave.wethBacking': 'reserves',
  'sepolia.aave.awethIssued': 'supply',
  'sepolia.lvote.pastVotes': 'historical',
  'sepolia.chainlink.ethUsd': 'carried feed',
  'sepolia.aave.isPoolAdmin': 'role',
  'sepolia.aave.isPoolAdminStranger': 'role',
  'mainnet.steth.rate': 'exchange rate',
  'mainnet.ens.pastSupply': 'historical',
  'mainnet.uniswap.ethUsdcTwap': 'TWAP inputs',
};

const feedEntries = feeds
  .map((f) => `    {
      name: ${JSON.stringify(f.name)},
      title: ${JSON.stringify(TITLES[f.name] ?? f.name)},
      note: ${JSON.stringify(NOTES[f.name] ?? '')},
      kind: ${JSON.stringify(CLASS[f.name] ?? 'state')},
      featured: ${FEATURED.indexOf(f.name) + 1 || false},
      chainId: ${f.chainId},
      target: '${f.target}',
      signature: ${JSON.stringify(f.signature.replace(/^function /, ''))},
      calldata: '${callDataFor(f)}',
      decode: ${decoderFor(f)},
    },`)
    .join('\n');

const generated = `// GENERATED by tools/build-web-config.mjs — do not edit by hand.
//
// The page once carried its own copy of the feed list and the two drifted, so three live
// feeds were missing from it. There is one list now, in prober/lib/config.mjs, and this
// file is derived from it. Run \`node tools/build-web-config.mjs\` after changing a feed.
window.LENS = {
  creditcoinRpc: '${env.CC3_TESTNET_RPC || 'https://rpc.cc3-testnet.creditcoin.network'}',
  explorer: 'https://creditcoin-testnet.blockscout.com',
  registry: '${addresses.registry}',
  aggregator: '${addresses.aggregator}',
  reserveMonitor: '${addresses.reserveMonitor}',
  market: '${addresses.market}',
  votePort: '${addresses.votePort}',
  snapshotProver: '${addresses.snapshotProver}',
  breaker: '${addresses.breaker}',
  escrow: '${addresses.escrow}',

  // Source chains, keyed by native chain id. Chain keys are resolved at runtime from the
  // precompile and never written down: the same integer means a different chain on a
  // different Attestcoin environment.
  sources: {
${Object.entries(sources)
  .map(([id, s]) => `    ${id}: {
      label: ${JSON.stringify(s.label)},
      rpc: '${s.rpc}',
      explorer: '${id === '1' ? 'https://etherscan.io' : 'https://sepolia.etherscan.io'}',
      probe: '${deployments.sources[id]?.probe ?? ''}',
      // Public endpoints that serve historical state, tried in order when the main one
      // declines a past block. None needs a key.
      archiveRpcs: ${JSON.stringify(publicArchiveRpcs[id] ?? [])},
    },`)
  .join('\n')}
  },

  feeds: [
${feedEntries}
  ],
};
`;

if (process.argv.includes('--check')) {
  const current = readFileSync(OUT, 'utf8');
  if (current !== generated) {
    console.error('web/config.js is stale; run: node tools/build-web-config.mjs');
    process.exit(1);
  }
  console.log('web/config.js is up to date');
  process.exit(0);
}

writeFileSync(OUT, generated);
console.log(`wrote web/config.js with ${feeds.length} feed(s)`);
