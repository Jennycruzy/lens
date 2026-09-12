// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {CircuitBreaker} from "../../src/CircuitBreaker.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

contract CircuitBreakerTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    address constant PROBER = address(0xB0B);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;

    uint256 constant MAX_DEVIATION_BPS = 500; // 5%
    uint256 constant MAX_AGE = 300;

    LensRegistry registry;
    CircuitBreaker breaker;
    ChainInfoStub chainInfo;
    VerifierStub verifier;
    bytes32 callHash = keccak256(hex"50d25bcd");
    bytes32 feedId;
    uint64 nonce;

    function setUp() public {
        vm.etch(ChainInfoLib.PRECOMPILE, address(new ChainInfoStub()).code);
        vm.etch(NativeQueryVerifierLib.PRECOMPILE, address(new VerifierStub()).code);
        chainInfo = ChainInfoStub(ChainInfoLib.PRECOMPILE);
        verifier = VerifierStub(NativeQueryVerifierLib.PRECOMPILE);

        chainInfo.setChain(KEY, CHAIN_ID, "Sepolia ethereum");
        chainInfo.setFrontier(KEY, FRONTIER, true);
        chainInfo.setGenesis(KEY, 0);
        verifier.setAccept(true);

        uint64[] memory keys = new uint64[](1);
        uint64[] memory ids = new uint64[](1);
        address[] memory probes = new address[](1);
        keys[0] = KEY;
        ids[0] = CHAIN_ID;
        probes[0] = PROBE;
        registry = new LensRegistry(keys, ids, probes);
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);
        breaker = new CircuitBreaker(registry, KEY, feedId, MAX_DEVIATION_BPS, MAX_AGE);
    }

    function _record(uint64 height, uint256 v) internal {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE,
            registry.PROBED_SIGNATURE(),
            TARGET,
            callHash,
            PROBER,
            true,
            false,
            height,
            SOURCE_TIME,
            abi.encode(v)
        );
        verifier.setTxIndex(++nonce);
        registry.submitProof(
            KEY,
            height,
            TxFixture.encode(2, 1, logs),
            INativeQueryVerifier.MerkleProof({
                root: keccak256(abi.encode(nonce)), siblings: new INativeQueryVerifier.MerkleProofEntry[](0)
            }),
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)})
        );
    }

    function test_passesAValueInsideEveryBound() public {
        _record(FRONTIER - 10, 2467e8);
        breaker.poke();
        (uint256 v, uint256 h) = breaker.value();
        assertEq(v, 2467e8);
        assertEq(h, FRONTIER - 10);
    }

    // --- deviation ------------------------------------------------------------

    function test_aMoveInsideTheBoundIsAccepted() public {
        _record(FRONTIER - 20, 2000e8);
        breaker.poke();
        _record(FRONTIER - 10, 2080e8); // 4%
        (bool tripped,) = breaker.poke();
        assertFalse(tripped, "4 percent is inside a 5 percent bound");
        (uint256 v,) = breaker.value();
        assertEq(v, 2080e8);
    }

    function test_aMoveBeyondTheBoundTrips() public {
        _record(FRONTIER - 20, 2000e8);
        breaker.poke();
        _record(FRONTIER - 10, 2200e8); // 10%
        (bool tripped, CircuitBreaker.Reason reason) = breaker.poke();
        assertTrue(tripped);
        assertEq(uint8(reason), uint8(CircuitBreaker.Reason.Deviation));

        vm.expectRevert(
            abi.encodeWithSelector(
                CircuitBreaker.BreakerTripped.selector, CircuitBreaker.Reason.Deviation, uint64(block.timestamp)
            )
        );
        breaker.value();
    }

    function test_theSameDeviatingObservationCannotRestoreItself() public {
        _record(FRONTIER - 20, 2000e8);
        breaker.poke();
        _record(FRONTIER - 10, 2200e8);
        (bool tripped,) = breaker.poke();
        assertTrue(tripped);

        (tripped,) = breaker.poke();
        assertTrue(tripped, "a second poke is not an independent confirmation");
    }

    function test_aCrashTripsJustAsAJumpDoes() public {
        _record(FRONTIER - 20, 2000e8);
        breaker.poke();
        _record(FRONTIER - 10, 1000e8); // -50%
        (bool tripped, CircuitBreaker.Reason reason) = breaker.poke();
        assertTrue(tripped);
        assertEq(uint8(reason), uint8(CircuitBreaker.Reason.Deviation));
    }

    // --- frontier regression, the reorg signature -----------------------------

    /// Found by the invariant run rather than designed from a specification: after a
    /// source-chain reorg the frontier can fall below a height already recorded.
    function test_frontierFallingBelowTheObservationTrips() public {
        _record(FRONTIER - 10, 2467e8);
        breaker.poke();

        chainInfo.setFrontier(KEY, FRONTIER - 50, true); // the reorg

        (bool tripped, CircuitBreaker.Reason reason) = breaker.status();
        assertTrue(tripped, "a rewound frontier must not be readable");
        assertEq(uint8(reason), uint8(CircuitBreaker.Reason.FrontierRegression));

        vm.expectRevert();
        breaker.value();
    }

    function test_frontierRecoveryAloneDoesNotRestore() public {
        _record(FRONTIER - 10, 2467e8);
        breaker.poke();

        chainInfo.setFrontier(KEY, FRONTIER - 50, true);
        (bool tripped,) = breaker.poke();
        assertTrue(tripped);

        chainInfo.setFrontier(KEY, FRONTIER, true);
        (tripped,) = breaker.poke();
        assertTrue(tripped, "catching up does not prove the old block remained canonical");

        _record(FRONTIER - 5, 2468e8);
        (tripped,) = breaker.poke();
        assertFalse(tripped, "a newer in-bound observation restores the feed");
    }

    // --- age ------------------------------------------------------------------

    function test_ageBeyondTheHardLimitTrips() public {
        _record(FRONTIER - uint64(MAX_AGE) - 1, 2467e8);
        (bool tripped, CircuitBreaker.Reason reason) = breaker.poke();
        assertTrue(tripped);
        assertEq(uint8(reason), uint8(CircuitBreaker.Reason.Age));
    }

    function test_ageExactlyAtTheLimitIsStillServed() public {
        _record(FRONTIER - uint64(MAX_AGE), 2467e8);
        (bool tripped,) = breaker.poke();
        assertFalse(tripped, "the bound is inclusive");
    }

    // --- restoring ------------------------------------------------------------

    function test_untripsOnlyOnAFreshObservationInsideEveryBound() public {
        _record(FRONTIER - 20, 2000e8);
        breaker.poke();
        _record(FRONTIER - 10, 2200e8);
        (bool tripped,) = breaker.poke();
        assertTrue(tripped);

        // Time passing is not evidence that anything improved.
        vm.warp(block.timestamp + 30 days);
        (tripped,) = breaker.status();
        assertTrue(tripped, "a breaker must not heal by waiting");

        // A fresh observation close to the last accepted value restores it.
        _record(FRONTIER - 5, 2260e8); // within 5% of 2200
        (tripped,) = breaker.poke();
        assertFalse(tripped, "a fresh in-bound observation restores the feed");
        (uint256 v,) = breaker.value();
        assertEq(v, 2260e8);
    }

    // --- no keys --------------------------------------------------------------

    /// The claim in the documentation, tested rather than asserted: there is no function
    /// on this contract that anybody can use to force it either way.
    function test_thereIsNoWayForAnyoneToTripOrUntripItByHand() public {
        _record(FRONTIER - 10, 2467e8);
        breaker.poke();

        address attacker = address(0xBAD);
        vm.startPrank(attacker);
        // `poke` is the only state-changing entry point and it takes no argument.
        breaker.poke();
        vm.stopPrank();

        (bool tripped,) = breaker.status();
        assertFalse(tripped, "an outsider changed nothing by calling the only entry point");
        (uint256 v,) = breaker.value();
        assertEq(v, 2467e8, "and the value is unchanged");
    }

    function test_pokeIsPermissionlessAndAnyoneCanRestoreTheFeed() public {
        _record(FRONTIER - 20, 2000e8);
        breaker.poke();
        _record(FRONTIER - 10, 2200e8);
        breaker.poke();

        _record(FRONTIER - 5, 2210e8);
        vm.prank(address(0xA11CE1));
        (bool tripped,) = breaker.poke();
        assertFalse(tripped, "a stranger restored it by telling it to look again");
    }

    // --- feeds that cannot be valued -----------------------------------------

    function test_aFeedWithNoObservationIsNotTrippedButHasNoValue() public {
        (bool tripped,) = breaker.status();
        assertFalse(tripped, "absence is not a fault");
        vm.expectRevert();
        breaker.value();
    }
}
