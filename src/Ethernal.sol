// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./interfaces/IPrice.sol";
import {IEthernal} from "./interfaces/IEthernal.sol";

import "forge-std/console.sol";

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
    uint public totalAssetLiquidity;
    uint public totalIndexLiquidity;

    uint public shortOpenInterest;
    uint public longOpenInterest;

    mapping(address => Position) shortPositions;
    mapping(address => Position) longPositions;

    uint constant MAX_LEVERAGE = 15 * SCALE_FACTOR;
    uint constant MAX_UTILIZATION = 8_000; // 80%
    uint constant MAX_BASIS_POINTS = 10_000; // 100%
    uint constant POSITION_FEE = 30; // 0.3%
    uint constant LIQUIDATOR_FEE = 1_000; // 10%

    uint constant SCALE_FACTOR = 1e18;
    uint constant BORROW_FEE_SCALE = 1e30;

    address immutable priceFeed;
    address immutable asset;
    address immutable indexToken;
    uint public immutable borrowingRatePerSecond; // decimals 30

    // uint  constant BORROWING_RATE_PER_YEAR = 1_000; // 10%

    modifier onlySupportedTokens(address token) {
        if (token != asset && token != indexToken) revert UnsupportedToken();
        _;
    }

    constructor(
        address asset_,
        address indexToken_,
        address priceFeed_,
        uint borrowingRatePerYear
    ) ERC20("Ethernal VT", "ETHNAL") {
        asset = asset_;
        indexToken = indexToken_;
        priceFeed = priceFeed_;
        borrowingRatePerSecond =
            ((BORROW_FEE_SCALE * borrowingRatePerYear) / MAX_BASIS_POINTS) /
            31_536_000; // seconds per year;
    }

    function addLiquidity(
        address token,
        uint amount,
        uint minLp
    ) external onlySupportedTokens(token) {
        uint liquidityAmount = amount;
        _transferTokensIn(token, msg.sender, amount);

        if (token == indexToken) {
            amount = _mulPrice(amount, getPrice());
        }

        uint mintAmount = previewDeposit(amount);

        if (mintAmount < minLp) revert UndesirableLpAmount();
        _updateLiquidity(token, int(liquidityAmount));
        _mint(msg.sender, mintAmount);
    }

    function _updateLiquidity(address token, int amount) internal {
        if (token == indexToken) {
            amount < 0
                ? totalIndexLiquidity -= uint(-amount)
                : totalIndexLiquidity += uint(amount);
        } else {
            amount < 0
                ? totalAssetLiquidity -= uint(-amount)
                : totalAssetLiquidity += uint(amount);
        }
    }

    function removeLiquidity(
        address tokenOut,
        uint lpAmount,
        uint minAmount
    ) external onlySupportedTokens(tokenOut) {
        uint amount = previewRedeem(lpAmount);

        if (tokenOut == indexToken) {
            uint price = getPrice();
            amount = _divPrice(amount, price);
        }

        if (amount < minAmount) revert Slippage();
        if (!_isValidWithdrawal(tokenOut, amount)) revert NotEnoughReserves();
        // what if no m0ny?
        _transferTokensOut(tokenOut, msg.sender, amount);
        _burn(msg.sender, lpAmount);

        _updateLiquidity(tokenOut, -int(amount));
    }

    function _isValidWithdrawal(
        address token,
        uint amount
    ) internal view returns (bool) {
        uint balance = ERC20(token).balanceOf(address(this));
        uint openInterest = token == indexToken
            ? longOpenInterest
            : shortOpenInterest;

        return (amount <= balance && (balance - amount) >= openInterest);
    }

    function previewRedeem(uint lpAmount) public view returns (uint) {
        uint totalSupply_ = totalSupply();

        return
            totalSupply_ == 0
                ? lpAmount
                : (lpAmount * totalAssets()) / totalSupply_;
    }

    function previewDeposit(uint amount) public view returns (uint) {
        uint totalAssets_ = totalAssets();
        return
            totalAssets_ == 0
                ? amount
                : (amount * totalSupply()) / totalAssets_;
    }

    function updatePosition(
        address collateralToken,
        int amount,
        int size,
        bool isLong
    ) public onlySupportedTokens(collateralToken) {
        if (amount == 0 && size == 0) revert ZeroAmount(); // @audit ?????
        Position memory position = isLong
            ? longPositions[msg.sender]
            : shortPositions[msg.sender];

        if (position.price == 0) {
            position.price = getPrice();
            position.colInIndex = collateralToken == indexToken;
            position.lastTimeUpdated = block.timestamp;
        } else {
            accrueAccount(msg.sender, isLong);
        }

        amount < 0
            ? position.collateral -= uint(-amount)
            : position.collateral += uint(amount);

        size < 0 ? position.size -= uint(-size) : position.size += uint(size);

        uint leverage = getLeverage(
            position.colInIndex
                ? _mulPrice(position.collateral, getPrice())
                : position.collateral,
            position.size
        );

        if (!isValidLeverage(leverage)) revert InvalidLeverage();

        if (!_isEnoughAssets(position.size, position.colInIndex))
            revert NotEnoughAssets();

        if (size != 0) {
            uint fee = getPositionFee(_abs(size));

            _transferTokensIn(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                position.colInIndex ? _divPrice(fee, getPrice()) : fee
            );
        }

        if (amount > 0)
            _transferTokensIn(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                uint(amount)
            );
        else if (amount < 0) {
            _transferTokensOut(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                uint(-amount)
            );
        }

        uint sizeChange = size < 0 ? uint(-size) : uint(size);

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
    }

    function _accrueBorrowingFees(address account, bool isLong) internal {
        Position memory position_ = getPosition(account, isLong);
        if (
            position_.lastTimeUpdated == 0 ||
            position_.lastTimeUpdated == block.timestamp
        ) return;

        uint elapsedTime = block.timestamp - position_.lastTimeUpdated;

        uint borrowingFees = calculateBorrowingFee(position_.size, elapsedTime);

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

    function _abs(int value) internal pure returns (uint) {
        return value >= 0 ? uint(value) : uint(-value);
    }

    function closePosition(bool isLong) external {
        Position storage position = _getPosition(msg.sender, isLong);
        accrueAccount(msg.sender, isLong);

        if (position.collateral == 0) return;
        if (isLiquidateable(msg.sender, isLong)) {
            _liquidate(msg.sender, isLong);
            return;
        } else {
            int profit = getPorLInAsset(
                getPrice(),
                position.price,
                position.size
            );

            uint total;
            uint collateral = position.collateral;
            bool colInIndex = position.colInIndex;

            if (isLong) {
                uint profitInIndex = _divPrice(uint(profit), getPrice());
                total += profitInIndex;
                if (colInIndex) {
                    total += collateral;
                } else {
                    collateral = _divPrice(collateral, getPrice());

                    total += collateral;
                }
                _transferTokensOut(indexToken, msg.sender, total);
            } else {
                total += uint(-profit);

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

    function getPositionFee(uint size) public pure returns (uint) {
        return (size / MAX_BASIS_POINTS) * POSITION_FEE;
    }

    function calculateBorrowingFee(
        uint size,
        uint elapsedTime
    ) public view returns (uint) {
        uint borrowFeeScaled = size * elapsedTime * borrowingRatePerSecond;
        return borrowFeeScaled / BORROW_FEE_SCALE;
    }

    function accrueAccount(address account, bool isLong) public {
        _accrueBorrowingFees(account, isLong);
        _accrueLoss(account, isLong);
    }

    function liquidate(address account, bool isLong) public {
        accrueAccount(account, isLong);
        _liquidate(account, isLong);
    }

    function _liquidate(address account, bool isLong) internal {
        Position storage position = _getPosition(account, isLong);
        if (position.collateral == 0) return;

        bool isLiquidateable_ = isLiquidateable(account, isLong);
        if (!isLiquidateable_) revert NotLiquidateable();

        // if size is usdc and price normally has 6 decimals
        // this needs to be accustomed to other decimals too;

        uint liquidatorFee = getLiquidationFee(position.collateral);
        position.collateral -= liquidatorFee;

        _transferTokensOut(
            position.colInIndex ? indexToken : asset,
            msg.sender,
            liquidatorFee
        );

        _transferTokensOut(
            position.colInIndex ? indexToken : asset,
            account,
            position.collateral
        );

        _resetPositionAndUpdateSize(position, isLong);
    }

    function getLiquidationFee(uint collateral) public pure returns (uint) {
        return (collateral * LIQUIDATOR_FEE) / MAX_BASIS_POINTS;
    }

    function getPorLInAsset(
        uint currentPrice,
        uint positionPrice,
        uint size
    ) public view returns (int) {
        int priceDelta = int(currentPrice) - int(positionPrice);

        uint sizeInIndex = _divPrice(size, positionPrice);

        return
            (priceDelta * int(sizeInIndex)) /
            int(10 ** ERC20(indexToken).decimals());
    }

    function _resetPositionAndUpdateSize(
        Position storage position,
        bool isLong
    ) internal {
        isLong
            ? longOpenInterest -= position.size
            : shortOpenInterest -= position.size;
        position.collateral = 0;
        position.size = 0;
        position.price = 0;
        position.lastTimeUpdated = 0;
    }

    function isLiquidateable(
        address account,
        bool isLong
    ) public view returns (bool) {
        Position memory position = getPosition(account, isLong);
        return
            getLeverage(
                position.colInIndex
                    ? _mulPrice(position.collateral, position.price)
                    : position.collateral,
                position.size
            ) > MAX_LEVERAGE;
    }

    function _accrueLoss(address account, bool isLong) internal {
        Position storage position = _getPosition(account, isLong);
        Position memory position_ = position;

        if (position_.collateral == 0) return;

        int potentialLoss = getPorLInAsset(
            getPrice(),
            position_.price,
            position_.size
        );

        if (isLong && potentialLoss < 0) {
            uint loss = uint(-potentialLoss);

            if (position_.colInIndex) {
                loss = _divPrice(loss, getPrice());
            }
            if (position_.collateral >= loss) {
                position.collateral -= loss;
            } else {
                _resetPositionAndUpdateSize(position, isLong);
            }
        } else if (!isLong && potentialLoss > 0) {
            uint loss = uint(potentialLoss);

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

    function getLeverage(
        uint collateral,
        uint size
    ) public pure returns (uint) {
        if (size == 0 || collateral == 0) revert ZeroAmount();
        return (size * SCALE_FACTOR) / collateral;
    }

    function isValidLeverage(uint leverage) public pure returns (bool) {
        return leverage <= MAX_LEVERAGE;
    }

    function _isEnoughAssets(
        uint size,
        bool colInIndex
    ) internal view returns (bool) {
        uint totalAssets_ = totalAssets();

        uint availableAssets = (totalAssets_ / MAX_BASIS_POINTS) *
            MAX_UTILIZATION;

        if (colInIndex) {
            size = _mulPrice(size, getPrice());
        }

        return size + longOpenInterest + shortOpenInterest <= availableAssets;
    }

    function totalAssets() public view returns (uint) {
        return totalAssetLiquidity + _mulPrice(totalIndexLiquidity, getPrice());
    }

    function getPosition(
        address account,
        bool isLong
    ) public view returns (Position memory) {
        return isLong ? longPositions[account] : shortPositions[account];
    }
    function getPrice() public view returns (uint) {
        (, int price, , , ) = IPriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert BadPrice();
        return uint(price);
    }

    function _getPosition(
        address account,
        bool isLong
    ) internal view returns (Position storage) {
        return isLong ? longPositions[account] : shortPositions[account];
    }

    function _mulPrice(uint amount, uint price) internal view returns (uint) {
        return (amount * price) / 10 ** ERC20(indexToken).decimals();
    }

    function _divPrice(uint amount, uint price) internal view returns (uint) {
        return (amount * 10 ** ERC20(indexToken).decimals()) / price;
    }

    function _transferTokensIn(
        address token,
        address from,
        uint amount
    ) internal {
        SafeERC20.safeTransferFrom(IERC20(token), from, address(this), amount);
    }

    function _transferTokensOut(
        address token,
        address to,
        uint amount
    ) internal {
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }
}
