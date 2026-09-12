// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "./LensRegistry.sol";

/**
 * @title CircuitBreaker
 * @notice Refuses a feed that has started behaving in a way no consumer should trade on.
 *
 * @dev **There is no owner and no pause key.** Nobody can trip this and nobody can
 *      untrip it. Every transition is a function of what the registry holds and what
 *      ChainInfo reports, so the breaker's state is reproducible by anyone reading the
 *      chain. An oracle with a pause key is a party you have to trust; this is the
 *      differentiator against the thing Lens replaces, so it is not compromised for
 *      operational convenience.
 *
 *      Three conditions trip it, and each answers a different question.
 *
 *      **Deviation.** The value moved further in one update than the bound allows.
 *      Either the source really moved that far, in which case pausing briefly costs
 *      little, or something is wrong, in which case trading on it costs a great deal.
 *
 *      **Frontier regression.** The attested frontier has fallen below a height already
 *      recorded. That is the on-chain signature of a source-chain reorg: the block the
 *      value came from may no longer be on the canonical chain. This condition was not
 *      designed from the specification — it was found by an invariant run, where an
 *      observation legitimately came to sit above the current frontier after a rewind.
 *
 *      **Age.** The feed has gone past a hard limit well beyond any consumer's own
 *      `maxAge`. A consumer's bound is its own business; this is the point at which the
 *      feed itself stops claiming to mean anything.
 *
 *      Untripping requires a fresh observation that is inside every bound. The breaker
 *      does not time out, because time passing is not evidence that anything improved.
 */
