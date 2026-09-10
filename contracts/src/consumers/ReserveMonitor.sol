// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILensFeed} from "../interfaces/ILensFeed.sol";

/**
 * @title ReserveMonitor
 * @notice Publishes whether an issuer's backing still covers what it has issued.
 *
 * @dev The shape every asset-backed issuer needs and none can currently get on
 *      Creditcoin: reserves held on one chain, tokens issued against them, and a ratio
 *      that anybody can check without being told it by the issuer.
 *
 *      Both legs are proven reads of real contracts. Nobody attests to the reserve
 *      balance — it is read from the token contract that holds it, on the chain where it
 *      is held, and the log proving that read was verified by the precompile.
 *
 *      **It reports insolvency by refusing to say otherwise.** `isSolvent` reverts when
 *      the inputs will not support an answer, rather than returning false. False would
 *      be a claim; a revert is the absence of one. An integrator that cannot tell
 *      "under-collateralised" from "I could not find out" will eventually act on the
 *      wrong one.
 */
contract ReserveMonitor {
    /// @notice reserves / supply, scaled to 1e18. 1e18 is exactly covered.
    ILensFeed public immutable RATIO;

    /// @notice Ratio below which the issuer is considered under-collateralised, 1e18 scale.
    uint256 public immutable MIN_RATIO;

    string private _description;

    /// @dev Latched once breached, because a breach is a fact about history that a later
    ///      top-up does not erase. Anyone reading this should see that it happened.
    bool public everBreached;
    uint256 public worstRatio = type(uint256).max;

    event SolvencyBreached(uint256 ratio, uint256 minimum, uint256 ageBlocks);
    event SolvencyObserved(uint256 ratio, uint256 ageBlocks);

    error FeedRequired();
    error MinimumRequired();
    error CannotDetermineSolvency();

    constructor(ILensFeed ratioFeed, uint256 minRatio, string memory description_) {
        if (address(ratioFeed) == address(0)) revert FeedRequired();
        if (minRatio == 0) revert MinimumRequired();
        RATIO = ratioFeed;
        MIN_RATIO = minRatio;
        _description = description_;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice The current backing ratio, or a revert.
    function ratio() public view returns (uint256 value, uint256 ageBlocks) {
        bool ok;
        (ok, value, ageBlocks) = RATIO.tryRead();
        if (!ok) revert CannotDetermineSolvency();
    }

    /**
     * @notice Whether backing currently covers issuance.
     * @dev Reverts rather than returning false when it cannot tell. Returning false for
     *      an unavailable feed would report an outage as an insolvency, which is its own
     *      kind of false alarm.
     */
    function isSolvent() external view returns (bool) {
        (uint256 value,) = ratio();
        return value >= MIN_RATIO;
    }

    /// @notice Reports solvency without reverting, for monitoring rather than decisions.
    function status() external view returns (bool determinable, bool solvent, uint256 value, uint256 ageBlocks) {
        (determinable, value, ageBlocks) = RATIO.tryRead();
        solvent = determinable && value >= MIN_RATIO;
    }

    /**
     * @notice Record the current ratio, emitting a breach if there is one.
     * @dev Permissionless and argument-free. It reads the feed and reports what it finds,
     *      so the issuer cannot suppress a breach by declining to call it, and nobody can
     *      manufacture one.
     */
    function poke() external returns (uint256 value, bool solvent) {
        uint256 ageBlocks;
        (value, ageBlocks) = ratio();
        solvent = value >= MIN_RATIO;

        if (value < worstRatio) worstRatio = value;

        if (!solvent) {
            everBreached = true;
            emit SolvencyBreached(value, MIN_RATIO, ageBlocks);
        } else {
            emit SolvencyObserved(value, ageBlocks);
        }
    }
}
