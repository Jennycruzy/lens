/**
 * Lens SDK — read verified cross-chain state from Creditcoin.
 *
 * Two things are worth knowing before using this.
 *
 * **Chain keys are environment-local.** The same integer means different chains on
 * different Attestcoin environments: Ethereum mainnet is key 3 on CC3 testnet and key 1
 * on CC3 mainnet, where key 1 on testnet is Sepolia. Nothing here takes a chain key as
 * input. You give a native chain id and the key is resolved from the precompile, so code
 * written against this cannot report the wrong chain's state.
 *
 * **Age is in source-chain blocks.** It is how far behind the attested head of the
 * source chain a value sits — never wall-clock, never a Creditcoin height. A feed is
 * only honest if its meaning survives that lag.
 */
import { Contract, JsonRpcProvider, AbiCoder, Interface, keccak256, toUtf8String } from 'ethers';

export const CHAIN_INFO_PRECOMPILE = '0x0000000000000000000000000000000000000fd3';
export const BLOCK_PROVER_PRECOMPILE = '0x0000000000000000000000000000000000000FD2';

export const REGISTRY_ABI = [
  'function observationOf(bytes32) view returns ((bytes returnData,uint256 probeHeight,uint64 sourceTimestamp,uint64 recordedAt,bool callSucceeded,bool truncated,address prober))',
  'function hasObservation(bytes32) view returns (bool)',
  'function frontierOf(uint64) view returns (uint64)',
  'function feedId(uint64,address,bytes) pure returns (bytes32)',
  'function feedIdFromCallHash(uint64,address,bytes32) pure returns (bytes32)',
  'function chainKeys() view returns (uint64[])',
  'function sourceOf(uint64) view returns ((uint64 chainId,address probe,bool registered))',
  'function PROBED_SIGNATURE() view returns (bytes32)',
  'function MAX_BATCH() view returns (uint256)',
];

const CHAIN_INFO_ABI = [
  'function get_supported_chains() view returns ((uint64 chainKey,uint64 chainId,bytes chainName,uint8 chainEncoding)[])',
  'function get_latest_attestation_height_and_hash(uint64) view returns ((uint64 height,bytes32 hash,bool isAttestation,bool exists))',
  'function get_attestation_genesis_height(uint64) view returns (uint64)',
];

const coder = AbiCoder.defaultAbiCoder();

/** Why a read was refused. A caller that cannot tell these apart cannot react correctly. */
export const Refusal = {
  None: 'none',
  Missing: 'missing', // never proven; ask a prober
  CallReverted: 'call-reverted', // proven, and proven to have failed at the source
  Truncated: 'truncated', // the answer is a prefix and must not be decoded
  Stale: 'stale', // outside the age you allowed
};

export class Lens {
  /**
   * @param {string|JsonRpcProvider} rpcOrProvider Creditcoin RPC, or a provider.
   * @param {string} registryAddress The LensRegistry deployment.
   */
  constructor(rpcOrProvider, registryAddress) {
    this.provider =
      typeof rpcOrProvider === 'string'
        ? new JsonRpcProvider(rpcOrProvider, undefined, { staticNetwork: true })
        : rpcOrProvider;
    this.registry = new Contract(registryAddress, REGISTRY_ABI, this.provider);
    this.chainInfo = new Contract(CHAIN_INFO_PRECOMPILE, CHAIN_INFO_ABI, this.provider);
    this._chains = null;
  }

  /** Every source chain this environment attests, read from the precompile. */
  async supportedChains() {
    if (this._chains) return this._chains;
    const raw = await this.chainInfo.get_supported_chains();
    this._chains = raw.map((c) => ({
      chainKey: Number(c.chainKey),
      chainId: Number(c.chainId),
      // The ABI type is `bytes`, despite the upstream SDK typing it `string`.
      chainName: toUtf8String(c.chainName),
    }));
    return this._chains;
  }

  /**
   * The key this environment uses for a native chain id.
   * @throws if the chain is not attested here, rather than defaulting to something.
   */
  async chainKeyFor(chainId) {
    const found = (await this.supportedChains()).find((c) => c.chainId === Number(chainId));
    if (!found) throw new Error(`chain id ${chainId} is not attested on this environment`);
    return found.chainKey;
  }

