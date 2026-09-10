// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ILensFeed
 * @notice A value with an age, and the right to refuse.
 *
 * @dev Both a plain registry feed and a composed one satisfy this, which is what lets
 *      composition nest: the median of two ratios is written the same way as the median
 *      of two raw feeds, because neither knows what it is reading.
 *
 *      `ageBlocks` is measured in blocks of the source chain. A composed feed reports
 *      the age of its *stalest* input, never an average — a number is only as current as
 *      the oldest thing it was derived from.
 */
interface ILensFeed {
    /// @notice The value, or a revert. Never a value alongside a warning.
    function read() external view returns (uint256 value, uint256 ageBlocks);

    /// @notice The value, reporting refusal instead of reverting.
    /// @return ok True only when a value is present, whole and inside every bound.
    function tryRead() external view returns (bool ok, uint256 value, uint256 ageBlocks);

    function describe() external view returns (string memory);
}
