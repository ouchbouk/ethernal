// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./IPrice.sol";

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
        uint256 size; // 10_000 usd // in tokens = size/price = 10 eth
        uint price; // 1000 usd/eth
    }

    uint256 totalAssetLiquidity;
    uint256 totalIndexLiquidity;

    uint256 shortOpenInterest;
    uint256 longOpenInterest;

    mapping(address => Position) shortPositions;
    mapping(address => Position) longPositions;

    uint8 constant MAX_LEVERAGE = 15;
    uint256 constant MAX_UTILIZATION = 8_000; // 80%
    uint256 constant MAX_BASIS_POINTS = 10_000; // 100%
    uint256 constant POSITION_FEE = 30; // 0.3%
    uint256 constant SCALE_FACTOR = 10 ** 18;

    address immutable priceFeed;

    address immutable asset;
    address immutable indexToken;

    modifier onlySupportedTokens(address token) {
        if (token != asset && token != indexToken) revert UnsupportedToken();
        _;
    }

    constructor(
        address priceFeed_,
        address asset_,
        address indexToken_
    ) ERC20("Ethernal VT", "ETHNAL") {
        asset = asset_;
        indexToken = indexToken_;
        priceFeed = priceFeed_;
    }

    function addLiquidity(
        address token,
        uint256 amount,
        uint minLp
    ) external onlySupportedTokens(token) {
        transferTokensIn(token, msg.sender, amount);

        if (token == indexToken) {
            amount = mulPrice(amount, getPrice(), ERC20(token).decimals());
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
        return (amount < balance && (balance - amount) > openInterest);
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
        }
        amount < 0
            ? position.collateral -= uint256(-amount)
            : position.collateral += uint256(amount);

        size < 0 ? position.size -= uint(size) : position.collateral += uint(
            size
        );

        uint leverage = getLeverage(position.collateral, position.size);

        if (!isValidLeverage(leverage)) revert InvalidLeverage();
        if (!isEnoughAssets(position.size)) revert NotEnoughAssets();

        if (amount > 0)
            transferTokensIn(
                position.colInIndex ? indexToken : asset,
                msg.sender,
                uint256(amount)
            );

        // @audit add fee

        // update storage
        if (isLong) {
            longPositions[msg.sender] = position;

            if (size > 0) {
                longOpenInterest += uint(size);
            } else if (size < 0) {
                longOpenInterest -= uint(-size);
            }
        } else {
            shortPositions[msg.sender] = position;

            if (size > 0) {
                shortOpenInterest += uint(size);
            } else if (size < 0) {
                shortOpenInterest -= uint(-size);
            }
        }
    }

    function updateOpenInterest(int size) internal {}

    function closePosition(bool isLong) public {
        Position storage position;
        bool isLiquidateable_;
        address asset_;
        if (isLong) {
            position = longPositions[msg.sender];
            isLiquidateable_ = isLiquidateable(msg.sender, true);
            asset_ = indexToken;
        } else {
            position = shortPositions[msg.sender];
            isLiquidateable_ = isLiquidateable(msg.sender, false);
            asset_ = asset;
        }

        if (isLiquidateable_) {
            liquidate(msg.sender, isLong);
            if (position.collateral > 0) {
                transferTokensOut(
                    position.colInIndex ? indexToken : asset,
                    msg.sender,
                    position.collateral
                );
            }
            // size??????
        } else {
            uint256 profit = getPorL(
                getPrice(),
                position.price,
                getSizeInTokens(position.size, position.price)
            );
            uint total;
            uint collateral = position.collateral;
            bool colInIndex = position.colInIndex;
            if (isLong) {
                uint profitInIndex = divPrice(
                    profit,
                    getPrice(),
                    ERC20(indexToken).decimals()
                );
                total += profitInIndex;
                // return collateral
                if (colInIndex) {
                    total += collateral;
                } else {
                    // 100(6) usd
                    // 1000(6) usd/eth
                    collateral = divPrice(
                        collateral,
                        getPrice(),
                        ERC20(indexToken).decimals()
                    );
                    total += collateral;
                }
            } else {
                total += profit;

                if (colInIndex) {
                    total += mulPrice(
                        collateral,
                        getPrice(),
                        ERC20(indexToken).decimals()
                    );
                } else {
                    total += collateral;
                }
            }

            SafeERC20.safeTransfer(IERC20(asset_), msg.sender, total);
        }
        resetPositionAndUpdateSize(position, isLong);
    }

    function getPositionFees(uint256 amount) public pure returns (uint256) {
        return (amount / MAX_BASIS_POINTS) * POSITION_FEE;
    }

    function liquidate(address user, bool isLong) public {
        bool isLiquidateable_ = isLiquidateable(msg.sender, isLong);
        if (isLiquidateable_) revert NotLiquidateable();

        Position storage position = isLong
            ? longPositions[user]
            : shortPositions[user];
        // if size is usdc and price normally has 6 decimals
        // this needs to be accustomed to other decimals too;
        uint256 liquidationPenalty = getPorL(
            getPrice(),
            position.price,
            getSizeInTokens(position.size, position.price)
        );

        if (position.collateral >= liquidationPenalty) {
            position.collateral -= liquidationPenalty;
        } else {
            resetPositionAndUpdateSize(position, isLong);
        }
    }

    function getSizeInTokens(
        uint256 size,
        uint256 price
    ) public pure returns (uint256) {
        return (size / price) * SCALE_FACTOR;
    }

    function getPorL(
        uint256 currentPrice,
        uint positionPrice,
        uint256 sizeInTokens
    ) public pure returns (uint256) {
        uint256 priceChange = currentPrice >= positionPrice
            ? currentPrice - positionPrice
            : positionPrice - currentPrice;

        return priceChange * sizeInTokens;
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
    }

    function isLiquidateable(
        address user,
        bool isLong
    ) public view returns (bool) {
        Position memory position = isLong
            ? longPositions[user]
            : shortPositions[user];
        uint collateral = position.colInIndex
            ? mulPrice(
                position.collateral,
                getPrice(),
                ERC20(indexToken).decimals()
            )
            : position.collateral;

        return getLeverage(collateral, position.size) > MAX_LEVERAGE;
    }

    function getLeverage(
        uint256 amount,
        uint256 size
    ) public view returns (uint256) {
        if (size == 0 || amount == 0) revert ZeroAmount();
        return
            size / mulPrice(amount, getPrice(), ERC20(indexToken).decimals());
    }

    function isValidLeverage(uint256 leverage) public pure returns (bool) {
        return leverage <= MAX_LEVERAGE;
    }

    function isEnoughAssets(uint256 size) public view returns (bool) {
        uint256 totalAssets_ = totalAssets();

        uint256 availableAssets = (totalAssets_ / MAX_BASIS_POINTS) *
            MAX_UTILIZATION;

        return size + longOpenInterest + shortOpenInterest < availableAssets;
    }

    function totalAssets() public view returns (uint256) {
        return
            totalAssetLiquidity +
            mulPrice(
                totalIndexLiquidity,
                getPrice(),
                ERC20(indexToken).decimals()
            );
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
        uint64 toScale
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
        SafeERC20.safeTransferFrom(IERC20(token), address(this), to, amount);
    }
}
