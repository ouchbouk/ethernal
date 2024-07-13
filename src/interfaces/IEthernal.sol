// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEthernal {
    struct Position {
        uint256 collateral;
        bool colInIndex;
        uint256 size;
        uint256 price;
        uint256 lastTimeUpdated;
    }

    /**
     * @dev Emitted when liquidity is added.
     */
    event AddLiquidity(address indexed user, address indexed token, uint256 amount);

    /**
     * @dev Emitted when liquidity is removed.
     */
    event RemoveLiquidity(address indexed user, address indexed token, uint256 amount);

    /**
     * @dev Emitted when a position is updated.
     */
    event UpdatePosition(address indexed user, bool indexed isLong, int256 size, int256 collateral);

    /**
     * @dev Emitted when a position is closed.
     */
    event ClosePosition(address indexed user, bool indexed isLong);

    /**
     * @dev  Emitted when a position is liquidated.
     */
    event LiquidatePosition(address indexed liquidator, address indexed liquidated, uint256 liquidationFee);

    /**
     * @dev Adds liquidity to the pool.
     */
    function addLiquidity(address token, uint256 amount, uint256 minLp) external;

    /**
     * @dev  Removes liquidity from the pool.
     */
    function removeLiquidity(address tokenOut, uint256 lpAmount, uint256 minAmount) external;

    /**
     * @dev  Returns the amount that would be received for redeeming LP tokens.
     */
    function previewRedeem(uint256 lpAmount) external view returns (uint256);

    /**
     * @dev Returns the amount of LP tokens that would be minted for a given deposit.
     */
    function previewDeposit(uint256 amount) external view returns (uint256);

    /**
     * @dev Updates the position for a user.
     */
    function updatePosition(address collateralToken, int256 amount, int256 size, bool isLong) external;

    /**
     * @dev  Accrues borrowing fees and losses for an account.
     */
    function accrueAccount(address account, bool isLong) external;

    /**
     * @dev Liquidates an account's position if necessary.
     */
    function liquidate(address account, bool isLong) external;

    /**
     * @dev Closes a user's position.
     */
    function closePosition(bool isLong) external;

    /**
     * @dev Returns the fee for a given position size.
     */
    function getPositionFee(uint256 size) external pure returns (uint256);

    /**
     * @dev Calculates the borrowing fee.
     */
    function calculateBorrowingFee(uint256 size, uint256 elapsedTime) external view returns (uint256);

    /**
     * @dev Returns the liquidation fee.
     */
    function getLiquidationFee(uint256 collateral) external pure returns (uint256);

    /**
     * @dev Returns the profit or loss in the asset.
     */
    function getPorLInAsset(uint256 currentPrice, uint256 positionPrice, uint256 size) external view returns (int256);

    /**
     * @dev Checks if an account is liquidateable.
     */
    function isLiquidateable(address account, bool isLong) external view returns (bool);

    /**
     * @dev Returns the leverage.
     */
    function getLeverage(uint256 collateral, uint256 size) external pure returns (uint256);

    /**
     * @dev Checks if the leverage is valid.
     */
    function isValidLeverage(uint256 leverage) external pure returns (bool);

    /**
     * @dev Returns a user's position.
     */
    function getPosition(address account, bool isLong) external view returns (Position memory);

    /**
     * @dev Returns the current price from the price feed.
     */
    function getPrice() external view returns (uint256);
}