  /**
   * The identifier of a feed: one chain, one target, one exact call.
   * Computed locally and identical to what the registry computes.
   */
  async feedId(chainId, target, callData) {
    const chainKey = await this.chainKeyFor(chainId);
    return keccak256(coder.encode(['uint64', 'address', 'bytes32'], [chainKey, target, keccak256(callData)]));
  }

  /** Build the calldata for a feed from a human-readable signature. */
  static callData(signature, args = []) {
    const iface = new Interface([signature.startsWith('function') ? signature : `function ${signature}`]);
    return iface.encodeFunctionData(signature.match(/(\w+)\s*\(/)[1], args);
  }

  static decode(signature, data) {
    const iface = new Interface([signature.startsWith('function') ? signature : `function ${signature}`]);
    return iface.decodeFunctionResult(signature.match(/(\w+)\s*\(/)[1], data);
  }

  /** How far the source chain has been attested. */
  async frontier(chainId) {
    return Number(await this.registry.frontierOf(await this.chainKeyFor(chainId)));
  }

  /**
   * Read a feed, refusing rather than returning anything doubtful.
   *
   * @param {number} maxAgeBlocks Largest acceptable age, in blocks of the source chain.
   * @returns {{ok: boolean, refusal: string, data?: string, age: number, observation?: object}}
   *   `data` is present only when `ok`. A refused read never carries a value, so it
   *   cannot be used by accident.
   */
  async read(chainId, target, callData, maxAgeBlocks) {
    const id = await this.feedId(chainId, target, callData);
    if (!(await this.registry.hasObservation(id))) {
      return { ok: false, refusal: Refusal.Missing, age: Infinity, feedId: id };
    }

    const o = await this.registry.observationOf(id);
    const observation = {
      returnData: o.returnData,
      probeHeight: Number(o.probeHeight),
      sourceTimestamp: Number(o.sourceTimestamp),
      recordedAt: Number(o.recordedAt),
      callSucceeded: o.callSucceeded,
      truncated: o.truncated,
      prober: o.prober,
    };

    if (!observation.callSucceeded) {
      return { ok: false, refusal: Refusal.CallReverted, age: 0, feedId: id, observation };
    }
    if (observation.truncated) {
      return { ok: false, refusal: Refusal.Truncated, age: 0, feedId: id, observation };
    }

    const frontier = await this.frontier(chainId);
    // Clamped: a reorg can rewind the frontier below a recorded height.
    const age = frontier > observation.probeHeight ? frontier - observation.probeHeight : 0;
    if (maxAgeBlocks !== undefined && age > maxAgeBlocks) {
      return { ok: false, refusal: Refusal.Stale, age, feedId: id, observation };
    }

    return { ok: true, refusal: Refusal.None, data: observation.returnData, age, feedId: id, observation };
  }

  /** Read and decode in one step, throwing on refusal. */
  async readValue(chainId, target, signature, args, maxAgeBlocks) {
    const callData = Lens.callData(signature, args);
    const result = await this.read(chainId, target, callData, maxAgeBlocks);
    if (!result.ok) {
      throw new Error(`Lens refused this feed: ${result.refusal} (age ${result.age})`);
    }
    return Lens.decode(signature, result.data)[0];
  }

  /**
   * Check a value against the contract that produced it.
   *
   * This is the claim Lens rests on, and it is offered as a function so an integrator can
   * check it themselves rather than take it on trust.
   */
  async verify(chainId, target, callData, sourceRpc) {
    const result = await this.read(chainId, target, callData);
    if (!result.ok) return { verified: false, reason: result.refusal };

    const provider = new JsonRpcProvider(sourceRpc, undefined, { staticNetwork: true });
    const onSource = await provider.call({
      to: target,
      data: callData,
      blockTag: result.observation.probeHeight,
    });
    return {
      verified: onSource === result.data,
      onLens: result.data,
      onSource,
      atHeight: result.observation.probeHeight,
    };
  }
}

export default Lens;
