// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "./LensRegistry.sol";
import {ILensFeed} from "./interfaces/ILensFeed.sol";

/**
 * @title RegistryFeed
 * @notice Presents one registry observation as an {ILensFeed}, so it can be composed.
 *
 * @dev The adapter that lets everything else in the composition layer stay ignorant of
 *      where a number came from.
 */
contract RegistryFeed is ILensFeed {
    LensRegistry public immutable LENS;
    uint64 public immutable CHAIN_KEY;
    bytes32 public immutable FEED_ID;
    uint256 public immutable MAX_AGE_BLOCKS;
    string private _description;

    error RegistryRequired();
    error FeedUnavailable(bytes32 feedId);
    error FeedStale(bytes32 feedId, uint256 age, uint256 maxAge);
    error SourceCallReverted(bytes32 feedId);
    error AnswerTruncated(bytes32 feedId);
    error AnswerWrongWidth(uint256 length);

    constructor(
        LensRegistry registry,
        uint64 chainKey,
        bytes32 feedId,
        uint256 maxAgeBlocks,
        string memory feedDescription
    ) {
        if (address(registry) == address(0)) revert RegistryRequired();
        LENS = registry;
        CHAIN_KEY = chainKey;
        FEED_ID = feedId;
        MAX_AGE_BLOCKS = maxAgeBlocks;
        _description = feedDescription;
    }

    function read() external view returns (uint256 value, uint256 ageBlocks) {
        if (!LENS.hasObservation(FEED_ID)) revert FeedUnavailable(FEED_ID);
        LensRegistry.Observation memory o = LENS.observationOf(FEED_ID);
        if (!o.callSucceeded) revert SourceCallReverted(FEED_ID);
        if (o.truncated) revert AnswerTruncated(FEED_ID);
        if (o.returnData.length != 32) revert AnswerWrongWidth(o.returnData.length);

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        ageBlocks = _age(frontier, o.probeHeight);
        if (o.probeHeight > frontier || ageBlocks > MAX_AGE_BLOCKS) {
            revert FeedStale(FEED_ID, ageBlocks, MAX_AGE_BLOCKS);
        }

        value = abi.decode(o.returnData, (uint256));
    }

    function tryRead() external view returns (bool ok, uint256 value, uint256 ageBlocks) {
        if (!LENS.hasObservation(FEED_ID)) return (false, 0, type(uint256).max);
        LensRegistry.Observation memory o = LENS.observationOf(FEED_ID);
        if (!o.callSucceeded || o.truncated || o.returnData.length != 32) return (false, 0, type(uint256).max);

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        ageBlocks = _age(frontier, o.probeHeight);
        if (o.probeHeight > frontier || ageBlocks > MAX_AGE_BLOCKS) return (false, 0, ageBlocks);

        return (true, abi.decode(o.returnData, (uint256)), ageBlocks);
    }

    function describe() external view returns (string memory) {
        return _description;
    }

    function _age(uint256 frontier, uint256 probeHeight) private pure returns (uint256) {
        if (probeHeight > frontier) return type(uint256).max;
        return frontier - probeHeight;
    }
}
