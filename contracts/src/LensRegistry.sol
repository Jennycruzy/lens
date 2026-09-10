// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {INativeQueryVerifier, NativeQueryVerifierLib} from
    "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {IChainInfo, ChainInfoLib} from "./interfaces/IChainInfo.sol";

/**
 * @title LensRegistry
 * @notice Accepts proofs that a read happened on a source chain, and records the answer.
 *
 * @dev The precompile proves one thing only: that a transaction was included in a block,
 *      and that the block is really part of the confirmed source chain. Everything else
 *      a consumer needs is this contract's job, and each of the six checks below is a
 *      vulnerability if it is missing.
 *
 *      1. Receipt status. Inclusion is not success. A reverted transaction is still in
 *         its block, and the precompile will happily prove it.
 *      2. Replay. A valid proof stays valid forever, so it is consumed once.
 *      3. Attestation range. A height outside the attested range is rejected in both
 *         directions, not just the future one.
 *      4. Monotonic newest-wins, keyed by source height. An older observation may never
 *         displace a newer one.
 *      5. Chain-key binding. A chain key means different chains in different Attestcoin
 *         environments, so keys are resolved from ChainInfo at construction and asserted
 *         against the native chain id, which is environment-independent.
 *      6. Emitter binding. The log must come from the probe registered for that chain
 *         key. Without this anyone deploys a look-alike emitter and forges every feed.
 *
 *      There is no owner and no pause key. The chain-key table and the probe addresses
 *      are immutable from construction, so there is no privileged operation to protect.
 */
