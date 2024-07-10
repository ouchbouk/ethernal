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

    /// @notice Emitted when liquidity is added
    /// @param user User depositing liquidity
    /// @param token Token address
    /// @param amount Amount deposited
    event AddLiquidity(
        address indexed user,
        address indexed token,
        uint amount
    );

    /// @notice Emitted when liquidity is removed
    /// @dev Explain to a developer any extra details
    /// @param user User removing liquidity
    /// @param token Token address
    /// @param amount Amount removed
    event RemoveLiquidity(
        address indexed user,
        address indexed token,
        uint amount
    );
    event UpdatePosition(
        address indexed user,
        bool indexed isLong,
        int size,
        int collateral
    );

    event ClosePosition(address indexed user, bool indexed isLong);

    event LiquidatePosition(
        address indexed liquidator,
        address indexed liquidated,
        uint liquidationFee
    );

    function addLiquidity(
        address token,
        uint256 amount,
        uint256 minLp
    ) external;
    function removeLiquidity(
        address tokenOut,
        uint256 lpAmount,
        uint256 minAmount
    ) external;

    function previewRedeem(uint256 lpAmount) external view returns (uint256);

    function previewDeposit(uint256 amount) external view returns (uint256);

    function updatePosition(
        address collateralToken,
        int256 amount,
        int256 size,
        bool isLong
    ) external;

    function accrueAccount(address account, bool isLong) external;

    function liquidate(address account, bool isLong) external;

    function closePosition(bool isLong) external;

    function getPositionFee(uint256 size) external pure returns (uint256);

    function calculateBorrowingFee(
        uint256 size,
        uint256 elapsedTime
    ) external view returns (uint256);

    function getLiquidationFee(
        uint256 collateral
    ) external pure returns (uint256);

    function getPorLInAsset(
        uint256 currentPrice,
        uint256 positionPrice,
        uint256 size
    ) external view returns (int256);

    function isLiquidateable(
        address account,
        bool isLong
    ) external view returns (bool);

    function getLeverage(
        uint256 collateral,
        uint256 size
    ) external pure returns (uint256);

    function isValidLeverage(uint256 leverage) external pure returns (bool);

    function getPosition(
        address account,
        bool isLong
    ) external view returns (Position memory);

    function getPrice() external view returns (uint256);
}
