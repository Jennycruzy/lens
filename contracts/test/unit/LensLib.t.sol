// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {LensLib} from "../../src/LensLib.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/// @dev A contract whose inheritance is already settled, using the library instead.
contract AlreadyInherits {
    using LensLib for LensRegistry;

    LensRegistry public immutable LENS;
    uint64 public immutable KEY;

    constructor(LensRegistry lens, uint64 key) {
        LENS = lens;
        KEY = key;
    }

    function readUint(bytes32 id, uint256 maxAge) external view returns (uint256) {
        return LENS.latestUint(KEY, id, maxAge);
    }

    function readInt(bytes32 id, uint256 maxAge) external view returns (int256) {
        return LENS.latestInt(KEY, id, maxAge);
    }

    function readAddress(bytes32 id, uint256 maxAge) external view returns (address) {
        return LENS.latestAddress(KEY, id, maxAge);
    }

    function tryRead(bytes32 id, uint256 maxAge) external view returns (bool, bytes memory, uint256) {
        return LENS.tryLatest(KEY, id, maxAge);
    }

    function age(bytes32 id) external view returns (uint256) {
        return LENS.ageOf(KEY, id);
    }
}

contract LensLibTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;

    LensRegistry registry;
    AlreadyInherits reader;
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
        reader = new AlreadyInherits(registry, KEY);
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);
    }

    function _record(uint64 height, bytes memory ret, bool ok, bool truncated) internal {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE,
            registry.PROBED_SIGNATURE(),
            TARGET,
            callHash,
            address(0xB0B),
            ok,
            truncated,
            height,
            SOURCE_TIME,
            ret
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

    /// The identifier the library computes must equal the one the registry computes,
    /// or a contract using the library reads a feed nobody is maintaining.
    function test_theIdentifierAgreesWithTheRegistry() public view {
        bytes memory callData = hex"18160ddd";
        assertEq(
            LensLib.feedId(registry, KEY, TARGET, callData),
            registry.feedId(KEY, TARGET, callData),
            "library and registry must derive the same feed"
        );
    }

    function test_readsTypedValues() public {
        _record(FRONTIER - 10, abi.encode(uint256(4242)), true, false);
        assertEq(reader.readUint(feedId, 100), 4242);
        assertEq(reader.age(feedId), 10);

        callHash = keccak256(hex"aabb");
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);
        _record(FRONTIER - 10, abi.encode(int256(-77)), true, false);
        assertEq(reader.readInt(feedId, 100), -77);

        callHash = keccak256(hex"ccdd");
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);
        _record(FRONTIER - 10, abi.encode(address(0xDECAF)), true, false);
        assertEq(reader.readAddress(feedId, 100), address(0xDECAF));
    }

    function test_staleRefuses() public {
        _record(FRONTIER - 900, abi.encode(uint256(1)), true, false);
        vm.expectRevert(abi.encodeWithSelector(LensLib.FeedStale.selector, feedId, 900, 100));
        reader.readUint(feedId, 100);
    }

    function test_missingRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(LensLib.FeedUnavailable.selector, feedId));
        reader.readUint(feedId, 100);
    }

    function test_failedReadRefuses() public {
        _record(FRONTIER - 10, hex"08c379a0", false, false);
        vm.expectRevert(abi.encodeWithSelector(LensLib.SourceCallReverted.selector, feedId));
        reader.readUint(feedId, 100);
    }

    function test_truncatedRefuses() public {
        _record(FRONTIER - 10, new bytes(64), true, true);
        vm.expectRevert(abi.encodeWithSelector(LensLib.AnswerTruncated.selector, feedId));
        reader.readUint(feedId, 100);
    }

    function test_wrongWidthRefuses() public {
        _record(FRONTIER - 10, hex"1234", true, false);
        vm.expectRevert(abi.encodeWithSelector(LensLib.AnswerWrongWidth.selector, feedId, 2));
        reader.readUint(feedId, 100);
    }

    function test_tryLatestCarriesNoValueWhenItRefuses() public {
        _record(FRONTIER - 900, abi.encode(uint256(1)), true, false);
        (bool ok, bytes memory data, uint256 age) = reader.tryRead(feedId, 100);
        assertFalse(ok);
        assertEq(data.length, 0);
        assertEq(age, 900);
    }

    function test_frontierRegressionRefusesEveryRead() public {
        _record(FRONTIER - 10, abi.encode(uint256(3)), true, false);
        chainInfo.setFrontier(KEY, FRONTIER - 500, true);

        assertEq(reader.age(feedId), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(LensLib.FeedStale.selector, feedId, type(uint256).max, type(uint256).max)
        );
        reader.readUint(feedId, type(uint256).max);

        (bool ok, bytes memory data, uint256 age) = reader.tryRead(feedId, type(uint256).max);
        assertFalse(ok);
        assertEq(data.length, 0);
        assertEq(age, type(uint256).max);
    }
}
