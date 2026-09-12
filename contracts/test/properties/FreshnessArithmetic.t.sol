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
 * @notice The freshness arithmetic, checked at every boundary that matters.
 *
 * @dev **This is exhaustive and randomised, not symbolic.** A symbolic prover would be
 *      the stronger tool here and the specification asks for one; halmos could not be
 *      installed in this environment, so the claim is not made. What is here instead is
 *      every boundary enumerated by hand plus a wide fuzz, which covers the same ground
 *      empirically. The distinction is recorded rather than blurred, because "proved" and
 *      "tested very hard" are different words.
 *
 *      The arithmetic is one subtraction — `frontier - probeHeight` — and it has exactly
 *      one dangerous case: the frontier moving *backwards* below a recorded height after
 *      a source-chain reorg. That observation may no longer be canonical, so the only
 *      safe result is refusal until a newer observation is proven.
 */
contract FreshnessArithmeticTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    uint64 constant SOURCE_TIME = 1_757_000_000;

    LensRegistry registry;
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
    }

    function _record(uint64 frontier, uint64 height) internal {
        chainInfo.setFrontier(KEY, frontier, true);
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE,
            registry.PROBED_SIGNATURE(),
            TARGET,
            callHash,
            address(0xB0B),
            true,
            false,
            height,
            SOURCE_TIME,
            abi.encode(uint256(1))
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

    function _feed(uint256 maxAge) internal returns (RegistryFeed) {
        return new RegistryFeed(registry, KEY, feedId, maxAge, "f");
    }

    /// The reorg case, at every distance a frontier could rewind to.
    function test_everyDegreeOfFrontierRegressionRefuses() public {
        uint64 height = 1_000_000;
        _record(height + 10, height);
        RegistryFeed feed = _feed(type(uint256).max);

        uint64[8] memory rewound = [uint64(999_999), 900_000, 500_000, 1000, 100, 10, 1, 0];
        for (uint256 i = 0; i < rewound.length; i++) {
            chainInfo.setFrontier(KEY, rewound[i], true);
            (bool ok,, uint256 age) = feed.tryRead();
            assertEq(age, type(uint256).max, "regression uses the refusal sentinel");
            assertFalse(ok, "no age bound can admit a possibly reorged observation");
        }
    }

    /// The boundary itself: one below, exactly at, one above.
    function test_theAgeBoundIsInclusiveAtExactlyMaxAge() public {
        uint64 height = 1_000_000;
        uint256 maxAge = 100;
        RegistryFeed feed = _feed(maxAge);

        _record(uint64(height + maxAge - 1), height);
        (bool below,, uint256 ageBelow) = feed.tryRead();
        assertTrue(below);
        assertEq(ageBelow, maxAge - 1);

        chainInfo.setFrontier(KEY, uint64(height + maxAge), true);
        (bool at,, uint256 ageAt) = feed.tryRead();
        assertTrue(at, "exactly at the bound is fresh");
        assertEq(ageAt, maxAge);

        chainInfo.setFrontier(KEY, uint64(height + maxAge + 1), true);
        (bool above,, uint256 ageAbove) = feed.tryRead();
        assertFalse(above, "one past the bound is not");
        assertEq(ageAbove, maxAge + 1);
    }

    /// A bound of zero means only a frontier exactly at the observation will do.
    function test_aZeroBoundAcceptsOnlyTheFrontierItself() public {
        uint64 height = 1_000_000;
        _record(height, height);
        RegistryFeed feed = _feed(0);

        (bool ok,, uint256 age) = feed.tryRead();
        assertTrue(ok);
        assertEq(age, 0);

        chainInfo.setFrontier(KEY, height + 1, true);
        (ok,, age) = feed.tryRead();
        assertFalse(ok, "one block of drift is already too much");
        assertEq(age, 1);
    }

    /// The largest values the types allow, where an unclamped subtraction would wrap.
    function test_extremeHeightsDoNotOverflowOrWrap() public {
        uint64 big = type(uint64).max - 1;
        _record(big, big - 1);
        RegistryFeed feed = _feed(type(uint256).max);

        (bool ok,, uint256 age) = feed.tryRead();
        assertTrue(ok);
        assertEq(age, 1);

        chainInfo.setFrontier(KEY, type(uint64).max, true);
        (,, age) = feed.tryRead();
        assertEq(age, 2, "still an ordinary difference at the top of the range");

        chainInfo.setFrontier(KEY, 0, true);
        uint256 regressedAge;
        (ok,, regressedAge) = feed.tryRead();
        assertFalse(ok, "a regressed frontier is never accepted");
        assertEq(regressedAge, type(uint256).max, "and it cannot wrap or masquerade as fresh");
    }

    /// Nothing about Creditcoin's own clock or height may move the age.
    function test_ageIsIndependentOfCreditcoinTimeAndHeight() public {
        uint64 height = 1_000_000;
        _record(height + 50, height);
        RegistryFeed feed = _feed(1000);

        (,, uint256 before) = feed.tryRead();
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 365 days);
            vm.roll(block.number + 1_000_000);
            (,, uint256 after_) = feed.tryRead();
            assertEq(after_, before, "only the source frontier may change the age");
        }
    }

    /// The whole space, randomly: ordinary age is the source-height difference, while
    /// a regressed frontier always refuses regardless of the caller's bound.
    function testFuzz_ageDifferenceOrRegressionGatesTheRead(uint64 frontier, uint64 height, uint64 maxAge) public {
        height = uint64(bound(height, 1, type(uint64).max - 1));
        RegistryFeed feed = _feed(maxAge);
        _record(height, height); // record while the frontier admits it
        chainInfo.setFrontier(KEY, frontier, true);

        bool regressed = frontier < height;
        uint256 expected = regressed ? type(uint256).max : uint256(frontier) - height;
        (bool ok,, uint256 age) = feed.tryRead();

        assertEq(age, expected, "age is a difference or the regression sentinel");
        assertEq(ok, !regressed && expected <= maxAge, "regression and age jointly gate the read");
    }
}
