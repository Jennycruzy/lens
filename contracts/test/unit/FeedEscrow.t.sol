// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {FeedEscrow} from "../../src/FeedEscrow.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {INativeQueryVerifier, NativeQueryVerifierLib} from
    "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

contract FeedEscrowTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    address constant PROBER = address(0xB0B);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;

    LensRegistry registry;
    FeedEscrow escrow;
    ChainInfoStub chainInfo;
    VerifierStub verifier;
    bytes32 callHash = keccak256(hex"18160ddd");
    bytes32 feedId;
    uint64 nonce;

    address funder = address(0xF00D);
    address alice = address(0xA11CE01);
    address bob = address(0xB0B01);

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
        escrow = new FeedEscrow(registry);
        feedId = registry.feedIdFromCallHash(KEY, TARGET, callHash);

        vm.deal(funder, 100 ether);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    function _encodedProbe(uint64 height, uint256 v) internal view returns (bytes memory) {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE, registry.PROBED_SIGNATURE(), TARGET, callHash, PROBER, true, false, height, SOURCE_TIME, abi.encode(v)
        );
        return TxFixture.encode(2, 1, logs);
    }

    function _proof() internal returns (INativeQueryVerifier.MerkleProof memory) {
        verifier.setTxIndex(++nonce);
        return INativeQueryVerifier.MerkleProof({
            root: keccak256(abi.encode(nonce)),
            siblings: new INativeQueryVerifier.MerkleProofEntry[](0)
        });
    }

    function _continuity() internal pure returns (INativeQueryVerifier.ContinuityProof memory) {
        return INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)});
    }

    function _claim(address who, uint64 height, uint256 v) internal returns (uint256 recorded, uint256 paid) {
        bytes memory encoded = _encodedProbe(height, v);
        INativeQueryVerifier.MerkleProof memory mp = _proof();
        vm.prank(who);
        return escrow.submitAndClaim(KEY, height, encoded, mp, _continuity(), feedId);
    }

    function test_funderSetsTheTermsAndTheBalanceIsHeld() public {
        vm.prank(funder);
        escrow.fund{value: 10 ether}(feedId, 0.1 ether, 50);

        FeedEscrow.Funding memory f = escrow.fundingOf(feedId);
        assertEq(f.balance, 10 ether);
        assertEq(f.rewardPerUpdate, 0.1 ether);
        assertEq(f.funder, funder);
    }

    function test_whoeverLandsTheProofTakesTheFee() public {
        vm.prank(funder);
        escrow.fund{value: 10 ether}(feedId, 0.1 ether, 0);

        uint256 before = alice.balance;
        (uint256 recorded, uint256 paid) = _claim(alice, FRONTIER - 100, 1234);

        assertEq(recorded, 1, "the observation landed");
        assertEq(paid, 0.1 ether);
        assertEq(alice.balance, before + 0.1 ether, "paid in the same transaction");
        assertEq(escrow.fundingOf(feedId).balance, 9.9 ether);
    }

    /// The attack the escrow exists to price: withholding only works if everyone does it.
    function test_oneProberDefectingDefeatsWithholdingByTheRest() public {
        vm.prank(funder);
        escrow.fund{value: 10 ether}(feedId, 0.1 ether, 0);

        // Alice and the rest withhold. Bob does not, and the feed updates anyway.
        uint256 before = bob.balance;
        (uint256 recorded, uint256 paid) = _claim(bob, FRONTIER - 100, 4242);

        assertEq(recorded, 1, "the feed updated despite the others withholding");
        assertEq(bob.balance, before + paid, "and the defector was paid for it");
        assertEq(abi.decode(registry.observationOf(feedId).returnData, (uint256)), 4242);
    }

    /// No amount of money buys a wrong answer, because the registry checks the proof.
    function test_payingDoesNotBypassAnyRegistryCheck() public {
        vm.prank(funder);
        escrow.fund{value: 10 ether}(feedId, 0.1 ether, 0);

        verifier.setAccept(false); // the precompile refuses
        bytes memory encoded = _encodedProbe(FRONTIER - 100, 1);
        INativeQueryVerifier.MerkleProof memory mp = _proof();
        vm.prank(alice);
        vm.expectRevert(LensRegistry.ProofRejected.selector);
        escrow.submitAndClaim(KEY, FRONTIER - 100, encoded, mp, _continuity(), feedId);

        assertEq(escrow.fundingOf(feedId).balance, 10 ether, "nothing was paid out");
        assertFalse(registry.hasObservation(feedId), "and nothing was recorded");
    }

    function test_aProberCannotDrainAFeedBySubmittingContinuously() public {
        vm.prank(funder);
        escrow.fund{value: 10 ether}(feedId, 1 ether, 100); // at most one reward per 100 blocks

        (, uint256 first) = _claim(alice, FRONTIER - 300, 1);
        assertEq(first, 1 ether);

        (, uint256 tooSoon) = _claim(alice, FRONTIER - 250, 2); // only 50 blocks later
        assertEq(tooSoon, 0, "inside the interval, so no reward");

        (, uint256 later) = _claim(alice, FRONTIER - 150, 3); // 150 blocks after the first
        assertEq(later, 1 ether, "past the interval, so payable again");
        assertEq(escrow.fundingOf(feedId).balance, 8 ether);
    }

    function test_theWorkStillHappensWhenTheMoneyRunsOut() public {
        vm.prank(funder);
        escrow.fund{value: 0.15 ether}(feedId, 0.1 ether, 0);

        (, uint256 first) = _claim(alice, FRONTIER - 300, 1);
        assertEq(first, 0.1 ether);

        (uint256 recorded, uint256 second) = _claim(alice, FRONTIER - 200, 2);
        assertEq(second, 0.05 ether, "pays out what is left rather than reverting");

        (uint256 recorded3, uint256 third) = _claim(alice, FRONTIER - 100, 3);
        assertEq(third, 0, "nothing left to pay");
        assertEq(recorded3, 1, "but the observation is still recorded");
        assertEq(recorded, 1);
    }

    // --- refunds --------------------------------------------------------------

    function test_funderCannotWithdrawInsideTheTimelock() public {
        vm.startPrank(funder);
        escrow.fund{value: 1 ether}(feedId, 0.1 ether, 0);
        vm.expectRevert(
            abi.encodeWithSelector(FeedEscrow.StillTimelocked.selector, uint64(block.timestamp + 3 days))
        );
        escrow.refund(feedId);
        vm.stopPrank();
    }

    function test_funderGetsTheRemainderBackAfterTheTimelock() public {
        vm.prank(funder);
        escrow.fund{value: 1 ether}(feedId, 0.1 ether, 0);
        _claim(alice, FRONTIER - 100, 1);

        vm.warp(block.timestamp + 3 days + 1);
        uint256 before = funder.balance;
        vm.prank(funder);
        escrow.refund(feedId);
        assertEq(funder.balance, before + 0.9 ether);
    }

    function test_onlyTheFunderCanRefund() public {
        vm.prank(funder);
        escrow.fund{value: 1 ether}(feedId, 0.1 ether, 0);
        vm.warp(block.timestamp + 4 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FeedEscrow.NotTheFunder.selector, alice, funder));
        escrow.refund(feedId);
    }

    /// A stranger topping up must not be able to cut a reward probers are relying on.
    function test_aTopUpFromAnyoneCannotChangeTheTerms() public {
        vm.prank(funder);
        escrow.fund{value: 1 ether}(feedId, 0.1 ether, 0);

        vm.prank(alice);
        escrow.fund{value: 0.5 ether}(feedId, 0.000001 ether, 99999);

        FeedEscrow.Funding memory f = escrow.fundingOf(feedId);
        assertEq(f.rewardPerUpdate, 0.1 ether, "terms unchanged");
        assertEq(f.minBlocksBetweenRewards, 0, "interval unchanged");
        assertEq(f.balance, 1.5 ether, "but the balance grew");
        assertEq(f.funder, funder, "and the funder is still the original");
    }

    function test_anUnfundedFeedStillUpdates() public {
        (uint256 recorded, uint256 paid) = _claim(alice, FRONTIER - 100, 7);
        assertEq(recorded, 1, "proving works without any money at all");
        assertEq(paid, 0);
    }
}
