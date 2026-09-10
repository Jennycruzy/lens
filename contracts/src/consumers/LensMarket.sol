// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/**
 * @title LensMarket
 * @notice A minimal collateralised lending market, priced entirely through Lens.
 *
 * @dev The market is not the point. The point is that it is written the way every
 *      Chainlink-consuming market is written — `latestRoundData`, a staleness check, a
 *      health factor, a liquidation — and there is no oracle behind it. The price comes
 *      from a read that happened on another chain and was proven here.
 *
 *      Nothing in this file knows what Lens is. It holds an `AggregatorV3Interface` and
 *      calls it. Point it at a Chainlink aggregator and it behaves identically, which is
 *      the claim: **port any Chainlink-consuming protocol by changing one address.**
 *
 *      Deliberately small: single collateral, single borrowable, no interest accrual, no
 *      reserve factor. Those would add lines without adding evidence, and every line
 *      here exists to show a price arriving and being acted upon.
 */
contract LensMarket {
    AggregatorV3Interface public immutable PRICE_FEED;

    /// @notice Collateral required per unit borrowed, in basis points. 15000 = 150%.
    uint256 public immutable COLLATERAL_RATIO_BPS;

    /// @notice Health factor below which a position may be liquidated, 1e18 scale.
    uint256 public constant LIQUIDATION_THRESHOLD = 1e18;

    /// @notice Discount a liquidator receives on seized collateral, in basis points.
    uint256 public immutable LIQUIDATION_BONUS_BPS;

    /// @notice Oldest price this market will act on, in seconds.
    uint256 public immutable MAX_PRICE_AGE;

    /// @notice 10 ** the feed's decimals, read from the feed at construction.
    /// @dev Never assumed. A Chainlink USD feed reports 8 decimals while balances and
    ///      debt here are 18, and multiplying the two without dividing this out leaves
    ///      every value off by ten orders of magnitude — small enough to look like a
    ///      plausible number and large enough to liquidate everyone.
    uint256 public immutable PRICE_UNIT;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    struct Position {
        uint256 collateral; // wei of the collateral asset
        uint256 debt; // units of the borrowed asset, 1e18 scale
    }

    mapping(address => Position) public positions;
    uint256 public totalDebt;

    event Deposited(address indexed who, uint256 amount);
    event Borrowed(address indexed who, uint256 amount, uint256 price);
    event Repaid(address indexed who, uint256 amount);
    event Withdrawn(address indexed who, uint256 amount);
    event Liquidated(address indexed who, address indexed by, uint256 debtRepaid, uint256 collateralSeized);

    error FeedRequired();
    error NothingDeposited();
    error NothingBorrowed();
    error InsufficientCollateral(uint256 healthFactor);
    error PositionIsHealthy(uint256 healthFactor);
    error NoDebt();
    error RepayExceedsDebt(uint256 amount, uint256 debt);
    error WithdrawExceedsCollateral(uint256 amount, uint256 collateral);
    error StalePrice(uint256 age, uint256 maxAge);
    error InvalidPrice(int256 answer);
    error TransferFailed();

    constructor(
        AggregatorV3Interface priceFeed,
        uint256 collateralRatioBps,
        uint256 liquidationBonusBps,
        uint256 maxPriceAge
    ) {
        if (address(priceFeed) == address(0)) revert FeedRequired();
        PRICE_FEED = priceFeed;
        PRICE_UNIT = 10 ** priceFeed.decimals();
        COLLATERAL_RATIO_BPS = collateralRatioBps;
        LIQUIDATION_BONUS_BPS = liquidationBonusBps;
        MAX_PRICE_AGE = maxPriceAge;
    }

    /**
     * @notice The price, exactly as a Chainlink consumer reads one.
     * @dev This function is the entire integration surface. It contains no Lens-specific
     *      logic and would be unchanged if the feed were Chainlink's own.
     */
    function price() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = PRICE_FEED.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);

        // `updatedAt` is the source chain's clock, so this measures how old the price
        // really is rather than how recently it happened to arrive here.
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > MAX_PRICE_AGE) revert StalePrice(age, MAX_PRICE_AGE);

        return uint256(answer);
    }

    function deposit() external payable {
        if (msg.value == 0) revert NothingDeposited();
        positions[msg.sender].collateral += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert NothingBorrowed();
        uint256 p = price();

        positions[msg.sender].debt += amount;
        totalDebt += amount;

        uint256 hf = _healthFactor(positions[msg.sender], p);
        if (hf < LIQUIDATION_THRESHOLD) revert InsufficientCollateral(hf);

        emit Borrowed(msg.sender, amount, p);
    }

    function repay(uint256 amount) external {
        Position storage pos = positions[msg.sender];
        if (pos.debt == 0) revert NoDebt();
        if (amount > pos.debt) revert RepayExceedsDebt(amount, pos.debt);
        pos.debt -= amount;
        totalDebt -= amount;
        emit Repaid(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        Position storage pos = positions[msg.sender];
        if (amount > pos.collateral) revert WithdrawExceedsCollateral(amount, pos.collateral);
        pos.collateral -= amount;

        if (pos.debt > 0) {
            uint256 hf = _healthFactor(pos, price());
            if (hf < LIQUIDATION_THRESHOLD) revert InsufficientCollateral(hf);
        }

        emit Withdrawn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Seize collateral from an unhealthy position.
     * @dev The liquidation the demonstration turns on: a real price move on another
     *      chain, proven here, makes a position liquidatable and this succeeds.
     */
    function liquidate(address who) external returns (uint256 debtRepaid, uint256 collateralSeized) {
        Position storage pos = positions[who];
        if (pos.debt == 0) revert NoDebt();

        uint256 p = price();
        uint256 hf = _healthFactor(pos, p);
        if (hf >= LIQUIDATION_THRESHOLD) revert PositionIsHealthy(hf);

        debtRepaid = pos.debt;
        // Value the debt in collateral terms, then add the liquidator's discount.
        uint256 atPrice = (debtRepaid * PRICE_UNIT) / p;
        collateralSeized = (atPrice * (BPS + LIQUIDATION_BONUS_BPS)) / BPS;
        if (collateralSeized > pos.collateral) collateralSeized = pos.collateral;

        pos.debt = 0;
        pos.collateral -= collateralSeized;
        totalDebt -= debtRepaid;

        emit Liquidated(who, msg.sender, debtRepaid, collateralSeized);
        (bool ok,) = payable(msg.sender).call{value: collateralSeized}("");
        if (!ok) revert TransferFailed();
    }

    function healthFactor(address who) external view returns (uint256) {
        return _healthFactor(positions[who], price());
    }

    /**
     * @dev Collateral value over debt, adjusted for the required ratio. At or above 1e18
     *      the position is safe; below it may be liquidated.
     */
    function _healthFactor(Position memory pos, uint256 p) private view returns (uint256) {
        if (pos.debt == 0) return type(uint256).max;
        // Collateral is 18-decimal; the price is in the feed's own units. Dividing by
        // PRICE_UNIT brings the product back to 18 decimals, matching debt.
        uint256 collateralValue = (pos.collateral * p) / PRICE_UNIT;
        uint256 required = (pos.debt * COLLATERAL_RATIO_BPS) / BPS;
        if (required == 0) return type(uint256).max;
        return (collateralValue * WAD) / required;
    }

    receive() external payable {}
}
