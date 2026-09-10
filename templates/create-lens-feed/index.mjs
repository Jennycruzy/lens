#!/usr/bin/env node
/**
 * Scaffold a Lens feed from a chain, a contract and a function.
 *
 *   node templates/create-lens-feed \
 *     --chain 11155111 \
 *     --target 0x694AA1769357215DE4FAC081bf1f309aDC325306 \
 *     --signature 'latestAnswer() returns (int256)' \
 *     --name myProtocol.ethUsd
 *
 * Prints the feed's identifier, the calldata a prober must use, a consumer contract that
 * reads it, and the commands to probe and prove it. Nothing is written unless --write is
 * given, so it is safe to run to find out what a feed would look like.
 *
 * It checks the target answers the call before printing anything, because a feed for a
 * function a contract does not have is a feed that will never have a value.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { JsonRpcProvider, Interface, keccak256, AbiCoder, Contract, toUtf8String } from 'ethers';

const arg = (n, d) => {
  const i = process.argv.indexOf(`--${n}`);
  return i === -1 ? d : process.argv[i + 1];
};

const chainId = Number(arg('chain'));
const target = arg('target');
const signature = arg('signature');
const name = arg('name', 'my.feed');
const args = JSON.parse(arg('args', '[]'));
const maxAge = Number(arg('max-age', 300));
const write = process.argv.includes('--write');

const CREDITCOIN_RPC = arg('creditcoin-rpc', 'https://rpc.cc3-testnet.creditcoin.network');
const REGISTRY = arg('registry', '0x81b6DcbcE28EC0634DC905cfDc5eA84005915852');
const SOURCE_RPC = {
  11155111: 'https://ethereum-sepolia-rpc.publicnode.com',
  1: 'https://ethereum-rpc.publicnode.com',
}[chainId];

if (!chainId || !target || !signature) {
  console.error('usage: --chain <id> --target <address> --signature "fn() returns (type)" [--args \'[]\'] [--name x] [--max-age 300] [--write]');
  process.exit(2);
}
if (!SOURCE_RPC) {
  console.error(`no RPC known for chain ${chainId}; add one to this template`);
  process.exit(2);
}

const fn = signature.startsWith('function') ? signature : `function ${signature}`;
const iface = new Interface([fn]);
const fnName = fn.match(/function\s+(\w+)/)[1];
const callData = iface.encodeFunctionData(fnName, args);

// Resolve the chain key from the precompile. It is environment-local and must never be
// written into a template.
const creditcoin = new JsonRpcProvider(CREDITCOIN_RPC, undefined, { staticNetwork: true });
const chainInfo = new Contract(
  '0x0000000000000000000000000000000000000fd3',
  ['function get_supported_chains() view returns ((uint64 chainKey,uint64 chainId,bytes chainName,uint8 chainEncoding)[])'],
  creditcoin,
);
const chains = await chainInfo.get_supported_chains();
const chain = chains.find((c) => Number(c.chainId) === chainId);
if (!chain) {
  console.error(`chain ${chainId} is not attested by this Creditcoin environment`);
  console.error(`attested here: ${chains.map((c) => `${toUtf8String(c.chainName)} (${c.chainId})`).join(', ')}`);
  process.exit(1);
}
const chainKey = Number(chain.chainKey);

// Does the target actually answer this call? A feed for a function that reverts will
// never hold a value, and finding that out now is cheaper than after a proof cycle.
const source = new JsonRpcProvider(SOURCE_RPC, undefined, { staticNetwork: true });
let sample;
try {
  const raw = await source.call({ to: target, data: callData });
  sample = iface.decodeFunctionResult(fnName, raw)[0];
} catch (e) {
  console.error(`\n  ${target} does not answer ${fnName}: ${e.shortMessage ?? e.message}`);
  console.error('  A feed for a call the target rejects will never hold a value.\n');
  process.exit(1);
}

const feedId = keccak256(
  AbiCoder.defaultAbiCoder().encode(['uint64', 'address', 'bytes32'], [chainKey, target, keccak256(callData)]),
);

const contractName = name.split(/[.\-_]/).map((p) => p[0].toUpperCase() + p.slice(1)).join('') + 'Reader';
const solidity = `// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensConsumer} from "../LensConsumer.sol";
import {LensRegistry} from "../LensRegistry.sol";

/// @notice Reads ${name}: ${fnName} on ${target}, ${toUtf8String(chain.chainName)}.
/// @dev Scaffolded by templates/create-lens-feed. The bound below is in blocks of the
///      source chain; the frontier trails its head by 30 to 40, so anything under about
///      50 can never be satisfied.
contract ${contractName} is LensConsumer {
    /// @dev keccak256(abi.encode(chainKey, target, keccak256(callData)))
    bytes32 public constant FEED_ID = ${feedId};

    uint64 private constant CHAIN_KEY = ${chainKey};
    uint256 public constant MAX_AGE_BLOCKS = ${maxAge};

    constructor(LensRegistry lens) LensConsumer(lens) {}

    function _defaultChainKey() internal pure override returns (uint64) {
        return CHAIN_KEY;
    }

    /// @notice The value, or a revert. There is deliberately no unbounded variant.
    function value() external view returns (uint256) {
        return _latestUint(FEED_ID, MAX_AGE_BLOCKS);
    }

    /// @notice The value, reporting refusal rather than reverting.
    function tryValue() external view returns (bool ok, uint256 v, uint256 ageBlocks) {
        bytes memory data;
        (ok, data, ageBlocks) = _tryLatest(FEED_ID, MAX_AGE_BLOCKS);
        if (ok && data.length == 32) v = abi.decode(data, (uint256));
        else ok = false;
    }
}
`;

console.log(`\n  feed        ${name}`);
console.log(`  chain       ${toUtf8String(chain.chainName)} (id ${chainId}, key ${chainKey} on this environment)`);
console.log(`  target      ${target}`);
console.log(`  call        ${fnName}(${args.join(', ')})`);
console.log(`  calldata    ${callData}`);
console.log(`  feed id     ${feedId}`);
console.log(`  reads now   ${sample}`);
console.log(`  max age     ${maxAge} source blocks (~${Math.round((maxAge * 12) / 60)} min)`);

console.log(`\n  add to prober/lib/config.mjs:\n`);
console.log(`  {
    name: '${name}',
    chainId: ${chainId},
    target: '${target}',
    signature: '${fn}',
    args: ${JSON.stringify(args)},
    describe: (v) => String(v),
  },`);

console.log(`\n  then:\n`);
console.log(`    node prober/probe.mjs ${name}`);
console.log(`    node prober/prove.mjs <tx-hash> ${chainId}`);

if (write) {
  mkdirSync('contracts/src/generated', { recursive: true });
  const path = `contracts/src/generated/${contractName}.sol`;
  writeFileSync(path, solidity);
  console.log(`\n  wrote ${path}\n`);
} else {
  console.log(`\n  consumer contract (re-run with --write to save it):\n`);
  console.log(solidity.split('\n').map((l) => '    ' + l).join('\n'));
}
