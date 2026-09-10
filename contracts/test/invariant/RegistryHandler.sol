// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {INativeQueryVerifier} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/**
 * @notice Drives the registry the way the world does: proofs arriving out of order, some
 *         replayed, some for reads that failed at the source, some for heights the chain
 *         has not attested, all while the frontier moves and occasionally rewinds.
 *
 * @dev The handler records what it believes should have happened. The invariants then
 *      compare that belief against the registry. Where they disagree, one of them is
 *      wrong, and finding out which is the point.
 */
contract RegistryHandler is CommonBase, StdUtils {
    LensRegistry public immutable registry;
    ChainInfoStub public immutable chainInfo;
    VerifierStub public immutable verifier;

    uint64 public constant KEY = 1;
    address public constant PROBE = address(0xA11CE);
    address public constant TARGET = address(0x7A6E7);
    address public constant PROBER = address(0xB0B);

    uint64 public frontier;
    /// @dev The highest frontier ever reached. A reorg rewinds `frontier` below heights
    ///      that were legitimately recorded before it, so this is the bound an
    ///      observation must respect — not the current frontier.
    uint64 public highWaterFrontier;
    uint64 private salt;

    /// Feeds the handler cycles through, so several are live at once.
    bytes32[4] public callHashes = [keccak256("feed.a"), keccak256("feed.b"), keccak256("feed.c"), keccak256("feed.d")];

    // What the handler believes, tracked independently of the registry.
    mapping(bytes32 => uint256) public expectedHeight;
    mapping(bytes32 => bool) public expectedFailed;
    mapping(bytes32 => bool) public everRecorded;
    mapping(bytes32 => bool) public queryUsed;
    /// Every query key the handler saw accepted, so the registry can be held to them.
    bytes32[] public acceptedKeys;
    uint256 public accepted;
    uint256 public rejected;

    constructor(LensRegistry r, ChainInfoStub ci, VerifierStub v, uint64 startFrontier) {
        registry = r;
        chainInfo = ci;
        verifier = v;
        frontier = startFrontier;
        highWaterFrontier = startFrontier;
    }

    function acceptedKeyCount() external view returns (uint256) {
        return acceptedKeys.length;
    }

    function feedIdAt(uint256 i) public view returns (bytes32) {
        return registry.feedIdFromCallHash(KEY, TARGET, callHashes[i % 4]);
    }

    /// A proof for a read that succeeded, at an arbitrary height.
    function submitProof(uint256 feedSeed, uint64 heightSeed, bool readSucceeded, bool acceptProof) external {
        uint256 i = feedSeed % 4;
        uint64 height = uint64(bound(heightSeed, 1, frontier + 50)); // sometimes past the frontier
        _submit(i, height, readSucceeded, false, acceptProof, false);
    }

    /// The same proof again, which must never be recorded twice.
    function replayLastProof(uint256 feedSeed, uint64 heightSeed) external {
        uint256 i = feedSeed % 4;
        uint64 height = uint64(bound(heightSeed, 1, frontier));
        _submit(i, height, true, false, true, true);
    }

    /// A read whose returned bytes were cut short.
    function submitTruncated(uint256 feedSeed, uint64 heightSeed) external {
        uint256 i = feedSeed % 4;
        uint64 height = uint64(bound(heightSeed, 1, frontier));
        _submit(i, height, true, true, true, false);
    }

    function advanceFrontier(uint64 by) external {
        frontier += uint64(bound(by, 1, 500));
        if (frontier > highWaterFrontier) highWaterFrontier = frontier;
        chainInfo.setFrontier(KEY, frontier, true);
    }

    /// A source-chain reorg rewinding what Creditcoin had attested.
    function rewindFrontier(uint64 by) external {
        uint64 back = uint64(bound(by, 1, 200));
        frontier = frontier > back ? frontier - back : 1;
        chainInfo.setFrontier(KEY, frontier, true);
    }

    /// @dev Building the transaction and recording the outcome in one function put it
    ///      over the stack limit once the accepted keys were tracked, so they are split.
    function _encodeProbe(uint256 i, uint64 height, bool readSucceeded, bool truncated)
        private
        view
        returns (bytes memory)
    {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            TxFixture.Probe({
                emitter: PROBE,
                signature: registry.PROBED_SIGNATURE(),
                target: TARGET,
                callHash: callHashes[i],
                prober: PROBER,
                success: readSucceeded,
                truncated: truncated,
                height: height,
                timestamp: uint256(height) * 12,
                returnData: truncated ? new bytes(64) : abi.encode(uint256(height))
            })
        );
        return TxFixture.encode(2, 1, logs);
    }

    function _remember(uint256 i, uint64 height, bool readSucceeded, bytes32 queryKey) private {
        bytes32 feedId = registry.feedIdFromCallHash(KEY, TARGET, callHashes[i]);
        accepted++;
        queryUsed[queryKey] = true;
        acceptedKeys.push(queryKey);
        expectedHeight[feedId] = height;
        expectedFailed[feedId] = !readSucceeded;
        everRecorded[feedId] = true;
    }

    function _submit(uint256 i, uint64 height, bool readSucceeded, bool truncated, bool acceptProof, bool reuseSalt)
        private
    {
        if (!reuseSalt) salt++;
        verifier.setTxIndex(salt);
        verifier.setAccept(acceptProof);

        bytes32 root = keccak256(abi.encode("root", salt));
        bytes32 queryKey = keccak256(abi.encode(KEY, height, salt, root));

        try registry.submitProof(
            KEY,
            height,
            _encodeProbe(i, height, readSucceeded, truncated),
            INativeQueryVerifier.MerkleProof({root: root, siblings: new INativeQueryVerifier.MerkleProofEntry[](0)}),
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)})
        ) {
            _remember(i, height, readSucceeded, queryKey);
        } catch {
            rejected++;
        }
    }
}
