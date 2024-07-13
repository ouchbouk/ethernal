# Ethernal

## Overview

Ethernal is DeFi perpetuals protocol that allows managing liquidity and leveraging positions on Ethereum. It includes features for adding/removing liquidity, managing long and short positions, and handling fees and liquidations.

## Prerequisites

- Solidity ^0.8.20
- OpenZeppelin Contracts

## Installation

To use this contract, you need to have Solidity and OpenZeppelin Contracts installed. You can install OpenZeppelin Contracts using npm:

```sh
forge install OpenZeppelin/openzeppelin-contracts
```

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

## Contract Components

### Imports

- `ERC4626` from OpenZeppelin: Extension for ERC20 to handle vaults.
- `ERC20` from OpenZeppelin: Standard ERC20 token implementation.
- `IERC20` from OpenZeppelin: Interface for ERC20.
- `SafeERC20` from OpenZeppelin: Safe operations for ERC20.
- `IPriceFeed`: Interface for fetching price data.
- `IEthernal`: Interface for the Ethernal contract.

### Errors

- `InvalidLeverage`
- `NotEnoughAssets`
- `ZeroAmount`
- `BadPrice`
- `NotLiquidateable`
- `UnsupportedToken`
- `UndesirableLpAmount`
- `NotEnoughReserves`
- `Slippage`

### State Variables

- `totalAssetLiquidity`: Total liquidity in the asset.
- `totalIndexLiquidity`: Total liquidity in the index token.
- `shortOpenInterest`: Total open interest for short positions.
- `longOpenInterest`: Total open interest for long positions.
- `shortPositions`: Mapping of short positions.
- `longPositions`: Mapping of long positions.
- Constants for leverage, utilization, fees, and scaling factors.
- Immutable variables for the price feed, asset, index token, and borrowing rate per second.

### Constructor

Initializes the contract with the asset, index token, price feed, and annual borrowing rate. It also sets the borrowing rate per second.

### Modifiers

- `onlySupportedTokens(address token)`: Ensures the token is either the asset or the index token.

### Functions

#### Public and External Functions

- `addLiquidity(address token, uint amount, uint minLp)`: Adds liquidity to the pool.
- `removeLiquidity(address tokenOut, uint lpAmount, uint minAmount)`: Removes liquidity from the pool.
- `updatePosition(address collateralToken, int amount, int size, bool isLong)`: Updates the position for a user.
- `closePosition(bool isLong)`: Closes a user's position.
- `accrueAccount(address account, bool isLong)`: Accrues borrowing fees and losses for an account.
- `liquidate(address account, bool isLong)`: Liquidates an account's position if necessary.

#### Internal Functions

- `_updateLiquidity(address token, int amount)`: Updates the total liquidity for the token.
- `_isValidWithdrawal(address token, uint amount)`: Checks if the withdrawal is valid.
- `_accrueBorrowingFees(address account, bool isLong)`: Accrues borrowing fees for an account.
- `_resetPositionAndUpdateSize(Position storage position, bool isLong)`: Resets a position and updates the size.
- `_accrueLoss(address account, bool isLong)`: Accrues losses for an account.
- `_isEnoughAssets(uint size, bool colInIndex)`: Checks if there are enough assets.
- `_getPosition(address account, bool isLong)`: Retrieves a user's position.
- `_mulPrice(uint amount, uint price)`: Multiplies amount by price.
- `_divPrice(uint amount, uint price)`: Divides amount by price.
- `_transferTokensIn(address token, address from, uint amount)`: Transfers tokens into the contract.
- `_transferTokensOut(address token, address to, uint amount)`: Transfers tokens out of the contract.

#### View Functions

- `previewRedeem(uint lpAmount)`: Returns the amount that would be received for redeeming LP tokens.
- `previewDeposit(uint amount)`: Returns the amount of LP tokens that would be minted for a given deposit.
- `calculateBorrowingFee(uint size, uint elapsedTime)`: Calculates the borrowing fee.
- `getPositionFee(uint size)`: Returns the fee for a given position size.
- `getLiquidationFee(uint collateral)`: Returns the liquidation fee.
- `getPorLInAsset(uint currentPrice, uint positionPrice, uint size)`: Returns the profit or loss in the asset.
- `getLeverage(uint collateral, uint size)`: Returns the leverage.
- `isValidLeverage(uint leverage)`: Checks if the leverage is valid.
- `totalAssets()`: Returns the total assets.
- `getPosition(address account, bool isLong)`: Returns a user's position.
- `getPrice()`: Returns the current price from the price feed.
- `isLiquidateable(address account, bool isLong)`: Checks if an account is liquidateable.

## Events

- `AddLiquidity(address indexed user, address indexed token, uint amount)`: Emitted when liquidity is added.
- `RemoveLiquidity(address indexed user, address indexed tokenOut, uint amount)`: Emitted when liquidity is removed.
- `UpdatePosition(address indexed user, bool isLong, int size, int amount)`: Emitted when a position is updated.
- `ClosePosition(address indexed user, bool isLong)`: Emitted when a position is closed.
- `LiquidatePosition(address indexed liquidator, address indexed account, uint fee)`: Emitted when a position is liquidated.
