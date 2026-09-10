// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "./LensRegistry.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/**
 * @title LensAggregatorV3
 * @notice Presents one Lens feed through Chainlink's `AggregatorV3Interface`.
 *
 * @dev A protocol written against Chainlink runs against Lens by changing one address.
 *      No fork of the protocol, no new interface for anyone to learn, no oracle behind
 *      it — the number comes from a read that happened on the source chain and was
 *      proven here.
 *
 *      **`updatedAt` is the source chain's clock, never Creditcoin's.** Downstream
 *      protocols liquidate on that field, and the two clocks are minutes apart because
 *      the attestation lag sits between them. Reporting the moment the proof landed
 *      would tell a consumer the price is current when it describes a block from eight
 *      minutes ago. This contract reports the time the read actually happened, so a
 *      Chainlink-shaped staleness check measures the real age of the number.
 *
 *      **Staleness reverts.** Chainlink returns a stale round and trusts the caller to
 *      notice. Most callers do not. Here a feed older than `maxAge` is refused, so a
 *      protocol that forgot to check is protected by the feed rather than by its own
 *      diligence. That is a deliberate difference from Chainlink and it is the safe
 *      direction to differ in.
 */
contract LensAggregatorV3 is AggregatorV3Interface {
    LensRegistry public immutable LENS;
    bytes32 public immutable FEED_ID;
    uint64 public immutable CHAIN_KEY;

    /// @notice Largest acceptable age, in blocks of the source chain.
    uint256 public immutable MAX_AGE_BLOCKS;

    uint8 private immutable _decimals;
    string private _description;

    /// @dev Chainlink's own aggregators report 4 here, and consumers that check it at
    ///      all check for that. Reporting something else breaks them for no benefit.
    uint256 public constant override version = 4;

    error RegistryRequired();
    error FeedUnavailable(bytes32 feedId);
    error FeedStale(bytes32 feedId, uint256 ageBlocks, uint256 maxAgeBlocks);
    error SourceCallReverted(bytes32 feedId);
    error AnswerTruncated(bytes32 feedId);
    error AnswerWrongWidth(bytes32 feedId, uint256 length);
    error AnswerOutOfRange(uint256 raw);
    error HistoryNotKept(uint80 requested, uint80 available);

    constructor(
        LensRegistry registry,
        uint64 chainKey,
        bytes32 feedId,
        uint8 feedDecimals,
        uint256 maxAgeBlocks,
        string memory feedDescription
    ) {
        if (address(registry) == address(0)) revert RegistryRequired();
        LENS = registry;
        CHAIN_KEY = chainKey;
        FEED_ID = feedId;
        _decimals = feedDecimals;
        MAX_AGE_BLOCKS = maxAgeBlocks;
        _description = feedDescription;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    /**
     * @notice The latest answer, or a revert.
     * @return roundId         The source-chain height the read happened at.
     * @return answer          The value, decoded as a signed 256-bit integer.
     * @return startedAt       Source-chain time of the read.
     * @return updatedAt       Source-chain time of the read. Never Creditcoin's clock.
     * @return answeredInRound Equal to `roundId`; there is no carry-forward here.
     *
     * @dev `startedAt` and `updatedAt` are the same instant because a probe is atomic:
     *      the read begins and completes inside one source-chain transaction. Chainlink
     *      separates them because an aggregation round collects submissions over time.
     *      There is no such window here, and inventing a gap would be fiction.
     */
    function latestRoundData()
        public
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (!LENS.hasObservation(FEED_ID)) revert FeedUnavailable(FEED_ID);
        LensRegistry.Observation memory o = LENS.observationOf(FEED_ID);

        // A read that reverted on the source chain is a proven absence of a value.
        if (!o.callSucceeded) revert SourceCallReverted(FEED_ID);
        // A truncated result decodes to a plausible, wrong number.
        if (o.truncated) revert AnswerTruncated(FEED_ID);

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        uint256 age = frontier > o.probeHeight ? frontier - o.probeHeight : 0;
        if (age > MAX_AGE_BLOCKS) revert FeedStale(FEED_ID, age, MAX_AGE_BLOCKS);

        if (o.returnData.length != 32) revert AnswerWrongWidth(FEED_ID, o.returnData.length);
        answer = _toInt256(o.returnData);

        roundId = _roundId(o.probeHeight);
        startedAt = o.sourceTimestamp;
        updatedAt = o.sourceTimestamp;
        answeredInRound = roundId;
    }

    /**
     * @notice Historical rounds are not served.
     * @dev The registry deliberately keeps only the newest observation per feed, so
     *      there is no honest answer to give for an older round. Returning the current
     *      one under a past round id would be a lie a lending market could liquidate on,
     *      so this reverts and says what it does have. History is available off-chain
     *      from the indexer, and verifiably on-chain through a checkpointed target.
     */
    function getRoundData(uint80 _round)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = latestRoundData();
        if (_round != roundId) revert HistoryNotKept(_round, roundId);
    }

    /// @notice Age of the feed in blocks of its source chain, without reverting.
    /// @dev For monitoring. A consumer deciding whether to act uses {latestRoundData},
    ///      which refuses rather than reporting.
    function ageInBlocks() external view returns (uint256) {
        if (!LENS.hasObservation(FEED_ID)) return type(uint256).max;
        LensRegistry.Observation memory o = LENS.observationOf(FEED_ID);
        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        return frontier > o.probeHeight ? frontier - o.probeHeight : 0;
    }

    /// @dev A source height cannot exceed 80 bits for any real chain, but the cast is
    ///      checked rather than assumed, because a silent wrap would make an old round
    ///      look new.
    function _roundId(uint256 probeHeight) private pure returns (uint80) {
        if (probeHeight > type(uint80).max) revert AnswerOutOfRange(probeHeight);
        return uint80(probeHeight);
    }

    /// @dev Decodes as `int256`, which is what Chainlink's `answer` is. A feed whose
    ///      target returns an unsigned value simply never sets the high bit; one that
    ///      returns a signed value round-trips correctly.
    function _toInt256(bytes memory data) private pure returns (int256 value) {
        assembly ("memory-safe") {
            value := mload(add(data, 0x20))
        }
    }
}
