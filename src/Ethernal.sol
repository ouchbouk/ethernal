// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./interfaces/IPrice.sol";
import {IEthernal} from "./interfaces/IEthernal.sol";

error InvalidLeverage();
error NotEnoughAssets();
error ZeroAmount();
error BadPrice();
error NotLiquidateable();
error UnsupportedToken();
error UndesirableLpAmount();
error NotEnoughReserves();
error Slippage();

contract Ethernal is IEthernal, ERC20 {
    uint256 public totalAssetLiquidity;
    uint256 public totalIndexLiquidity;

    uint256 public shortOpenInterest;
    uint256 public longOpenInterest;

    mapping(address => Position) shortPositions;
    mapping(address => Position) longPositions;

    uint256 constant MAX_LEVERAGE = 15 * SCALE_FACTOR;
    uint256 constant MAX_UTILIZATION = 8_000; // 80%
    uint256 constant MAX_BASIS_POINTS = 10_000; // 100%
    uint256 constant POSITION_FEE = 30; // 0.3%
    uint256 constant LIQUIDATOR_FEE = 1_000; // 10%

    uint256 constant SCALE_FACTOR = 1e18;
    uint256 constant BORROW_FEE_SCALE = 1e30;

    address immutable priceFeed;
    address immutable asset;
    address immutable indexToken;
    uint256 public immutable borrowingRatePerSecond; // decimals 30

    modifier onlySupportedTokens(address token) {
        if (token != asset && token != indexToken) revert UnsupportedToken();
        _;
    }

    constructor(address asset_, address indexToken_, address priceFeed_, uint256 borrowingRatePerYear)
        ERC20("Ethernal VT", "ETHNAL")
    {
        asset = asset_;
        indexToken = indexToken_;
        priceFeed = priceFeed_;
        borrowingRatePerSecond = ((BORROW_FEE_SCALE * borrowingRatePerYear) / MAX_BASIS_POINTS) / 31_536_000; // seconds per year;
    }

    /**
     * @dev See {IEthernal-addLiquidity}.
     */
    function addLiquidity(address token, uint256 amount, uint256 minLp) external onlySupportedTokens(token) {
        uint256 liquidityAmount = amount;
        _transferTokensIn(token, msg.sender, amount);

        if (token == indexToken) {
            amount = _mulPrice(amount, getPrice());
        }

        uint256 mintAmount = previewDeposit(amount);

        if (mintAmount < minLp) revert UndesirableLpAmount();
        _updateLiquidity(token, int256(liquidityAmount));
        _mint(msg.sender, mintAmount);

        emit AddLiquidity(msg.sender, token, amount);
    }

    /**
     * @dev See Updates the total liquidity for the token.
     */
    function _updateLiquidity(address token, int256 amount) internal {
        if (token == indexToken) {
            amount < 0 ? totalIndexLiquidity -= uint256(-amount) : totalIndexLiquidity += uint256(amount);
        } else {
            amount < 0 ? totalAssetLiquidity -= uint256(-amount) : totalAssetLiquidity += uint256(amount);
        }
    }

    /**
     * @dev See {IEthernal-removeLiquidity}.
     */
    function removeLiquidity(address tokenOut, uint256 lpAmount, uint256 minAmount)
        external
        onlySupportedTokens(tokenOut)
    {
        uint256 amount = previewRedeem(lpAmount);

        if (tokenOut == indexToken) {
            uint256 price = getPrice();
            amount = _divPrice(amount, price);
        }

        if (amount < minAmount) revert Slippage();
        if (!_isValidWithdrawal(tokenOut, amount)) revert NotEnoughReserves();
        _transferTokensOut(tokenOut, msg.sender, amount);
        _burn(msg.sender, lpAmount);

        _updateLiquidity(tokenOut, -int256(amount));

        emit RemoveLiquidity(msg.sender, tokenOut, amount);
    }

    /**
     * @dev Checks if the withdrawal is valid.
     */
    function _isValidWithdrawal(address token, uint256 amount) internal view returns (bool) {
        uint256 balance = ERC20(token).balanceOf(address(this));
        uint256 openInterest = token == indexToken ? longOpenInterest : shortOpenInterest;

        return (amount <= balance && (balance - amount) >= openInterest);
    }

    /**
     * @dev See {IEthernal-previewRedeem}.
     */
    function previewRedeem(uint256 lpAmount) public view returns (uint256) {
        uint256 totalSupply_ = totalSupply();

        return totalSupply_ == 0 ? lpAmount : (lpAmount * totalAssets()) / totalSupply_;
    }

    /**
     * @dev See {IEthernal-previewDeposit}.
     */
    function previewDeposit(uint256 amount) public view returns (uint256) {
        uint256 totalAssets_ = totalAssets();
        return totalAssets_ == 0 ? amount : (amount * totalSupply()) / totalAssets_;
    }

    /**
     * @dev See {IEthernal-updatePosition}.
     */
    function updatePosition(address collateralToken, int256 amount, int256 size, bool isLong)
        public
        onlySupportedTokens(collateralToken)
    {
        if (amount == 0 && size == 0) revert ZeroAmount();
        Position memory position = isLong ? longPositions[msg.sender] : shortPositions[msg.sender];

        if (position.price == 0) {
            position.price = getPrice();
            position.colInIndex = collateralToken == indexToken;
            position.lastTimeUpdated = block.timestamp;
        } else {
            accrueAccount(msg.sender, isLong);
        }

        amount < 0 ? position.collateral -= uint256(-amount) : position.collateral += uint256(amount);

        size < 0 ? position.size -= uint256(-size) : position.size += uint256(size);

        uint256 leverage = getLeverage(
            position.colInIndex ? _mulPrice(position.collateral, getPrice()) : position.collateral, position.size
        );

        if (!isValidLeverage(leverage)) revert InvalidLeverage();

        if (!_isEnoughAssets(position.size, position.colInIndex)) {
            revert NotEnoughAssets();
        }

        if (size != 0) {
            uint256 fee = getPositionFee(_abs(size));

            _transferTokensIn(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                position.colInIndex ? _divPrice(fee, getPrice()) : fee
            );
        }

        if (amount > 0) {
            _transferTokensIn(position.colInIndex ? indexToken : asset, msg.sender, uint256(amount));
        } else if (amount < 0) {
            _transferTokensOut(position.colInIndex ? indexToken : asset, msg.sender, uint256(-amount));
        }

        uint256 sizeChange = size < 0 ? uint256(-size) : uint256(size);

        if (isLong) {
            longPositions[msg.sender] = position;

            if (size > 0) {
                longOpenInterest += sizeChange;
            } else if (size < 0) {
                longOpenInterest -= sizeChange;
            }
        } else {
            shortPositions[msg.sender] = position;

            if (size > 0) {
                shortOpenInterest += sizeChange;
            } else if (size < 0) {
                shortOpenInterest -= sizeChange;
            }
        }

        emit UpdatePosition(msg.sender, isLong, size, amount);
    }

    /**
     * @dev Accrues borrowing fees for an account.
     */
    function _accrueBorrowingFees(address account, bool isLong) internal {
        Position memory position_ = getPosition(account, isLong);
        if (position_.lastTimeUpdated == 0 || position_.lastTimeUpdated == block.timestamp) return;

        uint256 elapsedTime = block.timestamp - position_.lastTimeUpdated;

        uint256 borrowingFees = calculateBorrowingFee(position_.size, elapsedTime);

        Position storage position = _getPosition(account, isLong);

        if (position.colInIndex) {
            borrowingFees = _divPrice(borrowingFees, getPrice());
        }

        if (position_.collateral < borrowingFees) {
            _resetPositionAndUpdateSize(position, isLong);
        } else {
            position.collateral -= borrowingFees;
        }
    }

    /**
     * @dev Returns absolute the value for an int
     */
    function _abs(int256 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(value) : uint256(-value);
    }

    /**
     * @dev See {IEthernal-closePosition}.
     */
    function closePosition(bool isLong) external {
        Position storage position = _getPosition(msg.sender, isLong);
        accrueAccount(msg.sender, isLong);

        emit ClosePosition(msg.sender, isLong);

        if (position.collateral == 0) return;
        if (isLiquidateable(msg.sender, isLong)) {
            _liquidate(msg.sender, isLong);
            return;
        } else {
            int256 profit = getPorLInAsset(getPrice(), position.price, position.size);

            uint256 total;
            uint256 collateral = position.collateral;
            bool colInIndex = position.colInIndex;

            if (isLong) {
                uint256 profitInIndex = _divPrice(uint256(profit), getPrice());
                total += profitInIndex;
                if (colInIndex) {
                    total += collateral;
                } else {
                    collateral = _divPrice(collateral, getPrice());

                    total += collateral;
                }
                _transferTokensOut(indexToken, msg.sender, total);
            } else {
                total += uint256(-profit);

                if (colInIndex) {
                    total += _mulPrice(collateral, getPrice());
                } else {
                    total += collateral;
                }
                _transferTokensOut(asset, msg.sender, total);
            }
            _resetPositionAndUpdateSize(position, isLong);
        }
    }

    /**
     * @dev See {IEthernal-getPositionFee}.
     */
    function getPositionFee(uint256 size) public pure returns (uint256) {
        return (size / MAX_BASIS_POINTS) * POSITION_FEE;
    }

    /**
     * @dev See {IEthernal-calculateBorrowingFee}.
     */
    function calculateBorrowingFee(uint256 size, uint256 elapsedTime) public view returns (uint256) {
        uint256 borrowFeeScaled = size * elapsedTime * borrowingRatePerSecond;
        return borrowFeeScaled / BORROW_FEE_SCALE;
    }

    /**
     * @dev See {IEthernal-accrueAccount}.
     */
    function accrueAccount(address account, bool isLong) public {
        _accrueBorrowingFees(account, isLong);
        _accrueLoss(account, isLong);
    }

    /**
     * @dev See {IEthernal-liquidate}.
     */
    function liquidate(address account, bool isLong) public {
        accrueAccount(account, isLong);
        _liquidate(account, isLong);
    }

    /**
     * @dev Liquidates an account's position.
     */
    function _liquidate(address account, bool isLong) internal {
        Position storage position = _getPosition(account, isLong);
        if (position.collateral == 0) return;

        bool isLiquidateable_ = isLiquidateable(account, isLong);
        if (!isLiquidateable_) revert NotLiquidateable();

        // if size is usdc and price normally has 6 decimals
        // this needs to be accustomed to other decimals too;

        uint256 liquidatorFee = getLiquidationFee(position.collateral);
        position.collateral -= liquidatorFee;

        _transferTokensOut(position.colInIndex ? indexToken : asset, msg.sender, liquidatorFee);

        _transferTokensOut(position.colInIndex ? indexToken : asset, account, position.collateral);

        _resetPositionAndUpdateSize(position, isLong);

        emit LiquidatePosition(msg.sender, account, liquidatorFee);
    }

    /**
     * @dev See {IEthernal-getLiquidationFee}.
     */
    function getLiquidationFee(uint256 collateral) public pure returns (uint256) {
        return (collateral * LIQUIDATOR_FEE) / MAX_BASIS_POINTS;
    }

    /**
     * @dev See {IEthernal-getPorLInAsset}.
     */
    function getPorLInAsset(uint256 currentPrice, uint256 positionPrice, uint256 size) public view returns (int256) {
        int256 priceDelta = int256(currentPrice) - int256(positionPrice);

        uint256 sizeInIndex = _divPrice(size, positionPrice);

        return (priceDelta * int256(sizeInIndex)) / int256(10 ** ERC20(indexToken).decimals());
    }

    /**
     * @dev Resets a position and updates the size.
     */
    function _resetPositionAndUpdateSize(Position storage position, bool isLong) internal {
        isLong ? longOpenInterest -= position.size : shortOpenInterest -= position.size;
        position.collateral = 0;
        position.size = 0;
        position.price = 0;
        position.lastTimeUpdated = 0;
    }

    /**
     * @dev See {IEthernal-isLiquidateable}.
     */
    function isLiquidateable(address account, bool isLong) public view returns (bool) {
        Position memory position = getPosition(account, isLong);
        return getLeverage(
            position.colInIndex ? _mulPrice(position.collateral, position.price) : position.collateral, position.size
        ) > MAX_LEVERAGE;
    }

    /**
     * @dev Accrues losses for an account.
     */
    function _accrueLoss(address account, bool isLong) internal {
        Position storage position = _getPosition(account, isLong);
        Position memory position_ = position;

        if (position_.collateral == 0) return;

        int256 potentialLoss = getPorLInAsset(getPrice(), position_.price, position_.size);

        if (isLong && potentialLoss < 0) {
            uint256 loss = uint256(-potentialLoss);

            if (position_.colInIndex) {
                loss = _divPrice(loss, getPrice());
            }
            if (position_.collateral >= loss) {
                position.collateral -= loss;
            } else {
                _resetPositionAndUpdateSize(position, isLong);
            }
        } else if (!isLong && potentialLoss > 0) {
            uint256 loss = uint256(potentialLoss);

            if (position_.colInIndex) {
                loss = _divPrice(loss, getPrice());
            }

            if (position_.collateral >= loss) {
                position.collateral -= loss;
            } else {
                _resetPositionAndUpdateSize(position, isLong);
            }
        }
    }

    /**
     * @dev See {IEthernal-getLeverage}.
     */
    function getLeverage(uint256 collateral, uint256 size) public pure returns (uint256) {
        if (size == 0 || collateral == 0) revert ZeroAmount();
        return (size * SCALE_FACTOR) / collateral;
    }

    /**
     * @dev See {IEthernal-isValidLeverage}.
     */
    function isValidLeverage(uint256 leverage) public pure returns (bool) {
        return leverage <= MAX_LEVERAGE;
    }

    /**
     * @dev Checks if there are enough assets.
     */
    function _isEnoughAssets(uint256 size, bool colInIndex) internal view returns (bool) {
        uint256 totalAssets_ = totalAssets();

        uint256 availableAssets = (totalAssets_ / MAX_BASIS_POINTS) * MAX_UTILIZATION;

        if (colInIndex) {
            size = _mulPrice(size, getPrice());
        }

        return size + longOpenInterest + shortOpenInterest <= availableAssets;
    }

    /**
     * @dev See {IEthernal-totalAssets}.
     */
    function totalAssets() public view returns (uint256) {
        return totalAssetLiquidity + _mulPrice(totalIndexLiquidity, getPrice());
    }

    /**
     * @dev See {IEthernal-getPosition}.
     */
    function getPosition(address account, bool isLong) public view returns (Position memory) {
        return isLong ? longPositions[account] : shortPositions[account];
    }

    /**
     * @dev See {IEthernal-getPrice}.
     */
    function getPrice() public view returns (uint256) {
        (, int256 price,,,) = IPriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert BadPrice();
        return uint256(price);
    }

    /**
     * @dev Retrieves a user's position.
     */
    function _getPosition(address account, bool isLong) internal view returns (Position storage) {
        return isLong ? longPositions[account] : shortPositions[account];
    }

    /**
     * @dev  Multiplies amount by price.
     */
    function _mulPrice(uint256 amount, uint256 price) internal view returns (uint256) {
        return (amount * price) / 10 ** ERC20(indexToken).decimals();
    }

    /**
     * @dev Divides amount by price.
     */
    function _divPrice(uint256 amount, uint256 price) internal view returns (uint256) {
        return (amount * 10 ** ERC20(indexToken).decimals()) / price;
    }

    /**
     * @dev Transfers tokens into the contract.
     */
    function _transferTokensIn(address token, address from, uint256 amount) internal {
        SafeERC20.safeTransferFrom(IERC20(token), from, address(this), amount);
    }

    /**
     * @dev Transfers tokens out of the contract.
     */
    function _transferTokensOut(address token, address to, uint256 amount) internal {
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }
}
