// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "./LensRegistry.sol";

/**
 * @title LensLib
 * @notice Reading Lens from a contract that would rather not inherit anything.
 *
 * @dev {LensConsumer} is the better starting point for a new contract: it makes the
 *      freshness bound part of every call and there is no way to forget it. This library
 *      exists for contracts that already have their inheritance settled, and it keeps the
 *      same rule — every function takes a `maxAgeBlocks` and refuses rather than
 *      returning something doubtful.
 *
 *      There is deliberately no function here that returns a value without a bound. One
 *      would be used, and it would be the whole design defeated in a single line.
 */
library LensLib {
    error FeedUnavailable(bytes32 feedId);
    error FeedStale(bytes32 feedId, uint256 age, uint256 maxAge);
    error SourceCallReverted(bytes32 feedId);
    error AnswerTruncated(bytes32 feedId);
    error AnswerWrongWidth(bytes32 feedId, uint256 length);

    /// @notice The identifier of a feed: one chain, one target, one exact call.
    function feedId(LensRegistry lens, uint64 chainKey, address target, bytes memory callData)
        internal
        pure
        returns (bytes32)
    {
        // Hashing here rather than calling keeps this `pure` and costs nothing.
        lens;
        return keccak256(abi.encode(chainKey, target, keccak256(callData)));
    }

    /// @notice Age in source blocks, or max uint when the frontier regressed.
    function ageOf(LensRegistry lens, uint64 chainKey, bytes32 id) internal view returns (uint256) {
        LensRegistry.Observation memory o = lens.observationOf(id);
        uint256 frontier = lens.frontierOf(chainKey);
        return _age(frontier, o.probeHeight);
    }

    /// @notice The freshest bytes for `id`, or a revert.
    function latest(LensRegistry lens, uint64 chainKey, bytes32 id, uint256 maxAgeBlocks)
        internal
        view
        returns (bytes memory)
    {
        if (!lens.hasObservation(id)) revert FeedUnavailable(id);
        LensRegistry.Observation memory o = lens.observationOf(id);
        if (!o.callSucceeded) revert SourceCallReverted(id);
        if (o.truncated) revert AnswerTruncated(id);

        uint256 frontier = lens.frontierOf(chainKey);
        uint256 age = _age(frontier, o.probeHeight);
        if (o.probeHeight > frontier || age > maxAgeBlocks) revert FeedStale(id, age, maxAgeBlocks);

        return o.returnData;
    }

    function latestUint(LensRegistry lens, uint64 chainKey, bytes32 id, uint256 maxAgeBlocks)
        internal
        view
        returns (uint256)
    {
        bytes memory data = latest(lens, chainKey, id, maxAgeBlocks);
        if (data.length != 32) revert AnswerWrongWidth(id, data.length);
        return abi.decode(data, (uint256));
    }

    function latestInt(LensRegistry lens, uint64 chainKey, bytes32 id, uint256 maxAgeBlocks)
        internal
        view
        returns (int256)
    {
        bytes memory data = latest(lens, chainKey, id, maxAgeBlocks);
        if (data.length != 32) revert AnswerWrongWidth(id, data.length);
        return abi.decode(data, (int256));
    }

    function latestAddress(LensRegistry lens, uint64 chainKey, bytes32 id, uint256 maxAgeBlocks)
        internal
        view
        returns (address)
    {
        bytes memory data = latest(lens, chainKey, id, maxAgeBlocks);
        if (data.length != 32) revert AnswerWrongWidth(id, data.length);
        return abi.decode(data, (address));
    }

    /// @notice A read that reports refusal rather than reverting.
    function tryLatest(LensRegistry lens, uint64 chainKey, bytes32 id, uint256 maxAgeBlocks)
        internal
        view
        returns (bool ok, bytes memory data, uint256 age)
    {
        if (!lens.hasObservation(id)) return (false, "", type(uint256).max);
        LensRegistry.Observation memory o = lens.observationOf(id);
        if (!o.callSucceeded || o.truncated) return (false, "", 0);

        uint256 frontier = lens.frontierOf(chainKey);
        age = _age(frontier, o.probeHeight);
        if (o.probeHeight > frontier || age > maxAgeBlocks) return (false, "", age);
        return (true, o.returnData, age);
    }

    function _age(uint256 frontier, uint256 probeHeight) private pure returns (uint256) {
        if (probeHeight > frontier) return type(uint256).max;
        return frontier - probeHeight;
    }
}
