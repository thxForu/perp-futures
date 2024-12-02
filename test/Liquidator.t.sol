// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "../src/Liquidator.sol";
import "../src/Storage.sol";
import "../src/Trading.sol";
import "./mocks/MockDai.sol";
import "./mocks/MockPriceFeed.sol";

contract LiquidatorTest is Test {
    Liquidator public liquidator;
    Trading public trading;
    Storage public storageContract;
    MockPriceFeed public priceFeed;
    MockDai public dai;

    address public trader = address(1);
    address public liquidatorAcc = address(2);
    uint256 public constant INITIAL_DAI = 10000e18;
    uint256 public constant INITIAL_PRICE = 2000e8;
    uint256 public constant PAIR_INDEX = 0;

    uint256 public constant MAINTENANCE_MARGIN = 50; // 0.5%
    uint256 public constant LIQUIDATION_FEE = 100; // 1%
    uint256 public constant MAX_DISCOUNT = 200; // 2%

    function setUp() public {
        dai = new MockDai();
        priceFeed = new MockPriceFeed(int256(INITIAL_PRICE));

        storageContract = new Storage();
        trading = new Trading(address(storageContract), address(dai));
        liquidator = new Liquidator(
            address(storageContract),
            address(trading),
            ILiquidator.LiquidationThresholds({
                maintenanceMargin: MAINTENANCE_MARGIN,
                liquidationFee: LIQUIDATION_FEE,
                maxLiquidationDiscount: MAX_DISCOUNT
            })
        );

        storageContract.setTradingContract(address(trading));
        trading.setLiquidator(address(liquidator));
        trading.setPriceFeed(PAIR_INDEX, address(priceFeed));

        dai.mint(trader, INITIAL_DAI);
        dai.mint(address(trading), INITIAL_DAI * 2);

        vm.startPrank(trader);
        dai.approve(address(trading), type(uint256).max);
        vm.stopPrank();
    }

    function testInitialSetup() public {
        assertEq(address(liquidator.storageContract()), address(storageContract));
        assertEq(address(liquidator.tradingContract()), address(trading));

        (uint256 mm, uint256 lf, uint256 md) = liquidator.thresholds();
        assertEq(mm, MAINTENANCE_MARGIN);
        assertEq(lf, LIQUIDATION_FEE);
        assertEq(md, MAX_DISCOUNT);
    }

    function testCannotLiquidateHealthyPosition() public {
        uint256 positionSize = 1000e18;
        uint256 leverage = 10;

        vm.startPrank(trader);
        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, 0, 0);
        vm.stopPrank();

        vm.startPrank(liquidatorAcc);
        vm.expectRevert("Position cannot be liquidated");
        liquidator.liquidate(0);
        vm.stopPrank();
    }

    function testSuccessfulLiquidation() public {
        uint256 positionSize = 10000e18;
        uint256 leverage = 20;

        vm.startPrank(trader);
        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, 0, 0);
        vm.stopPrank();

        // drop price to trigger liquidation (5%)
        int256 newPrice = int256(INITIAL_PRICE * 95 / 100);
        priceFeed.setPrice(newPrice);

        uint256 liquidatorBalanceBefore = dai.balanceOf(liquidatorAcc);
        uint256 expectedReward = liquidator.calculateLiquidationReward(positionSize);

        vm.startPrank(liquidatorAcc);
        uint256 actualReward = liquidator.liquidate(0);
        vm.stopPrank();

        uint256 liquidatorBalanceAfter = dai.balanceOf(liquidatorAcc);
        assertEq(liquidatorBalanceAfter - liquidatorBalanceBefore, actualReward, "Liquidator should receive reward");
        assertEq(actualReward, expectedReward, "Reward calculation mismatch");
    }

    function testCalculateLiquidationReward() public {
        uint256 positionSize = 1000e18;
        uint256 reward = liquidator.calculateLiquidationReward(positionSize);

        uint256 expectedReward = (positionSize * LIQUIDATION_FEE) / 10000;
        uint256 maxDiscount = (positionSize * MAX_DISCOUNT) / 10000;

        assertEq(reward, expectedReward);
        assertTrue(reward <= maxDiscount);
    }

    function testSetThresholds() public {
        ILiquidator.LiquidationThresholds memory newThresholds = ILiquidator.LiquidationThresholds({
            maintenanceMargin: 100, // 1%
            liquidationFee: 150, // 1.5%
            maxLiquidationDiscount: 250 // 2.5%
        });

        liquidator.setThresholds(newThresholds);

        (uint256 mm, uint256 lf, uint256 md) = liquidator.thresholds();
        assertEq(mm, 100);
        assertEq(lf, 150);
        assertEq(md, 250);
    }

    function testCannotSetInvalidThresholds() public {
        ILiquidator.LiquidationThresholds memory invalidThresholds =
            ILiquidator.LiquidationThresholds({maintenanceMargin: 0, liquidationFee: 100, maxLiquidationDiscount: 200});

        vm.expectRevert("Invalid maintenance margin");
        liquidator.setThresholds(invalidThresholds);
    }

    function testLiquidationAtDifferentPrices() public {
        uint256 positionSize = 1000e18;
        uint256 leverage = 20;

        vm.startPrank(trader);
        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, 0, 0);
        vm.stopPrank();

        // test for different price levels
        uint256[] memory priceChanges = new uint256[](3);
        priceChanges[0] = 98; // -2%
        priceChanges[1] = 95; // -5%
        priceChanges[2] = 90; // -10%

        for (uint256 i = 0; i < priceChanges.length; i++) {
            int256 newPrice = int256(INITIAL_PRICE * priceChanges[i] / 100);
            priceFeed.setPrice(newPrice);

            bool canLiquidate = liquidator.checkLiquidation(0);
            console.log("Price change:", priceChanges[i], "%. Can liquidate:", canLiquidate);
        }
    }
}
