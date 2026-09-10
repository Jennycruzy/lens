// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {LensConsumer} from "../../src/LensConsumer.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {NativeQueryVerifierLib} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {ChainInfoStub, VerifierStub} from "../helpers/Precompiles.sol";
import {RegistryHandler} from "./RegistryHandler.sol";

contract Reader is LensConsumer {
    uint64 private immutable _key;

    constructor(LensRegistry r, uint64 k) LensConsumer(r) {
        _key = k;
    }

    function _defaultChainKey() internal view override returns (uint64) {
        return _key;
    }

    function tryRead(bytes32 id, uint256 maxAge) external view returns (bool, bytes memory, uint256) {
        return _tryLatest(id, maxAge);
    }

    function read(bytes32 id, uint256 maxAge) external view returns (bytes memory) {
        return _latest(id, maxAge);
    }
}

/**
 * @notice The properties that must hold no matter what sequence of proofs arrives.
 *
 * These are the security argument. Stating them in a comment costs nothing and proves
 * nothing; a runner that tries thousands of orderings, including replays, reorgs and
 * proofs the precompile refuses, is what makes them claims.
 */
contract LensInvariantsTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    uint64 constant START_FRONTIER = 1_000_000;

    LensRegistry registry;
    RegistryHandler handler;
    ChainInfoStub chainInfo;
    VerifierStub verifier;
    Reader reader;

    function setUp() public {
        vm.etch(ChainInfoLib.PRECOMPILE, address(new ChainInfoStub()).code);
        vm.etch(NativeQueryVerifierLib.PRECOMPILE, address(new VerifierStub()).code);
        chainInfo = ChainInfoStub(ChainInfoLib.PRECOMPILE);
        verifier = VerifierStub(NativeQueryVerifierLib.PRECOMPILE);

        chainInfo.setChain(KEY, CHAIN_ID, "Sepolia ethereum");
        chainInfo.setFrontier(KEY, START_FRONTIER, true);
        chainInfo.setGenesis(KEY, 0);

        uint64[] memory keys = new uint64[](1);
        uint64[] memory ids = new uint64[](1);
        address[] memory probes = new address[](1);
        keys[0] = KEY;
        ids[0] = CHAIN_ID;
        probes[0] = address(0xA11CE);
        registry = new LensRegistry(keys, ids, probes);
        reader = new Reader(registry, KEY);

        handler = new RegistryHandler(registry, chainInfo, verifier, START_FRONTIER);
        targetContract(address(handler));
    }

    /// A recorded height never goes backwards, whatever order proofs arrive in.
    function invariant_probeHeightNeverDecreases() public view {
        for (uint256 i = 0; i < 4; i++) {
            bytes32 id = handler.feedIdAt(i);
            if (!handler.everRecorded(id)) continue;
            assertEq(
                registry.observationOf(id).probeHeight,
                handler.expectedHeight(id),
                "the registry holds a different height than the newest one accepted"
            );
        }
    }

    /// No observation is ever recorded above the frontier that was attested at the time.
    ///
    /// It is checked against the highest frontier ever reached rather than the current
    /// one, because a source-chain reorg rewinds the frontier below heights that were
    /// legitimately recorded before it. An observation sitting above the present
    /// frontier is therefore not a violation — it is the signature of a reorg, and it is
    /// what a circuit breaker exists to notice. This invariant caught that behaviour
    /// rather than the other way round.
    function invariant_recordedHeightWasAttestedWhenRecorded() public view {
        for (uint256 i = 0; i < 4; i++) {
            bytes32 id = handler.feedIdAt(i);
            if (!handler.everRecorded(id)) continue;
            assertLe(
                registry.observationOf(id).probeHeight,
                handler.highWaterFrontier(),
                "a height was recorded that had never been attested"
            );
        }
    }

    /// A read that failed at the source is never handed to a consumer as a value.
    function invariant_failedReadIsNeverSurfacedAsAValue() public view {
        for (uint256 i = 0; i < 4; i++) {
            bytes32 id = handler.feedIdAt(i);
            if (!handler.everRecorded(id)) continue;
            if (!handler.expectedFailed(id)) continue;
            (bool ok, bytes memory data,) = reader.tryRead(id, type(uint256).max);
            assertFalse(ok, "a failed read was offered as a value");
            assertEq(data.length, 0, "a refused read carried data");
        }
    }

    /// Fail-closed: a consumer never receives a value older than it allowed.
    function invariant_consumerNeverReceivesAValueOlderThanItsBound() public view {
        uint256[3] memory bounds = [uint256(0), 50, 1000];
        for (uint256 i = 0; i < 4; i++) {
            bytes32 id = handler.feedIdAt(i);
            if (!handler.everRecorded(id)) continue;
            for (uint256 b = 0; b < bounds.length; b++) {
                (bool ok,, uint256 age) = reader.tryRead(id, bounds[b]);
                if (ok) assertLe(age, bounds[b], "a value was returned outside the caller's bound");
            }
        }
    }

    /// An observation exists only where a submission was accepted.
    function invariant_observationsOnlyExistForAcceptedSubmissions() public view {
        for (uint256 i = 0; i < 4; i++) {
            bytes32 id = handler.feedIdAt(i);
            assertEq(
                registry.hasObservation(id),
                handler.everRecorded(id),
                "the registry and the handler disagree about whether a feed exists"
            );
        }
    }

    /// Invariant 3: no query is ever verified twice.
    ///
    /// Every query key the registry accepted is marked consumed, and the number of keys
    /// equals the number of accepted submissions — so none was accepted without being
    /// spent, and none was spent twice.
    ///
    /// The earlier version of this asserted `accepted + rejected >= accepted`, which is
    /// true of any two unsigned numbers and therefore checked nothing at all.
    function invariant_everyAcceptedQueryIsConsumedExactlyOnce() public view {
        uint256 n = handler.acceptedKeyCount();
        assertEq(n, handler.accepted(), "a submission was accepted without consuming a query");
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = handler.acceptedKeys(i);
            assertTrue(registry.consumed(key), "an accepted query was not marked consumed");
        }
    }

    /// And a consumed query can never be spent again, whatever else has happened.
    function invariant_aConsumedQueryStaysConsumed() public view {
        uint256 n = handler.acceptedKeyCount();
        if (n == 0) return;
        // Spot-check the oldest and newest rather than every key on every run.
        assertTrue(registry.consumed(handler.acceptedKeys(0)));
        assertTrue(registry.consumed(handler.acceptedKeys(n - 1)));
    }
}
