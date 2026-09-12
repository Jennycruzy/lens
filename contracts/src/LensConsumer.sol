// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "./LensRegistry.sol";

/**
 * @title LensConsumer
 * @notice The standard a contract inherits to read a Lens feed safely.
 *
 * @dev Safety lives here rather than in the probe, because the probe cannot know what
 *      staleness means to any particular reader. A thirty-minute average tolerates an
 *      hour of lag; a solvency check might tolerate a day; a liquidation tolerates
 *      almost none.
 *
 *      **Fail closed.** No path in this contract returns a value a caller could believe
 *      is fresh when it is not. Every read either satisfies the caller's own freshness
 *      bound or reverts. {_tryLatest} is the single exception, and it hands back an
 *      explicit `ok` flag rather than a value, so the refusal cannot be missed.
 *
 *      **Age is measured in source-chain blocks.** It is `frontier - probeHeight`: how
 *      far behind the attested head of the source chain this observation sits. It is
 *      never wall-clock time and never a Creditcoin height. Both of those would drift
 *      against the thing the value actually describes, and a Creditcoin height says
 *      nothing at all about how old an Ethereum read is.
 */
abstract contract LensConsumer {
    LensRegistry public immutable LENS;

    error RegistryRequired();
    error FeedUnavailable(bytes32 feedId);
    error FeedStale(bytes32 feedId, uint256 age, uint256 maxAge);
    error FeedReadFailed(bytes32 feedId);
    error FeedTruncated(bytes32 feedId);
    error FeedWrongWidth(bytes32 feedId, uint256 length, uint256 expected);

    constructor(LensRegistry registry) {
        if (address(registry) == address(0)) revert RegistryRequired();
        LENS = registry;
    }

    /**
     * @notice The freshest bytes for `id`, or a revert.
     * @param maxAge Largest acceptable age, in blocks of the source chain.
     *
     * @dev Four distinct refusals, deliberately not collapsed into one. A caller that
     *      cannot tell a stale feed from a failed read from an absent one cannot react
     *      correctly to any of them.
     */
    function _latest(bytes32 id, uint256 maxAge) internal view returns (bytes memory) {
        (bool ok, bytes memory data, uint256 age, RefusalReason reason) = _read(id, maxAge);
        if (ok) return data;
        if (reason == RefusalReason.Missing) revert FeedUnavailable(id);
        if (reason == RefusalReason.CallReverted) revert FeedReadFailed(id);
        if (reason == RefusalReason.Truncated) revert FeedTruncated(id);
        revert FeedStale(id, age, maxAge);
    }

    function _latestUint(bytes32 id, uint256 maxAge) internal view returns (uint256) {
        bytes memory data = _latest(id, maxAge);
        if (data.length != 32) revert FeedWrongWidth(id, data.length, 32);
        return abi.decode(data, (uint256));
    }

    function _latestAddress(bytes32 id, uint256 maxAge) internal view returns (address) {
        bytes memory data = _latest(id, maxAge);
        if (data.length != 32) revert FeedWrongWidth(id, data.length, 32);
        return abi.decode(data, (address));
    }

    function _latestBool(bytes32 id, uint256 maxAge) internal view returns (bool) {
        bytes memory data = _latest(id, maxAge);
        if (data.length != 32) revert FeedWrongWidth(id, data.length, 32);
        return abi.decode(data, (bool));
    }

    /**
     * @notice A read that reports refusal instead of reverting.
     * @return ok   True only when the value is present, succeeded, whole, and fresh.
     * @return data Empty unless `ok`. A refused read never carries a value, so it
     *              cannot be used by accident.
     * @return age  Age in source-chain blocks, reported even when refusing, so a caller
     *              can log or degrade rather than guess.
     */
    function _tryLatest(bytes32 id, uint256 maxAge) internal view returns (bool ok, bytes memory data, uint256 age) {
        (ok, data, age,) = _read(id, maxAge);
    }

    /// @notice Age of a feed in blocks of its source chain.
    function _ageOf(bytes32 id, uint64 chainKey) internal view returns (uint256) {
        LensRegistry.Observation memory o = LENS.observationOf(id);
        return _age(LENS.frontierOf(chainKey), o.probeHeight);
    }

    enum RefusalReason {
        None,
        Missing,
        CallReverted,
        Truncated,
        Stale
    }

    function _read(bytes32 id, uint256 maxAge)
        private
        view
        returns (bool ok, bytes memory data, uint256 age, RefusalReason reason)
    {
        if (!LENS.hasObservation(id)) return (false, "", type(uint256).max, RefusalReason.Missing);

        LensRegistry.Observation memory o = LENS.observationOf(id);

        // A read that reverted on the source chain is a proven fact, and it is proven
        // to be the absence of a value. It is never surfaced as one.
        if (!o.callSucceeded) return (false, "", 0, RefusalReason.CallReverted);

        // A truncated result is a prefix of the real answer. Decoding a prefix yields a
        // number that looks plausible and is wrong, which is the worst outcome available.
        if (o.truncated) return (false, "", 0, RefusalReason.Truncated);

        uint64 frontier = LENS.frontierOf(_chainKeyOf(id, o));
        age = _age(frontier, o.probeHeight);
        if (o.probeHeight > frontier || age > maxAge) return (false, "", age, RefusalReason.Stale);

        return (true, o.returnData, age, RefusalReason.None);
    }

    /**
     * @dev A frontier below the observation means the proven block may have been
     *      reorged away. It is not age zero. The maximum value is an unambiguous
     *      refusal sentinel: strict reads revert stale and try-reads return false.
     */
    function _age(uint64 frontier, uint256 probeHeight) private pure returns (uint256) {
        if (probeHeight > frontier) return type(uint256).max;
        return uint256(frontier) - probeHeight;
    }

    /**
     * @dev Which chain a feed belongs to is fixed when the feed is defined. A consumer
     *      that reads feeds from more than one source overrides this.
     */
    function _chainKeyOf(bytes32, LensRegistry.Observation memory) internal view virtual returns (uint64) {
        return _defaultChainKey();
    }

    function _defaultChainKey() internal view virtual returns (uint64);
}
