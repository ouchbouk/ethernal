// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Ethernal} from "../src/Ethernal.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceFeed} from "../src/interfaces/IPrice.sol";

contract USDC is ERC20 {
    constructor() ERC20("US Dollar Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 value) public {
        _mint(account, value);
    }
}

contract Weth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address account, uint256 value) public {
        _mint(account, value);
    }
}

contract PriceFeed is IPriceFeed {
    int256 price = 3000 * 10 ** 6;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function setPrice(int256 price_) public {
        price = price_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // int price = 3000 * 10 ** 6; // 3000 usdc/eth
        return (0, price, 0, 0, 0);
    }
}

contract EthernalTest is Test {
    Ethernal ethernal;
    USDC usdc;
    Weth weth;
    PriceFeed priceFeed;

    address liquidityProvider = makeAddr("liquidityProvider");
    address liquidityProviderOther = makeAddr("liquidityProviderOther");
    address user0 = makeAddr("user0");
    address user1 = makeAddr("user1");

    uint256 constant USDC_DECIMALS = 10 ** 6;
    uint256 constant WETH_DECIMALS = 10 ** 18;

    function setUp() public {
        usdc = new USDC();
        weth = new Weth();

        priceFeed = new PriceFeed();
        ethernal = new Ethernal(address(usdc), address(weth), address(priceFeed), 1_000);
    }

    modifier provideLiquidityInAsset() {
        uint256 liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint256 providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));
        assertEq(liquidity, usdc.balanceOf(address(ethernal)));
        assertEq(liquidity, ethernal.totalAssetLiquidity());
        _;
    }

    modifier provideLiquidityBoth() {
        uint256 liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint256 providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));
        assertEq(liquidity, usdc.balanceOf(address(ethernal)));

        liquidity = 1000 ether;
        weth.mint(liquidityProviderOther, liquidity);
        vm.startPrank(liquidityProviderOther);
        weth.approve(address(ethernal), liquidity);

        uint256 price = getPrice();
        uint256 liquidityInUsdc = (liquidity * price) / WETH_DECIMALS;
        ethernal.addLiquidity(address(weth), liquidity, 0);
        assertEq(liquidityInUsdc, ethernal.balanceOf(liquidityProviderOther));
        assertEq(liquidity, weth.balanceOf(address(ethernal)));
        _;
    }

    function mintUSDC(address account, uint256 value) public {
        usdc.mint(account, value);
    }

    function mintWeth(address account, uint256 value) public {
        weth.mint(account, value);
    }

    function testProvideLiquidityInAsset() public {
        uint256 liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint256 providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        vm.stopPrank();
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));
        assertEq(liquidity, usdc.balanceOf(address(ethernal)));
        assertEq(liquidity, ethernal.totalAssetLiquidity());

        // Other Liquidity provider
        uint256 liquidityOther = liquidity / 2;
        mintUSDC(liquidityProviderOther, liquidityOther);
        vm.startPrank(liquidityProviderOther);
        providerBalance = usdc.balanceOf(liquidityProviderOther);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProviderOther));
        assertEq(liquidityOther + liquidity, usdc.balanceOf(address(ethernal)));
        assertEq(liquidityOther + liquidity, ethernal.totalAssetLiquidity());
        vm.stopPrank();
    }

    function testRemoveLiquidityInAsset() public {
        // provide liquidity
        testProvideLiquidityInAsset();
        uint256 expectedLiquidity = 100_000 * USDC_DECIMALS;

        vm.startPrank(liquidityProvider);
        uint256 lpAmount = ethernal.balanceOf(liquidityProvider);
        ethernal.removeLiquidity(address(usdc), lpAmount, 0);
        vm.stopPrank();

        assertEq(expectedLiquidity, usdc.balanceOf(liquidityProvider));

        vm.startPrank(liquidityProviderOther);
        lpAmount = ethernal.balanceOf(liquidityProviderOther);
        ethernal.removeLiquidity(address(usdc), lpAmount, 0);
        vm.stopPrank();

        assertEq(expectedLiquidity / 2, usdc.balanceOf(liquidityProviderOther));
        assertEq(0, ethernal.totalSupply());
        assertEq(0, usdc.balanceOf(address(ethernal)));
        assertEq(0, ethernal.totalAssetLiquidity());
    }

    function testProvideLiquidityBothTokens() public provideLiquidityInAsset {
        uint256 liquidity = 1000 ether;
        weth.mint(liquidityProviderOther, liquidity);
        vm.startPrank(liquidityProviderOther);
        weth.approve(address(ethernal), liquidity);

        uint256 price = getPrice();
        uint256 liquidityInUsdc = (liquidity * price) / WETH_DECIMALS;
        ethernal.addLiquidity(address(weth), liquidity, 0);

        assertEq(liquidityInUsdc, ethernal.balanceOf(liquidityProviderOther));
        assertEq(liquidity, ethernal.totalIndexLiquidity());
        vm.stopPrank();
    }

    function testRemoveLiquidityInTokeOtherThanDeposited() public {
        testProvideLiquidityBothTokens();

        uint256 expectedLiquidity = 20 ether;
        uint256 removedLiquidityInAsset = mulPrice(expectedLiquidity, getPrice());
        uint256 lpToWithdraw = ethernal.previewDeposit(removedLiquidityInAsset);
        uint256 lpBalanceBefore = ethernal.balanceOf(liquidityProvider);
        vm.startPrank(liquidityProvider);
        ethernal.removeLiquidity(address(weth), lpToWithdraw, expectedLiquidity);
        assertEq(lpBalanceBefore - lpToWithdraw, ethernal.balanceOf(liquidityProvider));
        assertEq(expectedLiquidity, weth.balanceOf(liquidityProvider));
    }

    function testOpenLongPositionInAsset() public provideLiquidityBoth {
        int256 collateral = int256(100 * USDC_DECIMALS);
        int256 size = int256(1000 * USDC_DECIMALS);
        uint256 fee = ethernal.getPositionFee(uint256(size));
        uint256 colPlusFee = uint256(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        ethernal.updatePosition(address(usdc), collateral, size, true);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertEq(uint256(collateral), position.collateral);
        assertEq(false, position.colInIndex);
        assertEq(uint256(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(longOpenInterestBefore + uint256(size), longOpenInterestAfter);
        assertEq(balanceBefore + uint256(colPlusFee), balanceAfter);
    }

    function testIncreaseColLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int256 collateral = 10 * 10 ** 6;
        int256 size = 0;
        uint256 fee = ethernal.getPositionFee(uint256(size));
        uint256 colPlusFee = uint256(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);
        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        ethernal.updatePosition(address(usdc), collateral, size, true);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        assertEq(positionBefore.collateral + uint256(collateral), positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore + uint256(size), longOpenInterestAfter);
        assertEq(balanceBefore + uint256(colPlusFee), balanceAfter);
    }

    function testDecreaseColLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int256 collateral = -10 * 10 ** 6;
        int256 size = 0;

        vm.startPrank(user0);
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);
        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, true);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        assertEq(int256(positionBefore.collateral) + collateral, int256(positionAfter.collateral));
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore + uint256(size), longOpenInterestAfter);
        assertEq(balanceBefore - uint256(-collateral), balanceAfter);
    }

    function testIncreaseSizeLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int256 collateral = 0;
        int256 size = 300 * 10 ** 6;
        uint256 fee = ethernal.getPositionFee(uint256(size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);
        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, true);
        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore + uint256(size), longOpenInterestAfter);
        assertEq(balanceBefore + uint256(fee), balanceAfter);
    }

    function testDecreaseSizeLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int256 collateral = 0;
        int256 size = -300 * 10 ** 6;
        uint256 fee = ethernal.getPositionFee(uint256(-size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);
        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));
        ethernal.updatePosition(address(usdc), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint256(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore - uint256(-size), longOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testOpenLongPositionInIndex() public provideLiquidityBoth {
        int256 collateral = 1 ether;
        int256 size = int256(mulPrice(10 ether, getPrice()));
        uint256 fee = ethernal.getPositionFee(uint256(size));
        uint256 colPlusFee = uint256(collateral) + divPrice(fee, getPrice(), 10 ** 18);
        mintWeth(user0, colPlusFee);
        vm.startPrank(user0);
        weth.approve(address(ethernal), colPlusFee);
        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertEq(uint256(collateral), position.collateral);
        assertEq(true, position.colInIndex);
        assertEq(uint256(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(longOpenInterestBefore + uint256(size), longOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
    }

    function testIncreaseColLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int256 collateral = 0.5 ether;
        int256 size = 0;

        mintWeth(user0, uint256(collateral));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint256(collateral));

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        assertEq(positionBefore.collateral + uint256(collateral), positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore, longOpenInterestAfter);
        assertEq(balanceBefore + uint256(collateral), balanceAfter);
    }

    function testDecreaseColLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int256 collateral = -0.01 ether;
        int256 size = 0;

        vm.startPrank(user0);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        assertEq(positionBefore.collateral - uint256(-collateral), positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size, positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore, longOpenInterestAfter);
        assertEq(balanceBefore - uint256(-collateral), balanceAfter);
    }

    function testIncreaseSizeLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int256 collateral = 0;
        int256 size = int256(mulPrice(1 ether, getPrice()));
        uint256 fee = divPrice(ethernal.getPositionFee(uint256(size)), getPrice(), 10 ** 18);
        mintWeth(user0, uint256(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint256(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore + uint256(size), longOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testDecreaseSizeLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int256 collateral = 0;
        int256 size = -int256(mulPrice(1 ether, getPrice()));
        uint256 fee = divPrice(ethernal.getPositionFee(uint256(-size)), getPrice(), 10 ** 18);
        mintWeth(user0, uint256(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint256(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, true);
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint256(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore - uint256(-size), longOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testOpenShortPositionInAsset() public provideLiquidityBoth {
        int256 collateral = 100 * 10 ** 6;
        int256 size = 1000 * 10 ** 6;
        uint256 fee = ethernal.getPositionFee(uint256(size));
        uint256 colPlusFee = uint256(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertEq(uint256(collateral), position.collateral);
        assertEq(false, position.colInIndex);
        assertEq(uint256(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(shortOpenInterestBefore + uint256(size), shortOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
    }

    function testIncreaseColShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int256 collateral = 10 * 10 ** 6;
        int256 size = 0;
        uint256 fee = ethernal.getPositionFee(uint256(size));
        uint256 colPlusFee = uint256(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);
        assertEq(positionBefore.collateral + uint256(collateral), positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
    }

    function testDecreaseColShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int256 collateral = -10 * 10 ** 6;
        int256 size = 0;

        vm.startPrank(user0);
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);
        assertEq(positionBefore.collateral - uint256(-collateral), positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore - uint256(-collateral), balanceAfter);
    }

    function testIncreaseSizeShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int256 collateral = 0;
        int256 size = 300 * 10 ** 6;
        uint256 fee = ethernal.getPositionFee(uint256(size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore + uint256(size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testDecreaseSizeShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int256 collateral = 0;
        int256 size = -300 * 10 ** 6;
        uint256 fee = ethernal.getPositionFee(uint256(-size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint256 balanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint256(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore - uint256(-size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testOpenShortPositionInIndex() public provideLiquidityBoth {
        int256 collateral = 1 ether;
        int256 size = int256(mulPrice(10 ether, getPrice()));
        uint256 fee = ethernal.getPositionFee(uint256(size));
        uint256 colPlusFee = uint256(collateral) + divPrice(fee, getPrice(), 10 ** 18);
        mintWeth(user0, colPlusFee);
        vm.startPrank(user0);
        weth.approve(address(ethernal), colPlusFee);
        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertEq(uint256(collateral), position.collateral);
        assertEq(true, position.colInIndex);
        assertEq(uint256(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(shortOpenInterestBefore + uint256(size), shortOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
    }

    function testIncreaseColShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int256 collateral = 0.5 ether;
        int256 size = 0;

        mintWeth(user0, uint256(collateral));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint256(collateral));

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);
        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);
        assertEq(positionBefore.collateral + uint256(collateral), positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size, positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore + uint256(collateral), balanceAfter);
    }

    function testDecreaseColShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int256 collateral = -0.01 ether;
        int256 size = 0;

        vm.startPrank(user0);

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);
        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);
        assertEq(positionBefore.collateral - uint256(-collateral), positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size, positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore - uint256(-collateral), balanceAfter);
    }

    function testIncreaseSizeShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int256 collateral = 0;
        int256 size = int256(mulPrice(1 ether, getPrice()));
        uint256 fee = divPrice(ethernal.getPositionFee(uint256(size)), getPrice(), 10 ** 18);
        mintWeth(user0, uint256(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint256(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint256(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore + uint256(size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testDecreaseSizeShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int256 collateral = 0;
        int256 size = -int256(mulPrice(1 ether, getPrice()));
        uint256 fee = divPrice(ethernal.getPositionFee(uint256(-size)), getPrice(), 10 ** 18);
        mintWeth(user0, uint256(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint256(fee));

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 balanceBefore = weth.balanceOf(address(ethernal));

        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint256 balanceAfter = weth.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(user0, false);
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint256(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore - uint256(-size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testProfitableLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = 4000 * 10 ** 6;
        priceFeed.setPrice(newPrice);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        uint256 borrowingFees = ethernal.calculateBorrowingFee(positionBefore.size, elapsedTime);

        int256 pnl = ethernal.getPorLInAsset(uint256(newPrice), positionBefore.price, positionBefore.size);

        uint256 expectedBalanceInAsset = (uint256(pnl) + positionBefore.collateral) - borrowingFees;
        uint256 expectedBalance = divPrice(expectedBalanceInAsset, getPrice(), 10 ** 18);

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();

        uint256 userBalanceAfter = weth.balanceOf(user0);
        uint256 ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        assertEq(expectedBalance, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(longOpenInterestBefore - positionBefore.size, longOpenInterestAfter);
        assertEq(ethernalBalanceBefore - userBalanceAfter, ethernalBalanceAfter);
    }

    function testLossLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        uint256 newPrice = 2000 * USDC_DECIMALS;
        priceFeed.setPrice(int256(newPrice));

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();

        uint256 userBalanceAfter = weth.balanceOf(user0);
        uint256 ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();

        uint256 positionCollateral = ((100 * USDC_DECIMALS) * WETH_DECIMALS) / getPrice();

        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertTrue(userBalanceAfter < positionCollateral);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(longOpenInterestBefore - positionBefore.size, longOpenInterestAfter);
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testLiquidateableLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        uint256 newPrice = 2000 * USDC_DECIMALS;
        priceFeed.setPrice(int256(newPrice));

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();

        uint256 userBalanceAfter = weth.balanceOf(user0);
        uint256 ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        assertEq(0, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(longOpenInterestBefore - positionBefore.size, longOpenInterestAfter);
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testProfitableLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(4000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        uint256 borrowingFees = ethernal.calculateBorrowingFee(positionBefore.size, elapsedTime);

        int256 pnl = ethernal.getPorLInAsset(uint256(newPrice), positionBefore.price, positionBefore.size);

        uint256 expectedBalanceInAsset =
            (uint256(pnl) + mulPrice(positionBefore.collateral, getPrice())) - borrowingFees;

        uint256 expectedBalance = divPrice(expectedBalanceInAsset, getPrice(), 10 ** 18);

        vm.startPrank(user0);
        ethernal.closePosition(true);

        uint256 userBalanceAfter = weth.balanceOf(user0);
        uint256 ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        vm.stopPrank();

        assertEq(expectedBalance, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(longOpenInterestBefore - positionBefore.size, longOpenInterestAfter);
        assertEq(ethernalBalanceBefore - userBalanceAfter, ethernalBalanceAfter);
    }

    function testLossLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(1000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint256 longOpenInterestBefore = ethernal.longOpenInterest();
        uint256 ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, true);

        vm.startPrank(user0);
        ethernal.closePosition(true);

        uint256 userBalanceAfter = weth.balanceOf(user0);
        uint256 ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint256 longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        assertEq(0, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(longOpenInterestBefore - positionBefore.size, longOpenInterestAfter);
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testProfitableShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(1_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 ethernalBalanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 borrowingFees = ethernal.calculateBorrowingFee(positionBefore.size, elapsedTime);

        int256 pnl = ethernal.getPorLInAsset(uint256(newPrice), positionBefore.price, positionBefore.size);

        uint256 expectedBalanceInAsset = (uint256(-pnl) + positionBefore.collateral) - borrowingFees;

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();

        uint256 userBalanceAfter = usdc.balanceOf(user0);
        uint256 ethernalBalanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        assertEq(expectedBalanceInAsset, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(shortOpenInterestBefore - positionBefore.size, shortOpenInterestAfter);
        assertEq(ethernalBalanceBefore - userBalanceAfter, ethernalBalanceAfter);
    }

    function testProfitableShortPositionInIndex() public {
        testOpenShortPositionInIndex();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(1_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 ethernalBalanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        uint256 borrowingFees = ethernal.calculateBorrowingFee(positionBefore.size, elapsedTime);

        int256 pnl = ethernal.getPorLInAsset(uint256(newPrice), positionBefore.price, positionBefore.size);

        uint256 expectedBalanceInAsset =
            (uint256(-pnl) + mulPrice(positionBefore.collateral, getPrice())) - borrowingFees;

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();

        uint256 userBalanceAfter = usdc.balanceOf(user0);
        uint256 ethernalBalanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        assertEq(expectedBalanceInAsset, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(shortOpenInterestBefore - positionBefore.size, shortOpenInterestAfter);
        assertEq(ethernalBalanceBefore - userBalanceAfter, ethernalBalanceAfter);
    }

    function testLossShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        int256 newPrice = int256(4_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint256 userBalanceBefore = mulPrice(1 ether, getPrice());
        uint256 shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint256 ethernalBalanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(user0, false);

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();

        uint256 userBalanceAfter = usdc.balanceOf(user0);
        uint256 ethernalBalanceAfter = usdc.balanceOf(address(ethernal));
        uint256 shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        assertEq(0, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(shortOpenInterestBefore - positionBefore.size, shortOpenInterestAfter);
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testLiquidateLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(2_800 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        uint256 borrowingFee = ethernal.calculateBorrowingFee(position.size, elapsedTime);
        int256 loss = ethernal.getPorLInAsset(getPrice(), position.price, position.size);

        uint256 colMinusFees = position.collateral - borrowingFee - uint256(-loss);
        uint256 expectedFee = ethernal.getLiquidationFee(colMinusFees);

        vm.startPrank(user1);
        ethernal.liquidate(user0, true);
        uint256 liquidatorBalance = usdc.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testLiquidateLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(2_800 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        uint256 borrowingFee = ethernal.calculateBorrowingFee(position.size, elapsedTime);
        int256 loss = ethernal.getPorLInAsset(getPrice(), position.price, position.size);
        uint256 colMinusFees = position.collateral - divPrice((borrowingFee), getPrice(), 10 ** weth.decimals())
            - divPrice((uint256(-loss)), getPrice(), 10 ** weth.decimals());

        uint256 expectedFee = ethernal.getLiquidationFee(colMinusFees);

        vm.startPrank(user1);
        ethernal.liquidate(user0, true);
        uint256 liquidatorBalance = weth.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testLiquidateShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(3_100 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        uint256 borrowingFee = ethernal.calculateBorrowingFee(position.size, elapsedTime);
        int256 loss = ethernal.getPorLInAsset(getPrice(), position.price, position.size);
        uint256 colMinusFees = position.collateral - borrowingFee - uint256(loss);

        uint256 expectedFee = ethernal.getLiquidationFee(colMinusFees);
        vm.startPrank(user1);
        ethernal.liquidate(user0, false);
        uint256 liquidatorBalance = usdc.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testLiquidateShortPositionInIndex() public {
        testOpenShortPositionInIndex();
        uint256 elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int256 newPrice = int256(3_100 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        uint256 borrowingFee = ethernal.calculateBorrowingFee(position.size, elapsedTime);
        int256 loss = ethernal.getPorLInAsset(getPrice(), position.price, position.size);
        uint256 colMinusFees =
            position.collateral - divPrice((borrowingFee + uint256(loss)), getPrice(), 10 ** weth.decimals());

        uint256 expectedFee = ethernal.getLiquidationFee(colMinusFees);
        vm.startPrank(user1);
        ethernal.liquidate(user0, false);
        uint256 liquidatorBalance = weth.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testCalcBorrowFees() public view {
        uint256 borrowAmount = 100 * USDC_DECIMALS;
        uint256 expectedFee = 10 * USDC_DECIMALS;
        uint256 elapsedTime = 365 days + 1;
        uint256 fee = ethernal.calculateBorrowingFee(elapsedTime, borrowAmount);
        assertEq(expectedFee, fee);
    }

    function testGetPorL() public view {
        uint256 posPrice = 1_000 * USDC_DECIMALS;
        uint256 currentPrice = 2_000 * USDC_DECIMALS;
        uint256 posSize = 10_000 * USDC_DECIMALS;
        uint256 posSizeInIndex = (posSize / posPrice) * WETH_DECIMALS;
        int256 priceDelta = int256(currentPrice) - int256(posPrice);
        int256 expectedPnl = (int256(posSizeInIndex) * priceDelta) / int256(WETH_DECIMALS);

        int256 pOrL = ethernal.getPorLInAsset(currentPrice, posPrice, posSize);

        assertEq(expectedPnl, pOrL);
    }

    function getPrice() public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        return uint256(price);
    }

    function mulPrice(uint256 amount, uint256 price) internal view returns (uint256) {
        return (amount * price) / 10 ** weth.decimals();
    }

    function divPrice(uint256 n, uint256 price, uint256 toScale) internal pure returns (uint256) {
        return (n * toScale) / price;
    }
}
