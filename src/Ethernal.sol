// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./IPrice.sol";

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
// events?
contract Ethernal is ERC20 {
    struct Position {
        uint256 collateral;
        bool colInIndex;
        uint256 size;
        uint price;
        uint lastTimeUpdated;
    }

    uint256 totalAssetLiquidity;
    uint256 totalIndexLiquidity;

    uint256 shortOpenInterest;
    uint256 longOpenInterest;

    mapping(address => Position) shortPositions;
    mapping(address => Position) longPositions;

    uint256 constant MAX_LEVERAGE = 15 * SCALE_FACTOR;
    uint256 constant MAX_UTILIZATION = 8_000; // 80%
    uint256 constant MAX_BASIS_POINTS = 10_000; // 100%
    uint256 constant POSITION_FEE = 30; // 0.3%
    uint256 constant LIQUIDATOR_FEE = 1_000; // 10%
    uint256 constant BORROWING_RATE_PER_YEAR = 1_000; // 10%
    uint256 constant SCALE_FACTOR = 1e18;
    uint constant BORROW_FEE_SCALE = 1e30;
    address immutable priceFeed;

    address immutable asset;
    address immutable indexToken;
    uint256 public immutable borrowingRatePerSecond; // decimals 30

    modifier onlySupportedTokens(address token) {
        if (token != asset && token != indexToken) revert UnsupportedToken();
        _;
    }

    constructor(
        address asset_,
        address indexToken_,
        address priceFeed_
    ) ERC20("Ethernal VT", "ETHNAL") {
        asset = asset_;
        indexToken = indexToken_;
        priceFeed = priceFeed_;
        borrowingRatePerSecond =
            ((BORROW_FEE_SCALE * BORROWING_RATE_PER_YEAR) / MAX_BASIS_POINTS) /
            31_536_000; // seconds per year;
    }

    function addLiquidity(
        address token,
        uint256 amount,
        uint minLp
    ) external onlySupportedTokens(token) {
        transferTokensIn(token, msg.sender, amount);
        if (token == indexToken) {
            amount = mulPrice(
                amount,
                getPrice(),
                10 ** ERC20(token).decimals()
            );
        }

        uint mintAmount = previewDeposit(amount);

        if (mintAmount < minLp) revert UndesirableLpAmount();
        _mint(msg.sender, mintAmount);

        updateLiquidity(token, int(amount));
    }

    function updateLiquidity(address token, int256 amount) internal {
        if (token == indexToken) {
            amount < 0
                ? totalIndexLiquidity -= uint256(-amount)
                : totalIndexLiquidity += uint(amount);
        } else {
            amount < 0
                ? totalAssetLiquidity -= uint256(-amount)
                : totalAssetLiquidity += uint(amount);
        }
    }

    function removeLiquidity(
        address tokenOut,
        uint256 lpAmount,
        uint256 minAmount
    ) external onlySupportedTokens(tokenOut) {
        uint amount = previewRedeem(lpAmount);
        if (tokenOut == indexToken) {
            uint256 price = getPrice();
            amount = divPrice(amount, price, ERC20(indexToken).decimals());
        }

        if (amount < minAmount) revert Slippage();
        if (!isValidateWithdrawal(tokenOut, amount)) revert NotEnoughReserves();
        // what if no m0ny?
        transferTokensOut(tokenOut, msg.sender, amount);
        _burn(msg.sender, lpAmount);

        updateLiquidity(tokenOut, -int(amount));
    }

    function isValidateWithdrawal(
        address token,
        uint amount
    ) internal view returns (bool) {
        uint256 balance = ERC20(token).balanceOf(address(this));
        uint openInterest = token == indexToken
            ? longOpenInterest
            : shortOpenInterest;

        return (amount <= balance && (balance - amount) >= openInterest);
    }

    function previewRedeem(uint lpAmount) public view returns (uint256) {
        uint256 totalSupply_ = totalSupply();

        return
            totalSupply_ == 0
                ? lpAmount
                : lpAmount * (totalAssets() / totalSupply_);
    }

    function previewDeposit(uint amount) public view returns (uint256) {
        uint256 totalAssets_ = totalAssets();
        return
            totalAssets_ == 0
                ? amount
                : ((amount * totalSupply()) / totalAssets_);
    }

    function updatePosition(
        address collateralToken,
        int256 amount,
        int256 size,
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
            accrueBorrowingFees(msg.sender, isLong);
            accrueLoss(msg.sender, isLong);
        }

        amount < 0
            ? position.collateral -= uint256(-amount)
            : position.collateral += uint256(amount);

        size < 0 ? position.size -= uint(-size) : position.size += uint(size);

        uint leverage = getLeverage(
            position.colInIndex
                ? mulPrice(
                    position.collateral,
                    getPrice(),
                    10 ** ERC20(indexToken).decimals()
                )
                : position.collateral,
            position.size
        );

        if (!isValidLeverage(leverage)) revert InvalidLeverage();

        if (!isEnoughAssets(position.size, position.colInIndex))
            revert NotEnoughAssets();

        if (size > 0) {
            uint256 fee = getPositionFee(abs(size));
            transferTokensIn(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                fee
            );
        }

        if (amount > 0)
            transferTokensIn(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                uint256(amount)
            );
        else if (amount < 0) {
            transferTokensOut(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                uint(-amount)
            );
        }

        uint sizeChange;

        if (position.colInIndex) {
            sizeChange = mulPrice(
                size < 0 ? uint(-size) : uint(size),
                getPrice(),
                10 ** ERC20(indexToken).decimals()
            );
        } else {
            sizeChange = size < 0 ? uint(-size) : uint(size);
        }

        // update storage
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

    function accrueBorrowingFees(address account, bool isLong) internal {
        Position memory position = getPosition(account, isLong);
        if (
            position.lastTimeUpdated == 0 ||
            position.lastTimeUpdated == block.timestamp
        ) return;

        uint elapsedTime = block.timestamp - position.lastTimeUpdated;

        uint borrowingFees = calculateBorrowingFee(position.size, elapsedTime);

        if (position.collateral < borrowingFees) {
            resetPositionAndUpdateSize(
                getPositionStorage(account, isLong),
                isLong
            );
        } else {
            position.collateral -= borrowingFees;
        }
    }

    function abs(int value) internal pure returns (uint) {
        return value >= 0 ? uint(value) : uint(-value);
    }

    function closePosition(bool isLong) public {
        Position storage position = getPositionStorage(msg.sender, isLong);

        accrueBorrowingFees(msg.sender, isLong);
        accrueLoss(msg.sender, isLong);

        if (position.collateral == 0) return;

        if (isLiquidateable(msg.sender, isLong)) {
            liquidate(msg.sender, isLong);
            return;
        } else {
            int256 profit = getPorLInAsset(
                getPrice(),
                position.price,
                position.size
            );

            uint total;
            uint collateral = position.collateral;
            bool colInIndex = position.colInIndex;
            if (isLong) {
                uint profitInIndex = divPrice(
                    uint(profit),
                    getPrice(),
                    10 ** ERC20(indexToken).decimals()
                );
                total += profitInIndex;
                if (colInIndex) {
                    total += collateral;
                } else {
                    collateral = divPrice(
                        collateral,
                        getPrice(),
                        10 ** ERC20(indexToken).decimals()
                    );

                    total += collateral;
                }
                transferTokensOut(indexToken, msg.sender, total);
            } else {
                total += uint(-profit);

                if (colInIndex) {
                    total += mulPrice(
                        collateral,
                        getPrice(),
                        10 ** ERC20(indexToken).decimals()
                    );
                } else {
                    total += collateral;
                }
                transferTokensOut(asset, msg.sender, total);
            }
            resetPositionAndUpdateSize(position, isLong);
        }
    }

    function getPositionFee(uint256 size) public pure returns (uint256) {
        return (size / MAX_BASIS_POINTS) * POSITION_FEE;
    }

    function calculateBorrowingFee(
        uint size,
        uint elapsedTime
    ) public view returns (uint256) {
        uint borrowFeeScaled = size * elapsedTime * borrowingRatePerSecond;
        return borrowFeeScaled / BORROW_FEE_SCALE;
    }

    function liquidate(address user, bool isLong) public {
        bool isLiquidateable_ = isLiquidateable(msg.sender, isLong);
        if (!isLiquidateable_) revert NotLiquidateable();

        Position storage position = isLong
            ? longPositions[user]
            : shortPositions[user];
        // if size is usdc and price normally has 6 decimals
        // this needs to be accustomed to other decimals too;

        uint liquidatorFee = getLiquidationFee(position.collateral);

        position.collateral -= liquidatorFee;

        transferTokensOut(
            position.colInIndex ? indexToken : asset,
            msg.sender,
            liquidatorFee
        );

        transferTokensOut(
            position.colInIndex ? indexToken : asset,
            user,
            position.collateral
        );

        resetPositionAndUpdateSize(position, isLong);
    }

    function getLiquidationFee(uint collateral) public pure returns (uint) {
        return (collateral * LIQUIDATOR_FEE) / MAX_BASIS_POINTS;
    }

    function getPorLInAsset(
        uint256 currentPrice,
        uint256 positionPrice,
        uint256 size
    ) public view returns (int256) {
        int priceChange = int(currentPrice) - int(positionPrice);

        uint sizeInIndex = divPrice(
            size,
            positionPrice,
            10 ** ERC20(indexToken).decimals()
        );

        return (priceChange * int(sizeInIndex)) / int(SCALE_FACTOR);
    }

    function resetPositionAndUpdateSize(
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
        address user,
        bool isLong
    ) public view returns (bool) {
        Position memory position = isLong
            ? longPositions[user]
            : shortPositions[user];

        return
            getLeverage(
                position.colInIndex
                    ? mulPrice(
                        position.collateral,
                        getPrice(),
                        10 ** ERC20(indexToken).decimals()
                    )
                    : position.collateral,
                position.size
            ) > MAX_LEVERAGE;
    }

    function accrueLoss(address account, bool isLong) internal {
        Position storage position = getPositionStorage(account, isLong);
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
                loss = divPrice(
                    loss,
                    getPrice(),
                    10 ** ERC20(indexToken).decimals()
                );
            }

            if (position_.collateral >= loss) {
                longPositions[account].collateral -= loss;
            } else {
                resetPositionAndUpdateSize(position, isLong);
            }
        } else if (!isLong && potentialLoss > 0) {
            uint loss = uint(potentialLoss);

            if (position_.colInIndex) {
                loss = divPrice(
                    loss,
                    getPrice(),
                    10 ** ERC20(indexToken).decimals()
                );
            }

            if (position_.collateral >= loss) {
                shortPositions[account].collateral -= loss;
            } else {
                resetPositionAndUpdateSize(position, isLong);
            }
        }
    }

    function getLeverage(
        uint256 collateral,
        uint256 size
    ) public pure returns (uint256) {
        if (size == 0 || collateral == 0) revert ZeroAmount();
        return (size * SCALE_FACTOR) / collateral;
    }

    function isValidLeverage(uint256 leverage) public pure returns (bool) {
        return leverage <= MAX_LEVERAGE;
    }

    function isEnoughAssets(
        uint256 size,
        bool colInIndex
    ) public view returns (bool) {
        uint256 totalAssets_ = totalAssets();

        uint256 availableAssets = (totalAssets_ / MAX_BASIS_POINTS) *
            MAX_UTILIZATION;

        if (colInIndex) {
            size = mulPrice(
                size,
                getPrice(),
                10 ** ERC20(indexToken).decimals()
            );
        }

        return size + longOpenInterest + shortOpenInterest <= availableAssets;
    }

    function totalAssets() public view returns (uint256) {
        return
            totalAssetLiquidity +
            mulPrice(
                totalIndexLiquidity,
                getPrice(),
                10 ** ERC20(indexToken).decimals()
            );
    }

    function getPosition(
        address account,
        bool isLong
    ) public view returns (Position memory) {
        return isLong ? longPositions[account] : shortPositions[account];
    }

    function getPositionStorage(
        address account,
        bool isLong
    ) internal view returns (Position storage) {
        return isLong ? longPositions[account] : shortPositions[account];
    }

    function getPrice() public view returns (uint256) {
        (, int256 price, , , ) = IPriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert BadPrice();
        return uint256(price);
    }

    function mulPrice(
        uint256 amount,
        uint256 price,
        uint256 assetDecimals
    ) internal pure returns (uint256) {
        return (amount * price) / assetDecimals;
    }

    function divPrice(
        uint n,
        uint price,
        uint toScale
    ) internal pure returns (uint) {
        return (n * toScale) / price;
    }

    function transferTokensIn(
        address token,
        address from,
        uint256 amount
    ) internal {
        SafeERC20.safeTransferFrom(IERC20(token), from, address(this), amount);
    }

    function transferTokensOut(
        address token,
        address to,
        uint amount
    ) internal {
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }
}