contract LensRegistry {
    using EvmV1Decoder for bytes;

    /// @dev keccak256("Probed(address,bytes32,address,bool,bool,uint256,bytes)")
    bytes32 public constant PROBED_SIGNATURE = 0xcc205dbd77fbafc012eccc26fdeae09611101621c9e62bb7de830d156832dbfe;

    struct Observation {
        bytes returnData;
        uint256 probeHeight;
        uint64 recordedAt;
        bool callSucceeded;
        bool truncated;
        address prober;
    }

    /// @notice A source chain this registry will accept proofs from.
    struct Source {
        uint64 chainId; // native chain id, asserted against ChainInfo at construction
        address probe; // the one StateProbe whose logs count for this chain key
        bool registered;
    }

    INativeQueryVerifier public immutable VERIFIER;
    IChainInfo public immutable CHAIN_INFO;

    mapping(uint64 chainKey => Source) private _sources;
    mapping(bytes32 feedId => Observation) private _observations;
    mapping(bytes32 queryKey => bool) public consumed;

    uint64[] private _chainKeys;

    /// @dev The precompile accepts at most ten queries under one shared continuity proof.
    uint256 public constant MAX_BATCH = 10;

    event ObservationRecorded(
        bytes32 indexed feedId,
        uint64 indexed chainKey,
        address indexed target,
        uint256 probeHeight,
        bool callSucceeded,
        address prober,
        bytes returnData
    );
    event SourceRegistered(uint64 indexed chainKey, uint64 chainId, address probe);

    error NoSources();
    error DuplicateChainKey(uint64 chainKey);
    error ProbeAddressRequired(uint64 chainKey);
    error ChainKeyNotAttested(uint64 chainKey);
    error ChainKeyMeansADifferentChain(uint64 chainKey, uint64 expectedChainId, uint64 actualChainId);
    error UnknownChainKey(uint64 chainKey);
    error QueryAlreadyConsumed(bytes32 queryKey);
    error HeightAboveFrontier(uint64 chainKey, uint64 height, uint64 frontier);
    error HeightBelowAttestationGenesis(uint64 chainKey, uint64 height, uint64 genesis);
    error NothingAttested(uint64 chainKey);
    error ProofRejected();
    error ProbeTransactionReverted(uint8 receiptStatus);
    error NoProbeLogs();
    error ForeignEmitter(address emitter, address expected);
    error MalformedProbeLog();
    error EmittedHeightMismatch(uint256 emitted, uint64 proven);
    error ObservationNotNewer(bytes32 feedId, uint256 incoming, uint256 existing);
    error BatchEmpty();
    error BatchTooLarge(uint256 length, uint256 maximum);
    error BatchLengthMismatch();
    error NoObservation(bytes32 feedId);

    /**
     * @param keys      Attestcoin chain keys this registry accepts.
     * @param chainIds  The native chain id each key is expected to mean.
     * @param probes    The StateProbe deployed on each of those chains.
     *
     * @dev The assertion here is the whole of check 5. A hardcoded key would verify
     *      every proof correctly while reporting the wrong chain, because the proof is
     *      valid — it is simply a proof about somewhere else. Resolving the key through
     *      ChainInfo and comparing the native chain id makes that failure impossible to
     *      deploy: on the wrong environment, construction reverts.
     */
    constructor(uint64[] memory keys, uint64[] memory chainIds, address[] memory probes) {
        VERIFIER = NativeQueryVerifierLib.getVerifier();
        CHAIN_INFO = ChainInfoLib.chainInfo();

        uint256 n = keys.length;
        if (n == 0) revert NoSources();
        if (n != chainIds.length || n != probes.length) revert BatchLengthMismatch();

        for (uint256 i = 0; i < n; ++i) {
            uint64 key = keys[i];
            if (_sources[key].registered) revert DuplicateChainKey(key);
            if (probes[i] == address(0)) revert ProbeAddressRequired(key);

            IChainInfo.ChainInfoResult memory live = CHAIN_INFO.get_chain_by_key(key);
            if (live.chainKey != key || live.chainId == 0) revert ChainKeyNotAttested(key);
            if (live.chainId != chainIds[i]) {
                revert ChainKeyMeansADifferentChain(key, chainIds[i], live.chainId);
            }

            _sources[key] = Source({chainId: live.chainId, probe: probes[i], registered: true});
            _chainKeys.push(key);
            emit SourceRegistered(key, live.chainId, probes[i]);
        }
    }

    /**
     * @notice The identifier of a feed: one chain, one target, one exact call.
     * @dev Calldata is hashed rather than stored, so a feed is pinned to the precise
     *      query. Changing an argument produces a different feed rather than quietly
     *      changing the meaning of an existing one.
     */
    function feedId(uint64 chainKey, address target, bytes calldata data) public pure returns (bytes32) {
        return keccak256(abi.encode(chainKey, target, keccak256(data)));
    }

    function feedIdFromCallHash(uint64 chainKey, address target, bytes32 callHash) public pure returns (bytes32) {
        return keccak256(abi.encode(chainKey, target, callHash));
    }

    /// @notice Prove one probe transaction and record every feed it carries.
    function submitProof(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        INativeQueryVerifier.MerkleProof calldata merkleProof,
        INativeQueryVerifier.ContinuityProof calldata continuityProof
    ) external returns (uint256 recorded) {
        Source memory source = _requireSource(chainKey);
        _requireWithinAttestedRange(chainKey, blockHeight);
        _consumeQuery(chainKey, blockHeight, merkleProof);

        if (!VERIFIER.verifyAndEmit(chainKey, blockHeight, encodedTransaction, merkleProof, continuityProof)) {
            revert ProofRejected();
        }

        return _record(chainKey, blockHeight, encodedTransaction, source.probe);
    }

    /**
     * @notice Prove several probe transactions under one shared continuity proof.
     * @dev This is the path that makes proof cost per feed fall as feed count rises:
     *      one continuity chain is paid for once and amortised across every query in
     *      the batch. All of them must sit on the same chain key and inside the range
     *      that one continuity proof covers.
     */
    function submitBatch(
        uint64 chainKey,
        uint64[] calldata blockHeights,
        bytes[] calldata encodedTransactions,
        INativeQueryVerifier.MerkleProof[] calldata merkleProofs,
        INativeQueryVerifier.ContinuityProof calldata sharedContinuityProof
    ) external returns (uint256 recorded) {
        uint256 n = blockHeights.length;
        if (n == 0) revert BatchEmpty();
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH);
        if (n != encodedTransactions.length || n != merkleProofs.length) revert BatchLengthMismatch();

        Source memory source = _requireSource(chainKey);
        for (uint256 i = 0; i < n; ++i) {
            _requireWithinAttestedRange(chainKey, blockHeights[i]);
            _consumeQuery(chainKey, blockHeights[i], merkleProofs[i]);
        }

        if (!VERIFIER.verifyAndEmit(chainKey, blockHeights, encodedTransactions, merkleProofs, sharedContinuityProof))
        {
            revert ProofRejected();
        }

        for (uint256 i = 0; i < n; ++i) {
            recorded += _record(chainKey, blockHeights[i], encodedTransactions[i], source.probe);
        }
    }

    function observationOf(bytes32 id) external view returns (Observation memory) {
        Observation memory o = _observations[id];
        if (o.probeHeight == 0 && o.recordedAt == 0) revert NoObservation(id);
        return o;
    }

    function hasObservation(bytes32 id) external view returns (bool) {
        return _observations[id].recordedAt != 0;
    }

    /// @notice Highest source-chain height Creditcoin has attested for `chainKey`.
    /// @dev Read live rather than cached. A cached frontier is a stale frontier, and a
    ///      stale frontier is how a consumer is handed an old value it believes is new.
    function frontierOf(uint64 chainKey) public view returns (uint64) {
        _requireSource(chainKey);
        IChainInfo.HeightHash memory latest = CHAIN_INFO.get_latest_attestation_height_and_hash(chainKey);
        if (!latest.exists) revert NothingAttested(chainKey);
        return latest.height;
    }

    function sourceOf(uint64 chainKey) external view returns (Source memory) {
        return _sources[chainKey];
    }

    function chainKeys() external view returns (uint64[] memory) {
        return _chainKeys;
    }

    // -------------------------------------------------------------------------

    function _requireSource(uint64 chainKey) private view returns (Source memory source) {
        source = _sources[chainKey];
        if (!source.registered) revert UnknownChainKey(chainKey);
    }

    /// @dev Check 3. Rejecting only the future half would accept a height below the
    ///      attestation genesis, where no proof can be anchored at all.
    function _requireWithinAttestedRange(uint64 chainKey, uint64 height) private view {
        IChainInfo.HeightHash memory latest = CHAIN_INFO.get_latest_attestation_height_and_hash(chainKey);
        if (!latest.exists) revert NothingAttested(chainKey);
        if (height > latest.height) revert HeightAboveFrontier(chainKey, height, latest.height);

        uint64 genesis = CHAIN_INFO.get_attestation_genesis_height(chainKey);
        if (height < genesis) revert HeightBelowAttestationGenesis(chainKey, height, genesis);
    }

    /// @dev Check 2. The transaction index comes from the precompile rather than being
    ///      recovered from the Merkle path here, so the key cannot disagree with the
    ///      proof that was actually verified.
    function _consumeQuery(uint64 chainKey, uint64 blockHeight, INativeQueryVerifier.MerkleProof calldata merkleProof)
        private
    {
        uint64 txIndex = VERIFIER.calculateTxIndex(merkleProof);
        bytes32 queryKey = keccak256(abi.encode(chainKey, blockHeight, txIndex, merkleProof.root));
        if (consumed[queryKey]) revert QueryAlreadyConsumed(queryKey);
        consumed[queryKey] = true;
    }

    /**
     * @dev Checks 1, 4 and 6, plus the decode.
     *      Only logs emitted by the registered probe are considered. Any other log in
     *      the same transaction is ignored rather than rejected: a probe transaction is
     *      permissionless and may sit in a transaction that does other things.
     */
    function _record(uint64 chainKey, uint64 blockHeight, bytes calldata encodedTransaction, address expectedProbe)
        private
        returns (uint256 recorded)
    {
        bytes memory encoded = encodedTransaction;

        // Check 1: inclusion is not success.
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(encoded);
        if (receipt.receiptStatus != 1) revert ProbeTransactionReverted(receipt.receiptStatus);

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(receipt, PROBED_SIGNATURE);
        if (logs.length == 0) revert NoProbeLogs();

        for (uint256 i = 0; i < logs.length; ++i) {
            EvmV1Decoder.LogEntry memory log = logs[i];

            // Check 6: a look-alike emitter proves nothing about this feed.
            if (log.address_ != expectedProbe) revert ForeignEmitter(log.address_, expectedProbe);
            if (log.topics.length != 4) revert MalformedProbeLog();

            address target = address(uint160(uint256(log.topics[1])));
            bytes32 callHash = log.topics[2];
            address prober = address(uint160(uint256(log.topics[3])));

            (bool callSucceeded, bool truncated, uint256 emittedHeight, bytes memory returnData) =
                abi.decode(log.data, (bool, bool, uint256, bytes));

            // The probe records the height it ran at. It must be the height that was
            // proven, or the log has been bound to the wrong block somewhere.
            if (emittedHeight != blockHeight) revert EmittedHeightMismatch(emittedHeight, blockHeight);

            bytes32 id = feedIdFromCallHash(chainKey, target, callHash);

            // Check 4: newest-wins by source height, never by arrival order. Proofs
            // arrive out of order routinely, and an older one must not overwrite.
            Observation storage existing = _observations[id];
            if (existing.recordedAt != 0 && blockHeight <= existing.probeHeight) {
                revert ObservationNotNewer(id, blockHeight, existing.probeHeight);
            }

            _observations[id] = Observation({
                returnData: returnData,
                probeHeight: blockHeight,
                recordedAt: uint64(block.timestamp),
                callSucceeded: callSucceeded,
                truncated: truncated,
                prober: prober
            });

            emit ObservationRecorded(id, chainKey, target, blockHeight, callSucceeded, prober, returnData);
            ++recorded;
        }
    }
}