contract CircuitBreaker {
    LensRegistry public immutable LENS;
    uint64 public immutable CHAIN_KEY;
    bytes32 public immutable FEED_ID;

    /// @notice Largest permitted move between consecutive observations, in basis points.
    uint256 public immutable MAX_DEVIATION_BPS;

    /// @notice Age at which the feed stops meaning anything, in source-chain blocks.
    uint256 public immutable MAX_AGE_BLOCKS;

    uint256 private constant BPS = 10_000;

    enum Reason {
        None,
        Deviation,
        FrontierRegression,
        Age
    }

    struct State {
        bool tripped;
        Reason reason;
        uint256 lastValue;
        uint256 lastHeight;
        uint64 trippedAt;
        /// @dev The value that caused a deviation trip. A second observation near it
        ///      confirms the move was real, which is what allows the feed to resume.
        uint256 pendingValue;
        /// @dev Observation height that established the current trip condition.
        ///      Recovery requires a strictly newer observation.
        uint256 tripHeight;
    }

    State private _state;

    event Tripped(Reason reason, uint256 observed, uint256 previous, uint256 height);
    event Restored(uint256 value, uint256 height);

    error RegistryRequired();
    error DeviationBoundRequired();
    error BreakerTripped(Reason reason, uint64 since);
    error FeedUnavailable(bytes32 feedId);
    error SourceCallReverted(bytes32 feedId);
    error AnswerTruncated(bytes32 feedId);
    error AnswerWrongWidth(uint256 length);

    constructor(LensRegistry registry, uint64 chainKey, bytes32 feedId, uint256 maxDeviationBps, uint256 maxAgeBlocks) {
        if (address(registry) == address(0)) revert RegistryRequired();
        if (maxDeviationBps == 0) revert DeviationBoundRequired();
        LENS = registry;
        CHAIN_KEY = chainKey;
        FEED_ID = feedId;
        MAX_DEVIATION_BPS = maxDeviationBps;
        MAX_AGE_BLOCKS = maxAgeBlocks;
    }

    /**
     * @notice The value, if the breaker permits it.
     * @dev Reverts while tripped. A consumer cannot opt out of the breaker by catching
     *      the revert and carrying on, because there is no variant of this that returns
     *      a value alongside a warning.
     */
    function value() external view returns (uint256 observed, uint256 height) {
        (Reason reason, bool haveValue, uint256 v, uint256 h) = _evaluate();
        if (reason != Reason.None) revert BreakerTripped(reason, _state.trippedAt);
        if (_state.tripped) revert BreakerTripped(_state.reason, _state.trippedAt);
        // Absence is not a fault, but it is also not a value. Returning zero here would
        // hand a consumer a number that never existed.
        if (!haveValue) revert FeedUnavailable(FEED_ID);
        return (v, h);
    }

    /// @notice Whether a read would be refused right now, without reverting.
    function status() external view returns (bool tripped, Reason reason) {
        (Reason live,,,) = _evaluate();
        if (live != Reason.None) return (true, live);
        if (_state.tripped) return (true, _state.reason);
        return (false, Reason.None);
    }

    function state() external view returns (State memory) {
        return _state;
    }

    /**
     * @notice Records the current observation, tripping or restoring as the facts require.
     * @dev Permissionless, because it takes no argument a caller could lie about. It
     *      reads the registry and ChainInfo and does what they say. Anyone may call it,
     *      including the consumer that is about to read, and nobody can prevent it.
     */
    function poke() external returns (bool tripped, Reason reason) {
        uint256 previous = _state.lastValue;
        (Reason live, bool haveValue, uint256 v, uint256 h) = _evaluate();

        if (live != Reason.None) {
            bool firstTrip = !_state.tripped;
            bool changedReason = _state.reason != live;
            bool newerDeviationCandidate = live == Reason.Deviation && h > _state.tripHeight;
            if (firstTrip || changedReason || newerDeviationCandidate) {
                _state.tripped = true;
                _state.reason = live;
                if (firstTrip) _state.trippedAt = uint64(block.timestamp);
                _state.tripHeight = h;
                _state.pendingValue = live == Reason.Deviation ? v : 0;
                emit Tripped(live, v, previous, h);
            }
            return (true, live);
        }

        if (!haveValue) return (_state.tripped, _state.reason);

        // A frontier catching up, or a second poke of the same deviating observation,
        // is not new evidence. Recovery always needs a strictly newer observation.
        if (_state.tripped && h <= _state.tripHeight) return (true, _state.reason);

        // Inside every bound. Record it, and restore if the breaker was tripped.
        if (_state.tripped) {
            _state.tripped = false;
            _state.reason = Reason.None;
            _state.trippedAt = 0;
            _state.pendingValue = 0;
            _state.tripHeight = 0;
            emit Restored(v, h);
        }
        _state.lastValue = v;
        _state.lastHeight = h;
        return (false, Reason.None);
    }

    // -------------------------------------------------------------------------

    /**
     * @dev Works out whether anything is wrong right now, without writing.
     *      Order matters: a regressed frontier is checked before age, because after a
     *      rewind the age computation describes a chain state that may no longer exist.
     */
    function _evaluate() private view returns (Reason reason, bool haveValue, uint256 v, uint256 h) {
        if (!LENS.hasObservation(FEED_ID)) return (Reason.None, false, 0, 0);

        LensRegistry.Observation memory o = LENS.observationOf(FEED_ID);
        if (!o.callSucceeded || o.truncated) return (Reason.None, false, 0, o.probeHeight);
        if (o.returnData.length != 32) return (Reason.None, false, 0, o.probeHeight);

        v = abi.decode(o.returnData, (uint256));
        h = o.probeHeight;

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        if (frontier < o.probeHeight) return (Reason.FrontierRegression, true, v, h);

        if (frontier - o.probeHeight > MAX_AGE_BLOCKS) return (Reason.Age, true, v, h);

        // Deviation is only meaningful once there is something to deviate from, and
        // only against a *different* observation.
        if (_state.lastHeight != 0 && h != _state.lastHeight && _state.lastValue != 0) {
            bool nearLast = _within(v, _state.lastValue);
            // A held tripping value gives the move a second chance to be confirmed.
            bool nearPending = _state.tripped && _state.reason == Reason.Deviation && _state.pendingValue != 0
                && h > _state.tripHeight && _within(v, _state.pendingValue);
            if (!nearLast && !nearPending) return (Reason.Deviation, true, v, h);
        }

        return (Reason.None, true, v, h);
    }

    function _within(uint256 v, uint256 baseline) private view returns (bool) {
        if (baseline == 0) return true;
        uint256 diff = v > baseline ? v - baseline : baseline - v;
        // Refuse extreme values rather than letting multiplication wrap and falsely
        // classify a violent move as inside the bound.
        if (diff > type(uint256).max / BPS) return false;
        return (diff * BPS) / baseline <= MAX_DEVIATION_BPS;
    }
}
