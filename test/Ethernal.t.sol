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
            address(priceFeed),
            1_000
        );
    }

    modifier provideLiquidityInAsset() {
        uint liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));
        assertEq(liquidity, usdc.balanceOf(address(ethernal)));
        assertEq(liquidity, ethernal.totalAssetLiquidity());
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
        assertEq(liquidity, usdc.balanceOf(address(ethernal)));

        liquidity = 1000 ether;
        weth.mint(liquidityProviderOther, liquidity);
        vm.startPrank(liquidityProviderOther);
        weth.approve(address(ethernal), liquidity);

        uint price = getPrice();
        uint liquidityInUsdc = (liquidity * price) / WETH_DECIMALS;
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
        uint liquidity = 100_000 * USDC_DECIMALS;
        mintUSDC(liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        uint providerBalance = usdc.balanceOf(liquidityProvider);
        usdc.approve(address(ethernal), providerBalance);
        ethernal.addLiquidity(address(usdc), providerBalance, 0);
        vm.stopPrank();
        assertEq(providerBalance, ethernal.balanceOf(liquidityProvider));
        assertEq(liquidity, usdc.balanceOf(address(ethernal)));
        assertEq(liquidity, ethernal.totalAssetLiquidity());

        // Other Liquidity provider
        uint liquidityOther = liquidity / 2;
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
        assertEq(0, usdc.balanceOf(address(ethernal)));
        assertEq(0, ethernal.totalAssetLiquidity());
    }

    function testProvideLiquidityBothTokens() public provideLiquidityInAsset {
        uint liquidity = 1000 ether;
        weth.mint(liquidityProviderOther, liquidity);
        vm.startPrank(liquidityProviderOther);
        weth.approve(address(ethernal), liquidity);

        uint price = getPrice();
        uint liquidityInUsdc = (liquidity * price) / WETH_DECIMALS;
        ethernal.addLiquidity(address(weth), liquidity, 0);

        assertEq(liquidityInUsdc, ethernal.balanceOf(liquidityProviderOther));
        assertEq(liquidity, ethernal.totalIndexLiquidity());
        vm.stopPrank();
    }

    function testRemoveLiquidityInTokeOtherThanDeposited() public {
        testProvideLiquidityBothTokens();

        uint expectedLiquidity = 20 ether;
        uint removedLiquidityInAsset = mulPrice(expectedLiquidity, getPrice());
        uint lpToWithdraw = ethernal.previewDeposit(removedLiquidityInAsset);
        uint lpBalanceBefore = ethernal.balanceOf(liquidityProvider);
        vm.startPrank(liquidityProvider);
        ethernal.removeLiquidity(
            address(weth),
            lpToWithdraw,
            expectedLiquidity
        );
        assertEq(
            lpBalanceBefore - lpToWithdraw,
            ethernal.balanceOf(liquidityProvider)
        );
        assertEq(expectedLiquidity, weth.balanceOf(liquidityProvider));
    }

    function testOpenLongPositionInAsset() public provideLiquidityBoth {
        int collateral = int(100 * USDC_DECIMALS);
        int size = int(1000 * USDC_DECIMALS);
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        ethernal.updatePosition(address(usdc), collateral, size, true);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertEq(uint(collateral), position.collateral);
        assertEq(false, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(longOpenInterestBefore + uint(size), longOpenInterestAfter);
        assertEq(balanceBefore + uint(colPlusFee), balanceAfter);
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
        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        ethernal.updatePosition(address(usdc), collateral, size, true);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
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
        assertEq(longOpenInterestBefore + uint(size), longOpenInterestAfter);
        assertEq(balanceBefore + uint(colPlusFee), balanceAfter);
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
        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, true);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
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
        assertEq(longOpenInterestBefore + uint(size), longOpenInterestAfter);
        assertEq(balanceBefore - uint(-collateral), balanceAfter);
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
        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, true);
        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore + uint(size), longOpenInterestAfter);
        assertEq(balanceBefore + uint(fee), balanceAfter);
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
        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));
        ethernal.updatePosition(address(usdc), collateral, size, true);

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore - uint(-size), longOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testOpenLongPositionInIndex() public provideLiquidityBoth {
        int collateral = 1 ether;
        int size = int(mulPrice(10 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) +
            divPrice(fee, getPrice(), 10 ** 18);
        mintWeth(user0, colPlusFee);
        vm.startPrank(user0);
        weth.approve(address(ethernal), colPlusFee);
        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertEq(uint(collateral), position.collateral);
        assertEq(true, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(longOpenInterestBefore + uint(size), longOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
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

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();

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
        assertEq(longOpenInterestBefore, longOpenInterestAfter);
        assertEq(balanceBefore + uint(collateral), balanceAfter);
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

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();

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
        assertEq(longOpenInterestBefore, longOpenInterestAfter);
        assertEq(balanceBefore - uint(-collateral), balanceAfter);
    }

    function testIncreaseSizeLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int collateral = 0;
        int size = int(mulPrice(1 ether, getPrice()));
        uint fee = divPrice(
            ethernal.getPositionFee(uint(size)),
            getPrice(),
            10 ** 18
        );
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore + uint(size), longOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testDecreaseSizeLongPositionInIndex() public {
        testOpenLongPositionInIndex();

        int collateral = 0;
        int size = -int(mulPrice(1 ether, getPrice()));
        uint fee = divPrice(
            ethernal.getPositionFee(uint(-size)),
            getPrice(),
            10 ** 18
        );
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, true);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            true
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(longOpenInterestBefore - uint(-size), longOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testOpenShortPositionInAsset() public provideLiquidityBoth {
        int collateral = 100 * 10 ** 6;
        int size = 1000 * 10 ** 6;
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) + fee;
        mintUSDC(user0, colPlusFee);
        vm.startPrank(user0);
        usdc.approve(address(ethernal), colPlusFee);

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertEq(uint(collateral), position.collateral);
        assertEq(false, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(shortOpenInterestBefore + uint(size), shortOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
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

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

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
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
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

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(
            positionBefore.collateral - uint(-collateral),
            positionAfter.collateral
        );
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore - uint(-collateral), balanceAfter);
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

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore + uint(size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
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

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = usdc.balanceOf(address(ethernal));

        ethernal.updatePosition(address(usdc), collateral, size, false);

        uint balanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );

        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(false, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore - uint(-size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testOpenShortPositionInIndex() public provideLiquidityBoth {
        int collateral = 1 ether;
        int size = int(mulPrice(10 ether, getPrice()));
        uint fee = ethernal.getPositionFee(uint(size));
        uint colPlusFee = uint(collateral) +
            divPrice(fee, getPrice(), 10 ** 18);
        mintWeth(user0, colPlusFee);
        vm.startPrank(user0);
        weth.approve(address(ethernal), colPlusFee);
        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory position = ethernal.getPosition(user0, false);
        assertEq(uint(collateral), position.collateral);
        assertEq(true, position.colInIndex);
        assertEq(uint(size), position.size);
        assertEq(block.timestamp, position.lastTimeUpdated);
        assertEq(getPrice(), position.price);
        assertEq(shortOpenInterestBefore + uint(size), shortOpenInterestAfter);
        assertEq(balanceBefore + colPlusFee, balanceAfter);
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
        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(
            positionBefore.collateral + uint(collateral),
            positionAfter.collateral
        );
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size, positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore + uint(collateral), balanceAfter);
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
        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

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
        assertEq(shortOpenInterestBefore, shortOpenInterestAfter);
        assertEq(balanceBefore - uint(-collateral), balanceAfter);
    }
    function testIncreaseSizeShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int collateral = 0;
        int size = int(mulPrice(1 ether, getPrice()));
        uint fee = divPrice(
            ethernal.getPositionFee(uint(size)),
            getPrice(),
            10 ** 18
        );
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size + uint(size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore + uint(size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }
    function testDecreaseSizeShortPositionInIndex() public {
        testOpenShortPositionInIndex();

        int collateral = 0;
        int size = -int(mulPrice(1 ether, getPrice()));
        uint fee = divPrice(
            ethernal.getPositionFee(uint(-size)),
            getPrice(),
            10 ** 18
        );
        mintWeth(user0, uint(fee));

        vm.startPrank(user0);

        weth.approve(address(ethernal), uint(fee));

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint balanceBefore = weth.balanceOf(address(ethernal));

        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        ethernal.updatePosition(address(weth), collateral, size, false);

        uint balanceAfter = weth.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();

        Ethernal.Position memory positionAfter = ethernal.getPosition(
            user0,
            false
        );
        assertEq(positionBefore.collateral, positionAfter.collateral);
        assertEq(true, positionAfter.colInIndex);
        assertEq(positionBefore.size - uint(-size), positionAfter.size);
        assertEq(block.timestamp, positionAfter.lastTimeUpdated);
        assertEq(positionBefore.price, positionAfter.price);
        assertEq(shortOpenInterestBefore - uint(-size), shortOpenInterestAfter);
        assertEq(balanceBefore + fee, balanceAfter);
    }

    function testProfitableLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = 4000 * 10 ** 6;
        priceFeed.setPrice(newPrice);

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        uint borrowingFees = ethernal.calculateBorrowingFee(
            positionBefore.size,
            elapsedTime
        );

        int pnl = ethernal.getPorLInAsset(
            uint(newPrice),
            positionBefore.price,
            positionBefore.size
        );

        uint expectedBalanceInAsset = (uint(pnl) + positionBefore.collateral) -
            borrowingFees;
        uint expectedBalance = divPrice(
            expectedBalanceInAsset,
            getPrice(),
            10 ** 18
        );

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();

        uint userBalanceAfter = weth.balanceOf(user0);
        uint ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        assertEq(expectedBalance, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            longOpenInterestBefore - positionBefore.size,
            longOpenInterestAfter
        );
        assertEq(
            ethernalBalanceBefore - userBalanceAfter,
            ethernalBalanceAfter
        );
    }

    function testLossLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        uint newPrice = 2000 * USDC_DECIMALS;
        priceFeed.setPrice(int(newPrice));

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();

        uint userBalanceAfter = weth.balanceOf(user0);
        uint ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();

        uint positionCollateral = ((100 * USDC_DECIMALS) * WETH_DECIMALS) /
            getPrice();

        Ethernal.Position memory position = ethernal.getPosition(user0, true);
        assertTrue(userBalanceAfter < positionCollateral);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            longOpenInterestBefore - positionBefore.size,
            longOpenInterestAfter
        );
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testLiquidateableLongPositionInAsset() public {
        testOpenLongPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        uint newPrice = 2000 * USDC_DECIMALS;
        priceFeed.setPrice(int(newPrice));

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        vm.startPrank(user0);
        ethernal.closePosition(true);
        vm.stopPrank();

        uint userBalanceAfter = weth.balanceOf(user0);
        uint ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        assertEq(0, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            longOpenInterestBefore - positionBefore.size,
            longOpenInterestAfter
        );
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testProfitableLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(4000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        uint borrowingFees = ethernal.calculateBorrowingFee(
            positionBefore.size,
            elapsedTime
        );

        int pnl = ethernal.getPorLInAsset(
            uint(newPrice),
            positionBefore.price,
            positionBefore.size
        );

        uint expectedBalanceInAsset = (uint(pnl) +
            mulPrice(positionBefore.collateral, getPrice())) - borrowingFees;

        uint expectedBalance = divPrice(
            expectedBalanceInAsset,
            getPrice(),
            10 ** 18
        );

        vm.startPrank(user0);
        ethernal.closePosition(true);

        uint userBalanceAfter = weth.balanceOf(user0);
        uint ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        vm.stopPrank();

        assertEq(expectedBalance, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            longOpenInterestBefore - positionBefore.size,
            longOpenInterestAfter
        );
        assertEq(
            ethernalBalanceBefore - userBalanceAfter,
            ethernalBalanceAfter
        );
    }

    function testLossLongPositionInIndex() public {
        testOpenLongPositionInIndex();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(1000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint longOpenInterestBefore = ethernal.longOpenInterest();
        uint ethernalBalanceBefore = weth.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            true
        );

        vm.startPrank(user0);
        ethernal.closePosition(true);

        uint userBalanceAfter = weth.balanceOf(user0);
        uint ethernalBalanceAfter = weth.balanceOf(address(ethernal));
        uint longOpenInterestAfter = ethernal.longOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, true);

        assertEq(0, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            longOpenInterestBefore - positionBefore.size,
            longOpenInterestAfter
        );
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
    }

    function testProfitableShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(1_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint ethernalBalanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        uint borrowingFees = ethernal.calculateBorrowingFee(
            positionBefore.size,
            elapsedTime
        );

        int pnl = ethernal.getPorLInAsset(
            uint(newPrice),
            positionBefore.price,
            positionBefore.size
        );

        uint expectedBalanceInAsset = (uint(-pnl) + positionBefore.collateral) -
            borrowingFees;

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();

        uint userBalanceAfter = usdc.balanceOf(user0);
        uint ethernalBalanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        assertEq(expectedBalanceInAsset, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            shortOpenInterestBefore - positionBefore.size,
            shortOpenInterestAfter
        );
        assertEq(
            ethernalBalanceBefore - userBalanceAfter,
            ethernalBalanceAfter
        );
    }

    function testProfitableShortPositionInIndex() public {
        testOpenShortPositionInIndex();
        uint elapsedTime = 7 days;
        vm.warp(block.timestamp + elapsedTime);
        int newPrice = int(1_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint ethernalBalanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        uint borrowingFees = ethernal.calculateBorrowingFee(
            positionBefore.size,
            elapsedTime
        );

        int pnl = ethernal.getPorLInAsset(
            uint(newPrice),
            positionBefore.price,
            positionBefore.size
        );

        uint expectedBalanceInAsset = (uint(-pnl) +
            mulPrice(positionBefore.collateral, getPrice())) - borrowingFees;

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();

        uint userBalanceAfter = usdc.balanceOf(user0);
        uint ethernalBalanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        assertEq(expectedBalanceInAsset, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            shortOpenInterestBefore - positionBefore.size,
            shortOpenInterestAfter
        );
        assertEq(
            ethernalBalanceBefore - userBalanceAfter,
            ethernalBalanceAfter
        );
    }

    function testLossShortPositionInAsset() public {
        testOpenShortPositionInAsset();
        vm.warp(block.timestamp + 7 days);
        int newPrice = int(4_000 * USDC_DECIMALS);
        priceFeed.setPrice(newPrice);

        uint userBalanceBefore = mulPrice(1 ether, getPrice());
        uint shortOpenInterestBefore = ethernal.shortOpenInterest();
        uint ethernalBalanceBefore = usdc.balanceOf(address(ethernal));
        Ethernal.Position memory positionBefore = ethernal.getPosition(
            user0,
            false
        );

        vm.startPrank(user0);
        ethernal.closePosition(false);
        vm.stopPrank();

        uint userBalanceAfter = usdc.balanceOf(user0);
        uint ethernalBalanceAfter = usdc.balanceOf(address(ethernal));
        uint shortOpenInterestAfter = ethernal.shortOpenInterest();
        Ethernal.Position memory position = ethernal.getPosition(user0, false);

        assertEq(0, userBalanceAfter);
        assertEq(0, position.price);
        assertEq(0, position.size);
        assertEq(0, position.collateral);
        assertEq(0, position.lastTimeUpdated);
        assertEq(
            shortOpenInterestBefore - positionBefore.size,
            shortOpenInterestAfter
        );
        assertEq(ethernalBalanceBefore, ethernalBalanceAfter);
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

    function testCalcBorrowFees() public view {
        uint borrowAmount = 100 * USDC_DECIMALS;
        uint expectedFee = 10 * USDC_DECIMALS;
        uint elapsedTime = 365 days + 1;
        uint fee = ethernal.calculateBorrowingFee(elapsedTime, borrowAmount);
        assertEq(expectedFee, fee);
    }
    function testGetPorL() public view {
        uint posPrice = 1_000 * USDC_DECIMALS;
        uint currentPrice = 2_000 * USDC_DECIMALS;
        uint posSize = 10_000 * USDC_DECIMALS;
        uint posSizeInIndex = (posSize / posPrice) * WETH_DECIMALS;
        int priceDelta = int(currentPrice) - int(posPrice);
        int expectedPnl = (int(posSizeInIndex) * priceDelta) /
            int(WETH_DECIMALS);

        int pOrL = ethernal.getPorLInAsset(currentPrice, posPrice, posSize);

        assertEq(expectedPnl, pOrL);
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
