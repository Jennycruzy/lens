// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {LensAggregatorV3} from "../../src/LensAggregatorV3.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IChainInfo, ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/**
 * @dev A protocol written against Chainlink, copied in shape from the pattern every
 *      lending market uses. It is not modified in any way to work with Lens, which is
 *      the entire claim being tested.
 */
contract UnmodifiedChainlinkConsumer {
    AggregatorV3Interface public immutable priceFeed;

    constructor(address feed) {
        priceFeed = AggregatorV3Interface(feed);
    }

    /// The canonical Chainlink read, including the staleness check most forks write.
    function getPrice(uint256 maxAgeSeconds) external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "bad price");
        require(block.timestamp - updatedAt <= maxAgeSeconds, "stale price");
        return uint256(answer);
    }

    function collateralValue(uint256 amount) external view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        return (amount * uint256(answer)) / (10 ** priceFeed.decimals());
    }
}

contract LensAggregatorV3Test is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant TARGET = address(0x7A6E7);
    address constant PROBER = address(0xB0B);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;
    uint256 constant MAX_AGE = 200;

    LensRegistry registry;
    LensAggregatorV3 aggregator;
    ChainInfoStub chainInfo;
    VerifierStub verifier;
    bytes32 callHash = keccak256(hex"50d25bcd"); // latestAnswer()
    bytes32 feedId;
    uint64 nextRoot;

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
        aggregator = new LensAggregatorV3(registry, KEY, feedId, 8, MAX_AGE, "ETH / USD");

        vm.warp(SOURCE_TIME + 8 minutes);
    }

    function _record(uint64 height, int256 answer, bool ok, bool truncated, uint64 sourceTime) internal {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE,
            registry.PROBED_SIGNATURE(),
            TARGET,
            callHash,
            PROBER,
            ok,
            truncated,
            height,
            sourceTime,
            truncated ? new bytes(64) : abi.encode(answer)
        );
        verifier.setTxIndex(++nextRoot);
        registry.submitProof(
            KEY,
            height,
            TxFixture.encode(2, 1, logs),
            INativeQueryVerifier.MerkleProof({
                root: keccak256(abi.encode(nextRoot)), siblings: new INativeQueryVerifier.MerkleProofEntry[](0)
            }),
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)})
        );
    }

    function test_readsLikeAChainlinkFeed() public {
        _record(FRONTIER - 20, 2467_03000000, true, false, SOURCE_TIME);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            aggregator.latestRoundData();

        assertEq(answer, 2467_03000000, "the value the source returned");
        assertEq(roundId, FRONTIER - 20, "the round is the source height");
        assertEq(answeredInRound, roundId);
        assertEq(startedAt, updatedAt, "a probe is atomic; there is no round window");
        assertEq(aggregator.decimals(), 8);
        assertEq(aggregator.description(), "ETH / USD");
        assertEq(aggregator.version(), 4);
    }

    /// The whole reason the probe emits a source timestamp.
    function test_updatedAtIsTheSourceClockNotCreditcoins() public {
        _record(FRONTIER - 20, 2467_03000000, true, false, SOURCE_TIME);

        (,,, uint256 updatedAt,) = aggregator.latestRoundData();
        LensRegistry.Observation memory o = registry.observationOf(feedId);

        assertEq(updatedAt, SOURCE_TIME, "the time the read happened");
        assertEq(o.recordedAt, block.timestamp, "not the time the proof landed");
        assertLt(updatedAt, o.recordedAt, "and the source time is the earlier one");
        assertEq(block.timestamp - updatedAt, 8 minutes, "a consumer sees the true age");
    }

    /// Chainlink hands back a stale round and hopes the caller checks. This does not.
    function test_staleFeedRevertsInsteadOfReturningAnOldRound() public {
        _record(FRONTIER - (uint64(MAX_AGE) + 1), 2467_03000000, true, false, SOURCE_TIME);
        vm.expectRevert(abi.encodeWithSelector(LensAggregatorV3.FeedStale.selector, feedId, MAX_AGE + 1, MAX_AGE));
        aggregator.latestRoundData();
    }

    function test_frontierRegressionRefusesTheRound() public {
        _record(FRONTIER - 10, 2467_03000000, true, false, SOURCE_TIME);
        chainInfo.setFrontier(KEY, FRONTIER - 100, true);

        vm.expectRevert(
            abi.encodeWithSelector(LensAggregatorV3.FeedStale.selector, feedId, type(uint256).max, uint256(MAX_AGE))
        );
        aggregator.latestRoundData();
        assertEq(aggregator.ageInBlocks(), type(uint256).max);
    }

    function test_feedAtExactlyMaxAgeIsStillServed() public {
        _record(FRONTIER - uint64(MAX_AGE), 2467_03000000, true, false, SOURCE_TIME);
        (, int256 answer,,,) = aggregator.latestRoundData();
        assertEq(answer, 2467_03000000, "the bound is inclusive");
    }

    function test_feedWithNoObservationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LensAggregatorV3.FeedUnavailable.selector, feedId));
        aggregator.latestRoundData();
    }

    function test_failedSourceReadIsNeverServedAsAPrice() public {
        _record(FRONTIER - 20, 0, false, false, SOURCE_TIME);
        vm.expectRevert(abi.encodeWithSelector(LensAggregatorV3.SourceCallReverted.selector, feedId));
        aggregator.latestRoundData();
    }

    function test_truncatedReadIsNeverServedAsAPrice() public {
        _record(FRONTIER - 20, 0, true, true, SOURCE_TIME);
        vm.expectRevert(abi.encodeWithSelector(LensAggregatorV3.AnswerTruncated.selector, feedId));
        aggregator.latestRoundData();
    }

    function test_historicalRoundsAreRefusedRatherThanFaked() public {
        _record(FRONTIER - 20, 2467_03000000, true, false, SOURCE_TIME);
        uint80 current = uint80(FRONTIER - 20);
        vm.expectRevert(abi.encodeWithSelector(LensAggregatorV3.HistoryNotKept.selector, current - 5, current));
        aggregator.getRoundData(current - 5);
    }

    function test_currentRoundIsServedThroughGetRoundData() public {
        _record(FRONTIER - 20, 2467_03000000, true, false, SOURCE_TIME);
        (, int256 answer,,,) = aggregator.getRoundData(uint80(FRONTIER - 20));
        assertEq(answer, 2467_03000000);
    }

    function test_negativeAnswersRoundTrip() public {
        _record(FRONTIER - 20, -1234, true, false, SOURCE_TIME);
        (, int256 answer,,,) = aggregator.latestRoundData();
        assertEq(answer, -1234, "a signed feed keeps its sign");
    }

    // --- the claim that matters --------------------------------------------------

    /// An unmodified Chainlink-consuming contract, pointed at Lens, with no oracle.
    function test_anUnmodifiedChainlinkConsumerWorksUnchanged() public {
        _record(FRONTIER - 20, 2467_03000000, true, false, SOURCE_TIME);
        UnmodifiedChainlinkConsumer market = new UnmodifiedChainlinkConsumer(address(aggregator));

        assertEq(market.getPrice(1 hours), 2467_03000000, "its own staleness check passes");
        // 3 ETH at 2467.03 USD, carried at the feed's 8 decimals against an 18-decimal
        // amount, is 7401.09 in the amount's units.
        assertEq(market.collateralValue(3 ether), 7401.09 ether, "and it prices collateral");
    }

    /// Its own check catches the lag, because it is measuring the real age.
    function test_theConsumersOwnStalenessCheckSeesTheTrueAge() public {
        _record(FRONTIER - 20, 2467_03000000, true, false, SOURCE_TIME);
        UnmodifiedChainlinkConsumer market = new UnmodifiedChainlinkConsumer(address(aggregator));
        vm.expectRevert("stale price");
        market.getPrice(5 minutes); // the value is 8 minutes old at the source
    }

    /// And when Lens itself refuses, the consumer inherits the refusal rather than
    /// trading on a number nobody will stand behind.
    function test_whenLensRefusesTheConsumerRefusesToo() public {
        _record(FRONTIER - (uint64(MAX_AGE) + 1), 2467_03000000, true, false, SOURCE_TIME);
        UnmodifiedChainlinkConsumer market = new UnmodifiedChainlinkConsumer(address(aggregator));
        vm.expectRevert();
        market.getPrice(365 days); // even a consumer that checks nothing is protected
    }
}
