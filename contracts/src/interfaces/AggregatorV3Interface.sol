// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title AggregatorV3Interface
 * @notice Chainlink's consumer-facing feed interface, reproduced so that contracts
 *         written against Chainlink compile against Lens without modification.
 *
 * @dev Declared here rather than imported so this repository carries no dependency on
 *      Chainlink's packages. The shape is theirs and is reproduced deliberately: it is
 *      the de-facto standard every lending market, perpetual and vault already speaks.
 */
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
