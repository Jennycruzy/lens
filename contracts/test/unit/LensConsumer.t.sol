// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {LensConsumer} from "../../src/LensConsumer.sol";
import {IChainInfo, ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/// @dev The shape a real integration takes: inherit, name your chain, read.
contract ExampleReader is LensConsumer {
    uint64 private immutable _key;

    constructor(LensRegistry registry, uint64 chainKey) LensConsumer(registry) {
        _key = chainKey;
    }

    function _defaultChainKey() internal view override returns (uint64) {
        return _key;
    }

    function readBytes(bytes32 id, uint256 maxAge) external view returns (bytes memory) {
        return _latest(id, maxAge);
    }

    function readUint(bytes32 id, uint256 maxAge) external view returns (uint256) {
        return _latestUint(id, maxAge);
    }

    function readAddress(bytes32 id, uint256 maxAge) external view returns (address) {
        return _latestAddress(id, maxAge);
    }

    function readBool(bytes32 id, uint256 maxAge) external view returns (bool) {
        return _latestBool(id, maxAge);
    }

    function tryRead(bytes32 id, uint256 maxAge) external view returns (bool, bytes memory, uint256) {
        return _tryLatest(id, maxAge);
    }

    function age(bytes32 id) external view returns (uint256) {
        return _ageOf(id, _key);
    }
}

/**
 * @notice The consumer standard is where fail-closed lives, so these tests are mostly
 *         about refusal. The question each one asks is whether a caller can end up
 *         holding a value it believes is good when it is not.
 */
contract LensConsumerTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    address constant PROBER = address(0xB0B);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;

    LensRegistry registry;
    ExampleReader reader;
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
        reader = new ExampleReader(registry, KEY);
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);
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

    // --- the readable cases ----------------------------------------------------

    function test_readsAFreshValue() public {
        _record(FRONTIER - 10, abi.encode(uint256(4242)), true, false);
        assertEq(reader.readUint(feedId, 100), 4242);
        assertEq(reader.readBytes(feedId, 100), abi.encode(uint256(4242)));
        assertEq(reader.age(feedId), 10, "age is in blocks of the source chain");
    }

    function test_readsTypedValues() public {
        _record(FRONTIER - 10, abi.encode(address(0xDECAF)), true, false);
        assertEq(reader.readAddress(feedId, 100), address(0xDECAF));

        callHash = keccak256(hex"aabbccdd");
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);
        _record(FRONTIER - 10, abi.encode(true), true, false);
        assertTrue(reader.readBool(feedId, 100));
    }

    // --- the refusals, which are the point -------------------------------------

    function test_staleFeedRefuses() public {
        _record(FRONTIER - 500, abi.encode(uint256(1)), true, false);
        vm.expectRevert(abi.encodeWithSelector(LensConsumer.FeedStale.selector, feedId, 500, 100));
        reader.readUint(feedId, 100);
    }

    function test_ageBoundIsInclusive() public {
        _record(FRONTIER - 100, abi.encode(uint256(7)), true, false);
        assertEq(reader.readUint(feedId, 100), 7, "exactly at the bound is still fresh");
    }

    function test_missingFeedRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(LensConsumer.FeedUnavailable.selector, feedId));
        reader.readUint(feedId, 100);
    }

    /// A read that reverted at the source is a proven absence of a value, not a zero.
    function test_failedSourceReadRefusesRatherThanReturningZero() public {
        _record(FRONTIER - 10, hex"08c379a0", false, false);
        vm.expectRevert(abi.encodeWithSelector(LensConsumer.FeedReadFailed.selector, feedId));
        reader.readUint(feedId, 100);
    }

    /// A prefix of a number decodes to a plausible number that is wrong.
    function test_truncatedReadRefuses() public {
        _record(FRONTIER - 10, new bytes(8192), true, true);
        vm.expectRevert(abi.encodeWithSelector(LensConsumer.FeedTruncated.selector, feedId));
        reader.readBytes(feedId, 100);
    }

    function test_wrongWidthRefusesRatherThanDecodingGarbage() public {
        _record(FRONTIER - 10, hex"1234", true, false);
        vm.expectRevert(abi.encodeWithSelector(LensConsumer.FeedWrongWidth.selector, feedId, 2, 32));
        reader.readUint(feedId, 100);
    }

    // --- the refusal that reports instead of reverting --------------------------

    function test_tryLatestReportsRefusalAndCarriesNoValue() public {
        _record(FRONTIER - 500, abi.encode(uint256(99)), true, false);
        (bool ok, bytes memory data, uint256 age) = reader.tryRead(feedId, 100);
        assertFalse(ok, "must refuse");
        assertEq(data.length, 0, "a refused read never carries a value");
        assertEq(age, 500, "but it does report the age, so a caller can react");
    }

    function test_tryLatestSucceedsOnAFreshFeed() public {
        _record(FRONTIER - 10, abi.encode(uint256(99)), true, false);
        (bool ok, bytes memory data, uint256 age) = reader.tryRead(feedId, 100);
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 99);
        assertEq(age, 10);
    }

    function test_tryLatestOnAMissingFeedCarriesNoValue() public view {
        (bool ok, bytes memory data,) = reader.tryRead(keccak256("nothing here"), 100);
        assertFalse(ok);
        assertEq(data.length, 0);
    }

    // --- a frontier that moves backwards ---------------------------------------

    /// A source-chain reorg can rewind the frontier below a height already recorded.
    /// Age must clamp at zero rather than underflow into an enormous number, which
    /// would read as "impossibly stale" and lock every consumer out.
    function test_frontierBehindTheObservationClampsAgeToZero() public {
        _record(FRONTIER - 10, abi.encode(uint256(5)), true, false);
        chainInfo.setFrontier(KEY, FRONTIER - 100, true);

        assertEq(reader.age(feedId), 0, "age clamps rather than underflowing");
        assertEq(reader.readUint(feedId, 0), 5, "and the value stays readable at any bound");
    }

    // --- freshness is never measured on the wrong clock -------------------------

    /// Age must not move when Creditcoin's clock moves. It is a statement about the
    /// source chain, and only the source chain's frontier may change it.
    function test_ageIgnoresCreditcoinTimeAndHeight() public {
        _record(FRONTIER - 10, abi.encode(uint256(1)), true, false);
        uint256 before = reader.age(feedId);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 200_000);

        assertEq(reader.age(feedId), before, "Creditcoin time and height are irrelevant");
        assertEq(reader.readUint(feedId, 100), 1, "and the feed is still readable");

        chainInfo.setFrontier(KEY, FRONTIER + 90, true);
        assertEq(reader.age(feedId), 100, "only the source frontier moves it");
    }

    function testFuzz_neverReturnsAValueOlderThanTheCallerAllowed(uint32 offset, uint32 maxAge) public {
        vm.assume(offset > 0 && offset < FRONTIER);
        _record(FRONTIER - offset, abi.encode(uint256(1)), true, false);

        (bool ok,, uint256 age) = reader.tryRead(feedId, maxAge);
        if (ok) {
            assertLe(age, maxAge, "a value was returned, so it was inside the bound");
        } else {
            assertGt(age, maxAge, "it refused, so it was outside the bound");
        }
    }
}
