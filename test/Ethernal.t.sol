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
    int price = 3000 * 10 ** 6;
    function decimals() external pure returns (uint8) {
        return 6;
    }
    function setPrice(int price_) public {
        price = price_;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
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

    uint constant USDC_DECIMALS = 10 ** 6;
    uint constant WETH_DECIMALS = 10 ** 18;

    function setUp() public {
        usdc = new USDC();
        weth = new Weth();

        priceFeed = new PriceFeed();
        ethernal = new Ethernal(
            address(usdc),
            address(weth),
            address(priceFeed)
        );
    }

    modifier provideLiquidityUSDC() {
        uint liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));
        _;
    }

    modifier provideLiquidityBoth() {
        uint liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));

        liquidity = 1000 ether;
        weth.mint(liquidityProviderOther, liquidity);
        vm.startPrank(liquidityProviderOther);
        weth.approve(address(ethernal), liquidity);

        uint price = getPrice();
        uint liquidityInUsdc = (liquidity * price) / WETH_DECIMALS;
        ethernal.addLiquidity(address(weth), liquidity, 0);
        assertEq(liquidityInUsdc, ethernal.balanceOf(liquidityProviderOther));
        _;
    }

    function mintUSDC(address account, uint256 value) public {
        usdc.mint(account, value);
    }

    function mintWeth(address account, uint256 value) public {
        weth.mint(account, value);
    }

    function testProvideLiquidity() public {
        uint liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        vm.stopPrank();
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));

        // Other Liquidity provider
        uint liquidityOther = liquidity / 2;
        mintUSDC(liquidityProviderOther, liquidityOther);
        vm.startPrank(liquidityProviderOther);
        providerBalance = usdc.balanceOf(liquidityProviderOther);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProviderOther));
        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        // provide liquidity
        testProvideLiquidity();
        uint expectedLiquidity = 100_000 * USDC_DECIMALS;

        vm.startPrank(liquidityProvider);
        uint lpAmount = ethernal.balanceOf(liquidityProvider);
        ethernal.removeLiquidity(address(usdc), lpAmount, 0);
        vm.stopPrank();

        assertEq(expectedLiquidity, usdc.balanceOf(liquidityProvider));

        vm.startPrank(liquidityProviderOther);
        lpAmount = ethernal.balanceOf(liquidityProviderOther);
        ethernal.removeLiquidity(address(usdc), lpAmount, 0);
        vm.stopPrank();

        assertEq(expectedLiquidity / 2, usdc.balanceOf(liquidityProviderOther));
        assertEq(0, ethernal.totalSupply());
    }

    function testProvideLiquidityBothTokens() public provideLiquidityUSDC {
        uint liquidity = 100 ether;
        weth.mint(liquidityProviderOther, liquidity);
        vm.startPrank(liquidityProviderOther);
        weth.approve(address(ethernal), liquidity);

        uint price = getPrice();
        uint liquidityInUsdc = (liquidity * price) / WETH_DECIMALS;
        ethernal.addLiquidity(address(weth), liquidity, 0);

        assertEq(liquidityInUsdc, ethernal.balanceOf(liquidityProviderOther));
        vm.stopPrank();
    }

    function testOpenLongPositionInAsset() public provideLiquidityBoth {
        int collateral = int(100 * USDC_DECIMALS);
        int size = int(1000 * USDC_DECIMALS);
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);
        ethernal.updatePosition(address(usdc), collateral, size, true);

        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertEq(uint(collateral), position.collateral);
        assertEq(false, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
    }

    function testIncreaseColLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int collateral = 10 * 10 ** 6;
        int size = 0;
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(usdc), collateral, size, true);
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(
            positionBefore.collateral + uint(collateral),
            positionAfter.collateral
        );
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        // @audit check if ethernal has received
    }

    function testDecreaseColLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int collateral = -10 * 10 ** 6;
        int size = 0;

        vm.startPrank(user0);
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(usdc), collateral, size, true);
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(
            int(positionBefore.collateral) + collateral,
            int(positionAfter.collateral)
        );
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testIncreaseSizeLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int collateral = 0;
        int size = 300 * 10 ** 6;
        uint fee = ethernal.getPositionFee(uint(size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(usdc), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testDecreaseSizeLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        int collateral = 0;
        int size = -300 * 10 ** 6;
        uint fee = ethernal.getPositionFee(uint(-size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(usdc), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testOpenLongPositionInIndex() public provideLiquidityBoth {
        int collateral = 1 ether;
        int size = int(mulPrice(10 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintWeth(user0, colPlusFee);
        vm.startPrank(user0);
        weth.approve(address(ethernal), colPlusFee);
        ethernal.updatePosition(address(weth), collateral, size, true);

        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertEq(uint(collateral), position.collateral);
        assertEq(true, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
    }
    function testIncreaseColLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int collateral = 0.5 ether;
        int size = 0;

        mintWeth(user0, uint(collateral));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(collateral));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(weth), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(
            positionBefore.collateral + uint(collateral),
            positionAfter.collateral
        );
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testDecreaseColLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int collateral = -0.01 ether;
        int size = 0;

        vm.startPrank(user0);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(weth), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(
            positionBefore.collateral - uint(-collateral),
            positionAfter.collateral
        );
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size, positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testIncreaseSizeLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int collateral = 0;
        int size = int(mulPrice(1 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(size));
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(weth), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testDecreaseSizeLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int collateral = 0;
        int size = -int(mulPrice(1 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(-size));
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(weth), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testOpenShortPositionInAsset() public provideLiquidityBoth {
        int collateral = 100 * 10 ** 6;
        int size = 1000 * 10 ** 6;
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);
        ethernal.updatePosition(address(usdc), collateral, size, false);

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertEq(uint(collateral), position.collateral);
        assertEq(false, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
    }

    function testIncreaseColShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int collateral = 10 * 10 ** 6;
        int size = 0;
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(usdc), collateral, size, false);
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(
            positionBefore.collateral + uint(collateral),
            positionAfter.collateral
        );
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        // @audit check if ethernal has received
    }

    function testDecreaseColShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int collateral = -10 * 10 ** 6;
        int size = 0;

        vm.startPrank(user0);
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(usdc), collateral, size, false);
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(
            int(positionBefore.collateral) + collateral,
            int(positionAfter.collateral)
        );
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testIncreaseSizeShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int collateral = 0;
        int size = 300 * 10 ** 6;
        uint fee = ethernal.getPositionFee(uint(size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(usdc), collateral, size, false);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testDecreaseSizeShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        int collateral = 0;
        int size = -300 * 10 ** 6;
        uint fee = ethernal.getPositionFee(uint(-size));

        mintUSDC(user0, fee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), fee);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(usdc), collateral, size, false);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testOpenShortPositionInIndex() public provideLiquidityBoth {
        int collateral = 1 ether;
        int size = int(mulPrice(10 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintWeth(user0, colPlusFee);
        vm.startPrank(user0);
        weth.approve(address(ethernal), colPlusFee);
        ethernal.updatePosition(address(weth), collateral, size, false);

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertEq(uint(collateral), position.collateral);
        assertEq(true, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
    }

    function testIncreaseColShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int collateral = 0.5 ether;
        int size = 0;

        mintWeth(user0, uint(collateral));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(collateral));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(weth), collateral, size, false);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(
            positionBefore.collateral + uint(collateral),
            positionAfter.collateral
        );
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testDecreaseColShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int collateral = -0.01 ether;
        int size = 0;

        vm.startPrank(user0);

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(weth), collateral, size, false);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(
            positionBefore.collateral - uint(-collateral),
            positionAfter.collateral
        );
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size, positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }
    function testIncreaseSizeShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int collateral = 0;
        int size = int(mulPrice(1 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(size));
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(weth), collateral, size, false);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }
    function testDecreaseSizeShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int collateral = 0;
        int size = -int(mulPrice(1 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(-size));
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(weth), collateral, size, false);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
    }

    function testProfitableLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        int newPrice = 4000 * 10 ** 6;
        priceFeed.setPrice(newPrice);

        vm.startPrank(user0);
        uint balanceBefore = weth.balanceOf(user0);
        ethernal.closePosition(true);

        uint balanceAfter = weth.balanceOf(user0);
        vm.stopPrank();

        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertTrue(balanceAfter > balanceBefore);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
    }

    function testLossLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        uint newPrice = 2000 * USDC_DECIMALS;
        priceFeed.setPrice(int(newPrice));

        vm.startPrank(user0);
        ethernal.closePosition(true);

        uint balanceAfter = weth.balanceOf(user0);
        vm.stopPrank();

        uint positionCollateral = ((100 * USDC_DECIMALS) * WETH_DECIMALS) /
            getPrice();
        assertTrue(balanceAfter < positionCollateral);
    }

    function testLiquidateableLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        uint newPrice = 2000 * USDC_DECIMALS;
        priceFeed.setPrice(int(newPrice));

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();
        uint balanceAfter = weth.balanceOf(user0);
        assertEq(0, balanceAfter);
    }

    function testProfitableLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        vm.warp(block.timestamp + 7 days);
        int newPrice = int(4000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        vm.startPrank(user0);
        uint balanceBefore = weth.balanceOf(user0);
        ethernal.closePosition(true);

        uint balanceAfter = weth.balanceOf(user0);
        vm.stopPrank();

        assertTrue(balanceAfter > balanceBefore);
    }

    function testLossLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(1000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        vm.startPrank(user0);

        ethernal.closePosition(true);
        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        uint balance = weth.balanceOf(user0);
        assertEq(0, balance);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
    }

    function testProfitableShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        int newPrice = int(1_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        vm.startPrank(user0);
        uint balanceBefore = usdc.balanceOf(user0);
        ethernal.closePosition(false);
        uint balanceAfter = usdc.balanceOf(user0);
        vm.stopPrank();

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertTrue(balanceAfter > balanceBefore);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
    }

    function testProfitableShortPositionInIndex() public {
        testOpenShortPositionInIndex();
        vm.warp(block.timestamp + 2 days);
        int newPrice = int(1_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        vm.startPrank(user0);
        uint balanceBefore = usdc.balanceOf(user0);
        ethernal.closePosition(false);
        uint balanceAfter = usdc.balanceOf(user0);
        vm.stopPrank();

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertTrue(balanceAfter > balanceBefore);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
    }

    function testLossShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        int newPrice = int(4_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        uint balance = usdc.balanceOf(user0);
        assertEq(0, balance);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
    }

    function testLiquidateLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(2_800 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        uint borrowingFee = ethernal.calculateBorrowingFee(
            position.size,
            elapsedTime
        );
        int loss = ethernal.getPorLInAsset(
            getPrice(),
            position.price,
            position.size
        );

        uint colMinusFees = position.collateral - borrowingFee - uint(-loss);
        uint expectedFee = ethernal.getLiquidationFee(colMinusFees);

        vm.startPrank(user1);
        ethernal.liquidate(user0, true);
        uint liquidatorBalance = usdc.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testLiquidateLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(2_800 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        uint borrowingFee = ethernal.calculateBorrowingFee(
            position.size,
            elapsedTime
        );
        int loss = ethernal.getPorLInAsset(
            getPrice(),
            position.price,
            position.size
        );
        uint colMinusFees = position.collateral -
            divPrice((borrowingFee), getPrice(), 10 ** weth.decimals()) -
            divPrice((uint(-loss)), getPrice(), 10 ** weth.decimals());

        uint expectedFee = ethernal.getLiquidationFee(colMinusFees);

        vm.startPrank(user1);
        ethernal.liquidate(user0, true);
        uint liquidatorBalance = weth.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testLiquidateShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(3_100 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        uint borrowingFee = ethernal.calculateBorrowingFee(
            position.size,
            elapsedTime
        );
        int loss = ethernal.getPorLInAsset(
            getPrice(),
            position.price,
            position.size
        );
        uint colMinusFees = position.collateral - borrowingFee - uint(loss);

        uint expectedFee = ethernal.getLiquidationFee(colMinusFees);
        vm.startPrank(user1);
        ethernal.liquidate(user0, false);
        uint liquidatorBalance = usdc.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testLiquidateShortPositionInIndex() public {
        testOpenShortPositionInIndex();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(3_100 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        uint borrowingFee = ethernal.calculateBorrowingFee(
            position.size,
            elapsedTime
        );
        int loss = ethernal.getPorLInAsset(
            getPrice(),
            position.price,
            position.size
        );
        uint colMinusFees = position.collateral -
            divPrice(
                (borrowingFee + uint(loss)),
                getPrice(),
                10 ** weth.decimals()
            );

        uint expectedFee = ethernal.getLiquidationFee(colMinusFees);
        vm.startPrank(user1);
        ethernal.liquidate(user0, false);
        uint liquidatorBalance = weth.balanceOf(user1);
        assertEq(expectedFee, liquidatorBalance);
    }

    function testCalcBorrowFees() public {
        uint borrowAmount = 100 * USDC_DECIMALS;
        uint expectedFee = 10 * USDC_DECIMALS;
        uint elapsedTime = 365 days + 1;
        uint fee = ethernal.calculateBorrowingFee(elapsedTime, borrowAmount);
        assertEq(expectedFee, fee);
    }

    function getPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    function mulPrice(
        uint256 amount,
        uint256 price
    ) internal view returns (uint256) {
        return (amount * price) / 10 ** weth.decimals();
    }

    function divPrice(
        uint n,
        uint price,
        uint toScale
    ) internal pure returns (uint) {
        return (n * toScale) / price;
    }
}
