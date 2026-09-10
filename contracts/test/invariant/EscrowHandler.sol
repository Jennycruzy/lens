// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {FeedEscrow} from "../../src/FeedEscrow.sol";
import {INativeQueryVerifier} from
    "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/// @notice Funds, claims and refunds against the escrow in whatever order the fuzzer
///         chooses, tracking what was put in and what came out.
contract EscrowHandler is CommonBase, StdUtils {
    LensRegistry public immutable registry;
    FeedEscrow public immutable escrow;
    ChainInfoStub public immutable chainInfo;
    VerifierStub public immutable verifier;

    uint64 public constant KEY = 1;
    address public constant PROBE = address(0xA11CE);
    address public constant TARGET = address(0x7A6E7);

    bytes32 public immutable FEED;
    bytes32 private constant CALL_HASH = keccak256("escrow.feed");

    uint64 public frontier;
    uint64 private salt;

    uint256 public totalFunded;
    uint256 public totalPaidOut;
    uint256 public totalRefunded;

    constructor(LensRegistry r, FeedEscrow e, ChainInfoStub ci, VerifierStub v, uint64 startFrontier) {
        registry = r;
        escrow = e;
        chainInfo = ci;
        verifier = v;
        frontier = startFrontier;
        FEED = r.feedIdFromCallHash(KEY, TARGET, CALL_HASH);
    }

    receive() external payable {}

    function fund(uint96 amount, uint96 reward, uint16 interval) external {
        uint256 value = bound(amount, 1, 10 ether);
        uint256 r = bound(reward, 1, 1 ether);
        if (address(this).balance < value) return;
        try escrow.fund{value: value}(FEED, r, uint64(bound(interval, 0, 500))) {
            totalFunded += value;
        } catch {}
    }

    function claim(uint64 heightSeed) external {
        uint64 height = uint64(bound(heightSeed, 1, frontier));
        uint256 before = address(this).balance;

        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE, registry.PROBED_SIGNATURE(), TARGET, CALL_HASH, address(this),
            true, false, height, uint256(height) * 12, abi.encode(uint256(height))
        );
        verifier.setTxIndex(++salt);

        try escrow.submitAndClaim(
            KEY, height, TxFixture.encode(2, 1, logs),
            INativeQueryVerifier.MerkleProof({
                root: keccak256(abi.encode("r", salt)),
                siblings: new INativeQueryVerifier.MerkleProofEntry[](0)
            }),
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)}),
            FEED
        ) {
            totalPaidOut += address(this).balance - before;
        } catch {}
    }

    function refund(uint32 warp) external {
        vm.warp(block.timestamp + bound(warp, 0, 10 days));
        uint256 before = address(this).balance;
        try escrow.refund(FEED) {
            totalRefunded += address(this).balance - before;
        } catch {}
    }

    function advanceFrontier(uint16 by) external {
        frontier += uint64(bound(by, 1, 400));
        chainInfo.setFrontier(KEY, frontier, true);
    }
}
