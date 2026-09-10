// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {RegistryFeed} from "../../src/RegistryFeed.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/**
 * @notice The adapter that lets everything in the composition layer stay ignorant of
 *         where a number came from. Its refusals are what the composer relies on, so
 *         each one is exercised directly rather than only through a median.
 */
contract RegistryFeedTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    address constant PROBER = address(0xB0B);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;
    uint256 constant MAX_AGE = 200;

    LensRegistry registry;
    RegistryFeed feed;
    ChainInfoStub chainInfo;
    VerifierStub verifier;
    bytes32 callHash = keccak256(hex"18160ddd");
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
        feed = new RegistryFeed(registry, KEY, feedId, MAX_AGE, "total supply");
    }

    function _record(uint64 height, bytes memory ret, bool ok, bool truncated) internal {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE, registry.PROBED_SIGNATURE(), TARGET, callHash, PROBER, ok, truncated, height, SOURCE_TIME, ret
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

    function test_readsAValueAndItsAge() public {
        _record(FRONTIER - 30, abi.encode(uint256(777)), true, false);
        (uint256 value, uint256 age) = feed.read();
        assertEq(value, 777);
        assertEq(age, 30, "age is in blocks of the source chain");
        assertEq(feed.describe(), "total supply");
    }

    function test_tryReadAgreesWithRead() public {
        _record(FRONTIER - 30, abi.encode(uint256(777)), true, false);
        (bool ok, uint256 value, uint256 age) = feed.tryRead();
        (uint256 rValue, uint256 rAge) = feed.read();
        assertTrue(ok);
        assertEq(value, rValue);
        assertEq(age, rAge);
    }

    function test_missingFeedRefusesBothWays() public {
        vm.expectRevert(abi.encodeWithSelector(RegistryFeed.FeedUnavailable.selector, feedId));
        feed.read();

        (bool ok, uint256 value, uint256 age) = feed.tryRead();
        assertFalse(ok);
        assertEq(value, 0);
        assertEq(age, type(uint256).max, "an unknown age is reported as unbounded, not zero");
    }

    function test_failedSourceReadRefusesBothWays() public {
        _record(FRONTIER - 10, hex"08c379a0", false, false);
        vm.expectRevert(abi.encodeWithSelector(RegistryFeed.SourceCallReverted.selector, feedId));
        feed.read();
        (bool ok,,) = feed.tryRead();
        assertFalse(ok);
    }

    function test_truncatedReadRefusesBothWays() public {
        _record(FRONTIER - 10, new bytes(64), true, true);
        vm.expectRevert(abi.encodeWithSelector(RegistryFeed.AnswerTruncated.selector, feedId));
        feed.read();
        (bool ok,,) = feed.tryRead();
        assertFalse(ok);
    }

    function test_wrongWidthRefusesBothWays() public {
        _record(FRONTIER - 10, hex"1234", true, false);
        vm.expectRevert(abi.encodeWithSelector(RegistryFeed.AnswerWrongWidth.selector, 2));
        feed.read();
        (bool ok,,) = feed.tryRead();
        assertFalse(ok, "a value of the wrong width is never decoded");
    }

    function test_staleFeedRefusesButStillReportsItsAge() public {
        _record(FRONTIER - 500, abi.encode(uint256(1)), true, false);
        vm.expectRevert(abi.encodeWithSelector(RegistryFeed.FeedStale.selector, feedId, 500, MAX_AGE));
        feed.read();

        (bool ok,, uint256 age) = feed.tryRead();
        assertFalse(ok);
        assertEq(age, 500, "the age is reported so a caller can react rather than guess");
    }

    function test_ageBoundIsInclusive() public {
        _record(FRONTIER - uint64(MAX_AGE), abi.encode(uint256(5)), true, false);
        (uint256 value,) = feed.read();
        assertEq(value, 5);
    }

    /// After a reorg the frontier can sit below a recorded height. Age clamps to zero
    /// rather than underflowing into a number that would lock every reader out.
    function test_frontierBehindTheObservationClampsAge() public {
        _record(FRONTIER - 10, abi.encode(uint256(9)), true, false);
        chainInfo.setFrontier(KEY, FRONTIER - 100, true);
        (uint256 value, uint256 age) = feed.read();
        assertEq(age, 0);
        assertEq(value, 9);
    }

    function test_registryAddressIsRequired() public {
        vm.expectRevert(RegistryFeed.RegistryRequired.selector);
        new RegistryFeed(LensRegistry(address(0)), KEY, feedId, MAX_AGE, "x");
    }

    function testFuzz_neverReturnsAValueOutsideItsBound(uint32 offset) public {
        vm.assume(offset > 0 && offset < FRONTIER);
        _record(FRONTIER - offset, abi.encode(uint256(1)), true, false);
        (bool ok,, uint256 age) = feed.tryRead();
        if (ok) assertLe(age, MAX_AGE);
        else assertGt(age, MAX_AGE);
    }
}
