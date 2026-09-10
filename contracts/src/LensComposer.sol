// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILensFeed} from "./interfaces/ILensFeed.sol";

/**
 * @title MedianFeed
 * @notice The median of several feeds, which are themselves feeds.
 *
 * @dev Two uses, and they are the same contract because the shape is the same.
 *
 *      **Across probers.** The same target read by several independent probers. No one
 *      of them can move the answer, so withholding by a minority costs nothing and a
 *      minority reporting oddly is outvoted. Note that correctness never depended on
 *      this — each leg is already cryptographic — so the median buys liveness and
 *      robustness, not trust.
 *
 *      **Across source chains.** The same asset on Ethereum and on Sepolia, and any
 *      chain attested later. Genuine multi-chain aggregation where every leg is proven
 *      rather than reported.
 *
 *      **The age of a median is the age of its stalest input.** Averaging ages, or
 *      taking the freshest, would let one current leg disguise several stale ones. A
 *      derived number cannot be more current than the oldest thing it derives from, and
 *      this is one of the properties the invariant suite enforces.
 */
contract MedianFeed is ILensFeed {
    ILensFeed[] private _inputs;

    /// @notice How many inputs must answer for a median to be produced.
    uint256 public immutable QUORUM;

    string private _description;

    error NotEnoughInputs(uint256 given, uint256 quorum);
    error QuorumRequired();
    error NoQuorum(uint256 answered, uint256 quorum);

    constructor(ILensFeed[] memory feeds, uint256 quorum, string memory description_) {
        if (quorum == 0) revert QuorumRequired();
        if (feeds.length < quorum) revert NotEnoughInputs(feeds.length, quorum);
        _inputs = feeds;
        QUORUM = quorum;
        _description = description_;
    }

    function inputs() external view returns (ILensFeed[] memory) {
        return _inputs;
    }

    function read() external view returns (uint256 value, uint256 ageBlocks) {
        bool ok;
        (ok, value, ageBlocks) = _median();
        if (!ok) revert NoQuorum(_answering(), QUORUM);
    }

    function tryRead() external view returns (bool ok, uint256 value, uint256 ageBlocks) {
        return _median();
    }

    function describe() external view returns (string memory) {
        return _description;
    }

    function _answering() private view returns (uint256 n) {
        for (uint256 i = 0; i < _inputs.length; ++i) {
            (bool ok,,) = _inputs[i].tryRead();
            if (ok) ++n;
        }
    }

    /**
     * @dev Collects whatever answers, sorts, and takes the middle. Inputs that refuse
     *      are skipped rather than counted as zero — a refusal is an absence of a value,
     *      and treating it as a number would drag the median toward zero, which is the
     *      most dangerous direction for a price to move.
     */
    function _median() private view returns (bool ok, uint256 value, uint256 ageBlocks) {
        uint256 n = _inputs.length;
        uint256[] memory values = new uint256[](n);
        uint256 count;
        uint256 stalest;

        for (uint256 i = 0; i < n; ++i) {
            (bool answered, uint256 v, uint256 age) = _inputs[i].tryRead();
            if (!answered) continue;
            values[count++] = v;
            if (age > stalest) stalest = age;
        }

        if (count < QUORUM) return (false, 0, type(uint256).max);

        // Insertion sort. The input count is small and fixed at construction.
        for (uint256 i = 1; i < count; ++i) {
            uint256 key = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > key) {
                values[j] = values[j - 1];
                --j;
            }
            values[j] = key;
        }

        // An even count averages the middle pair, which is the ordinary convention and
        // avoids favouring either side arbitrarily.
        value = count % 2 == 1
            ? values[count / 2]
            : (values[count / 2 - 1] + values[count / 2]) / 2;

        return (true, value, stalest);
    }
}

/**
 * @title RatioFeed
 * @notice One feed divided by another, scaled.
 *
 * @dev The shape behind a solvency ratio, a cross rate, or a collateralisation figure:
 *      reserves over supply, one asset over another. Both legs are proven reads, so the
 *      ratio inherits that rather than being reported by anyone.
 */
contract RatioFeed is ILensFeed {
    ILensFeed public immutable NUMERATOR;
    ILensFeed public immutable DENOMINATOR;

    /// @notice Fixed-point scale of the result, e.g. 1e18.
    uint256 public immutable SCALE;

    string private _description;

    error FeedRequired();
    error ScaleRequired();
    error DenominatorIsZero();
    error InputRefused();

    constructor(ILensFeed numerator, ILensFeed denominator, uint256 scale, string memory description_) {
        if (address(numerator) == address(0) || address(denominator) == address(0)) revert FeedRequired();
        if (scale == 0) revert ScaleRequired();
        NUMERATOR = numerator;
        DENOMINATOR = denominator;
        SCALE = scale;
        _description = description_;
    }

    function read() external view returns (uint256 value, uint256 ageBlocks) {
        bool ok;
        (ok, value, ageBlocks) = _ratio();
        if (!ok) revert InputRefused();
    }

    function tryRead() external view returns (bool ok, uint256 value, uint256 ageBlocks) {
        return _ratio();
    }

    function describe() external view returns (string memory) {
        return _description;
    }

    function _ratio() private view returns (bool ok, uint256 value, uint256 ageBlocks) {
        (bool nOk, uint256 n, uint256 nAge) = NUMERATOR.tryRead();
        (bool dOk, uint256 d, uint256 dAge) = DENOMINATOR.tryRead();

        // Either leg refusing refuses the whole ratio. There is no partial answer.
        if (!nOk || !dOk) return (false, 0, type(uint256).max);
        if (d == 0) return (false, 0, type(uint256).max);

        // The stalest leg, never the average, sets the age of the result.
        ageBlocks = nAge > dAge ? nAge : dAge;

        // Scale before dividing so precision is not lost in the division.
        value = (n * SCALE) / d;
        return (true, value, ageBlocks);
    }
}
