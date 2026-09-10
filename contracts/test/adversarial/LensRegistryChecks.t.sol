// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {IChainInfo, ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {INativeQueryVerifier, NativeQueryVerifierLib} from
    "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/**
 * @notice One test per way of getting a wrong answer into the registry.
 *
 * Each check is stated as an attack rather than as a feature, because that is how it
 * has to hold: not "the registry validates receipt status" but "a proof of a reverted
 * probe is rejected". Every one of these passes a *valid* proof to the registry. The
 * precompile is doing its job in all of them; the question is whether the registry
 * does its own.
 */
contract LensRegistryChecksTest is Test {
    uint64 constant ETHEREUM_KEY = 3; // on CC3 testnet
    uint64 constant ETHEREUM_CHAIN_ID = 1;
    uint64 constant SEPOLIA_KEY = 1;
    uint64 constant SEPOLIA_CHAIN_ID = 11155111;

    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    address constant PROBER = address(0xB0B);

    LensRegistry registry;
    ChainInfoStub chainInfo;
    VerifierStub verifier;

    uint64 constant FRONTIER = 25_947_000;
    bytes32 callHash = keccak256(hex"12345678");
    bytes32 probedSignature;
    uint256 constant SOURCE_TIME = 1_757_000_000;

    function setUp() public {
        // Put the stubs where the precompiles live, so the registry's own hardcoded
        // addresses are the ones under test.
        ChainInfoStub ci = new ChainInfoStub();
        VerifierStub v = new VerifierStub();
        vm.etch(ChainInfoLib.PRECOMPILE, address(ci).code);
        vm.etch(NativeQueryVerifierLib.PRECOMPILE, address(v).code);
        chainInfo = ChainInfoStub(ChainInfoLib.PRECOMPILE);
        verifier = VerifierStub(NativeQueryVerifierLib.PRECOMPILE);

        chainInfo.setChain(ETHEREUM_KEY, ETHEREUM_CHAIN_ID, "Ethereum");
        chainInfo.setChain(SEPOLIA_KEY, SEPOLIA_CHAIN_ID, "Sepolia ethereum");
        chainInfo.setFrontier(ETHEREUM_KEY, FRONTIER, true);
        chainInfo.setGenesis(ETHEREUM_KEY, 1_000_000);
        verifier.setAccept(true);

        registry = _deploy(ETHEREUM_KEY, ETHEREUM_CHAIN_ID, PROBE);
        probedSignature = registry.PROBED_SIGNATURE();
    }

    function _deploy(uint64 key, uint64 chainId, address probe) internal returns (LensRegistry) {
        uint64[] memory keys = new uint64[](1);
        uint64[] memory ids = new uint64[](1);
        address[] memory probes = new address[](1);
        keys[0] = key;
        ids[0] = chainId;
        probes[0] = probe;
        return new LensRegistry(keys, ids, probes);
    }

    function _tx(uint8 status, address emitter, bool callSucceeded, bool truncated, uint256 height, bytes memory ret)
        internal
        view
        returns (bytes memory)
    {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            emitter, probedSignature, TARGET, callHash, PROBER, callSucceeded, truncated, height, SOURCE_TIME, ret
        );
        return TxFixture.encode(2, status, logs);
    }

    function _goodTx(uint256 height, bytes memory ret) internal view returns (bytes memory) {
        return _tx(1, PROBE, true, false, height, ret);
    }

    function _proof() internal pure returns (INativeQueryVerifier.MerkleProof memory) {
        return INativeQueryVerifier.MerkleProof({root: keccak256("root"), siblings: new INativeQueryVerifier.MerkleProofEntry[](0)});
    }

    function _proofWithRoot(bytes32 root) internal pure returns (INativeQueryVerifier.MerkleProof memory) {
        return INativeQueryVerifier.MerkleProof({root: root, siblings: new INativeQueryVerifier.MerkleProofEntry[](0)});
    }

    function _continuity() internal pure returns (INativeQueryVerifier.ContinuityProof memory) {
        return INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)});
    }

    function _submit(uint64 height, bytes memory encoded, INativeQueryVerifier.MerkleProof memory mp)
        internal
        returns (uint256)
    {
        return registry.submitProof(ETHEREUM_KEY, height, encoded, mp, _continuity());
    }

    // --- the happy path, so the rejections below mean something ---------------

    function test_aValidProbeIsRecorded() public {
        uint256 n = _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(1234))), _proof());
        assertEq(n, 1);

        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, callHash);
        LensRegistry.Observation memory o = registry.observationOf(id);
        assertEq(abi.decode(o.returnData, (uint256)), 1234);
        assertEq(o.probeHeight, FRONTIER - 10);
        assertTrue(o.callSucceeded);
        assertEq(o.prober, PROBER);
    }

    // --- check 1: inclusion is not success ------------------------------------

    function test_proofOfARevertedProbeTransactionIsRejected() public {
        bytes memory encoded = _tx(0, PROBE, true, false, FRONTIER - 10, abi.encode(uint256(1234)));
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.ProbeTransactionReverted.selector, uint8(0)));
        _submit(FRONTIER - 10, encoded, _proof());
    }

    // --- check 2: a valid proof stays valid forever ---------------------------

    function test_replayedProofIsRejected() public {
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(1))), _proof());
        bytes memory replay = _goodTx(FRONTIER - 10, abi.encode(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(
                LensRegistry.QueryAlreadyConsumed.selector,
                keccak256(abi.encode(ETHEREUM_KEY, uint64(FRONTIER - 10), uint64(0), keccak256("root")))
            )
        );
        _submit(FRONTIER - 10, replay, _proof());
    }

    function test_twoDistinctQueriesInTheSameBlockBothLand() public {
        verifier.setTxIndex(0);
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(1))), _proof());
        // A different transaction in the same block has a different index and root.
        verifier.setTxIndex(7);
        callHash = keccak256(hex"9999");
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(2))), _proofWithRoot(keccak256("other")));
    }

    // --- check 3: outside the attested range, in both directions --------------

    function test_heightAboveTheFrontierIsRejected() public {
        bytes memory encoded = _goodTx(FRONTIER + 1, abi.encode(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(LensRegistry.HeightAboveFrontier.selector, ETHEREUM_KEY, FRONTIER + 1, FRONTIER)
        );
        _submit(FRONTIER + 1, encoded, _proof());
    }

    function test_heightBelowAttestationGenesisIsRejected() public {
        bytes memory encoded = _goodTx(999_999, abi.encode(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(LensRegistry.HeightBelowAttestationGenesis.selector, ETHEREUM_KEY, uint64(999_999), uint64(1_000_000))
        );
        _submit(999_999, encoded, _proof());
    }

    function test_chainWithNothingAttestedIsRejected() public {
        bytes memory encoded = _goodTx(FRONTIER - 10, abi.encode(uint256(1)));
        chainInfo.setFrontier(ETHEREUM_KEY, 0, false);
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.NothingAttested.selector, ETHEREUM_KEY));
        _submit(FRONTIER - 10, encoded, _proof());
    }

    // --- check 4: newest wins, by source height, never by arrival order --------

    function test_olderObservationCannotDisplaceANewerOne() public {
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(100))), _proof());

        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, callHash);
        verifier.setTxIndex(1);
        bytes memory older = _goodTx(FRONTIER - 50, abi.encode(uint256(999)));
        vm.expectRevert(
            abi.encodeWithSelector(LensRegistry.ObservationNotNewer.selector, id, uint256(FRONTIER - 50), uint256(FRONTIER - 10))
        );
        _submit(FRONTIER - 50, older, _proofWithRoot(keccak256("b")));
    }

    function test_sameHeightTwiceIsRejected() public {
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(100))), _proof());
        verifier.setTxIndex(1);
        bytes memory sameHeight = _goodTx(FRONTIER - 10, abi.encode(uint256(101)));
        vm.expectRevert();
        _submit(FRONTIER - 10, sameHeight, _proofWithRoot(keccak256("c")));
    }

    function test_newerObservationReplacesTheHeldOne() public {
        _submit(FRONTIER - 50, _goodTx(FRONTIER - 50, abi.encode(uint256(100))), _proof());
        verifier.setTxIndex(1);
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(200))), _proofWithRoot(keccak256("d")));

        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, callHash);
        assertEq(abi.decode(registry.observationOf(id).returnData, (uint256)), 200);
    }

    // --- check 5: the same integer means different chains elsewhere -----------

    function test_deployingAgainstAChainKeyThatMeansSomethingElseReverts() public {
        // Key 1 is Ethereum mainnet on CC3 mainnet, but Sepolia here. A registry built
        // for mainnet must refuse to come up on testnet rather than silently report
        // Sepolia state as Ethereum's.
        vm.expectRevert(
            abi.encodeWithSelector(
                LensRegistry.ChainKeyMeansADifferentChain.selector, SEPOLIA_KEY, ETHEREUM_CHAIN_ID, SEPOLIA_CHAIN_ID
            )
        );
        _deploy(SEPOLIA_KEY, ETHEREUM_CHAIN_ID, PROBE);
    }

    function test_deployingAgainstAnUnattestedChainKeyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.ChainKeyNotAttested.selector, uint64(99)));
        _deploy(99, 12345, PROBE);
    }

    function test_unknownChainKeyIsRejectedOnSubmission() public {
        bytes memory encoded = _goodTx(FRONTIER - 10, abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.UnknownChainKey.selector, SEPOLIA_KEY));
        registry.submitProof(SEPOLIA_KEY, FRONTIER - 10, encoded, _proof(), _continuity());
    }

    // --- check 6: a look-alike emitter proves nothing --------------------------

    function test_logFromALookAlikeEmitterIsRejected() public {
        address lookAlike = address(0xBADBAD);
        bytes memory encoded = _tx(1, lookAlike, true, false, FRONTIER - 10, abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.ForeignEmitter.selector, lookAlike, PROBE));
        _submit(FRONTIER - 10, encoded, _proof());
    }

    function test_transactionWithNoProbeLogsIsRejected() public {
        bytes memory encoded = TxFixture.encode(2, 1, new EvmV1Decoder.LogEntry[](0));
        vm.expectRevert(LensRegistry.NoProbeLogs.selector);
        _submit(FRONTIER - 10, encoded, _proof());
    }

    // --- binding the log to the block it was proven in -------------------------

    function test_logClaimingADifferentHeightThanWasProvenIsRejected() public {
        bytes memory encoded = _goodTx(FRONTIER - 999, abi.encode(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(LensRegistry.EmittedHeightMismatch.selector, uint256(FRONTIER - 999), uint64(FRONTIER - 10))
        );
        _submit(FRONTIER - 10, encoded, _proof());
    }

    // --- the precompile's own refusal -----------------------------------------

    function test_proofThePrecompileRejectsIsNotRecorded() public {
        bytes memory encoded = _goodTx(FRONTIER - 10, abi.encode(uint256(1)));
        verifier.setAccept(false);
        vm.expectRevert(LensRegistry.ProofRejected.selector);
        _submit(FRONTIER - 10, encoded, _proof());
    }

    // --- a failed read is recorded as failed, never as a value -----------------

    function test_failedSourceReadIsRecordedAsFailure() public {
        bytes memory encoded = _tx(1, PROBE, false, false, FRONTIER - 10, hex"08c379a0");
        _submit(FRONTIER - 10, encoded, _proof());
        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, callHash);
        assertFalse(registry.observationOf(id).callSucceeded, "must be marked failed");
    }

    function test_truncatedReadIsRecordedAsTruncated() public {
        bytes memory encoded = _tx(1, PROBE, true, true, FRONTIER - 10, new bytes(8192));
        _submit(FRONTIER - 10, encoded, _proof());
        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, callHash);
        assertTrue(registry.observationOf(id).truncated, "must be marked truncated");
    }

    // --- the two clocks must not be confused -----------------------------------

    /// The source time is when the value was true. Creditcoin's time is when the proof
    /// arrived, which is later by the attestation lag. A consumer handed the second and
    /// told it was the first believes the value fresher than it is.
    function test_sourceTimeAndCreditcoinTimeAreRecordedSeparately() public {
        vm.warp(SOURCE_TIME + 8 minutes);
        _submit(FRONTIER - 10, _goodTx(FRONTIER - 10, abi.encode(uint256(1))), _proof());

        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, callHash);
        LensRegistry.Observation memory o = registry.observationOf(id);

        assertEq(o.sourceTimestamp, SOURCE_TIME, "must keep the time the read happened");
        assertEq(o.recordedAt, SOURCE_TIME + 8 minutes, "and the time the proof landed");
        assertLt(o.sourceTimestamp, o.recordedAt, "the source time is always the earlier of the two");
    }

    // --- absence is not zero ---------------------------------------------------

    function test_readingAFeedThatHasNoObservationReverts() public {
        bytes32 id = registry.feedIdFromCallHash(ETHEREUM_KEY, TARGET, keccak256("never probed"));
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.NoObservation.selector, id));
        registry.observationOf(id);
    }

    // --- batching --------------------------------------------------------------

    function test_batchAboveThePrecompileCapIsRejected() public {
        uint256 n = registry.MAX_BATCH() + 1;
        vm.expectRevert(abi.encodeWithSelector(LensRegistry.BatchTooLarge.selector, n, registry.MAX_BATCH()));
        registry.submitBatch(
            ETHEREUM_KEY, new uint64[](n), new bytes[](n), new INativeQueryVerifier.MerkleProof[](n), _continuity()
        );
    }

    function test_batchSharesOneContinuityProofAcrossQueries() public {
        uint64[] memory heights = new uint64[](3);
        bytes[] memory txs = new bytes[](3);
        INativeQueryVerifier.MerkleProof[] memory proofs = new INativeQueryVerifier.MerkleProof[](3);

        for (uint256 i = 0; i < 3; ++i) {
            heights[i] = uint64(FRONTIER - 30 + i);
            callHash = keccak256(abi.encode("feed", i));
            txs[i] = _goodTx(heights[i], abi.encode(uint256(i + 1)));
            proofs[i] = _proofWithRoot(keccak256(abi.encode("root", i)));
        }

        uint256 recorded = registry.submitBatch(ETHEREUM_KEY, heights, txs, proofs, _continuity());
        assertEq(recorded, 3, "one continuity proof, three feeds");
    }
}
