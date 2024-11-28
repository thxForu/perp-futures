// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "../src/Trading.sol";
import "../src/Storage.sol";
import "./mocks/MockDai.sol";
import "./mocks/MockPriceFeed.sol";

contract TradingTest is Test {
    Trading public trading;
    Storage public storageContract;
    MockPriceFeed public priceFeed;
    MockDai public dai;

    address public trader = address(1);
    uint256 public constant INITIAL_DAI = 10000e18;
    uint256 public constant INITIAL_PRICE = 2000e8;
    uint256 public constant PAIR_INDEX = 0;

    function setUp() public {
        dai = new MockDai();
        priceFeed = new MockPriceFeed(int256(INITIAL_PRICE));

        storageContract = new Storage();
        trading = new Trading(address(storageContract), address(dai));

        storageContract.setTradingContract(address(trading));
        trading.setPriceFeed(PAIR_INDEX, address(priceFeed));

        dai.mint(trader, INITIAL_DAI);
        dai.mint(address(trading), INITIAL_DAI * 2);

        vm.startPrank(trader);
        dai.approve(address(trading), type(uint256).max);
        vm.stopPrank();
    }

    function testGetCurrentPrice() public {
        assertEq(address(trading.priceFeeds(PAIR_INDEX)), address(priceFeed), "price feed not set correctly");

        uint256 price = trading.getCurrentPrice(PAIR_INDEX);
        assertEq(price, INITIAL_PRICE, "incorrect price");
        console.log("current price:", price / 1e8);
    }

    function testOpenPositionWithRealPrice() public {
        uint256 positionSize = 1000e18; // 1000 DAI
        uint256 leverage = 2;
        uint256 currentPrice = trading.getCurrentPrice(PAIR_INDEX);
        uint256 tpPrice = currentPrice + (currentPrice * 5 / 100); // +5%
        uint256 slPrice = currentPrice - (currentPrice * 5 / 100); // -5%

        vm.startPrank(trader);
        trading.initiateMarketOrder(
            PAIR_INDEX,
            true, // long
            leverage,
            positionSize,
            tpPrice,
            slPrice
        );
        vm.stopPrank();

        IStorage.Trade memory trade = storageContract.getTrade(0);
        assertEq(trade.trader, trader);
        assertEq(trade.openPrice, currentPrice);
        assertEq(trade.leverage, leverage);
        assertEq(trade.positionSizeDai, positionSize);
        assertEq(trade.buy, true);

        console.log("Position opened at price:", currentPrice / 1e8);
        console.log("Take Profit set at:", tpPrice / 1e8);
        console.log("Stop Loss set at:", slPrice / 1e8);
    }

    function testClosePosition() public {
        uint256 positionSize = 1000e18;
        uint256 leverage = 2;
        uint256 initialPrice = trading.getCurrentPrice(PAIR_INDEX);
        uint256 tpPrice = initialPrice + (initialPrice * 5 / 100);
        uint256 slPrice = initialPrice - (initialPrice * 5 / 100);

        vm.startPrank(trader);

        // open position
        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, tpPrice, slPrice);

        uint256 balanceBefore = dai.balanceOf(trader);

        // close position
        trading.closePosition(0);

        uint256 balanceAfter = dai.balanceOf(trader);
        vm.stopPrank();

        // verify balance
        assertGe(
            balanceAfter, balanceBefore - positionSize, "should return at least initial position size minus losses"
        );

        IStorage.Trade memory trade = storageContract.getTrade(0);
        assertEq(trade.trader, address(0), "trade should be removed");

        console.log("balance before:", balanceBefore / 1e18);
        console.log("balance after:", balanceAfter / 1e18);
        console.log("pnl:", (int256(balanceAfter - balanceBefore)) / 1e18);
    }

    function testCloseLongPositionWithProfit() public {
        uint256 positionSize = 1000e18;
        uint256 leverage = 2;

        vm.startPrank(trader);

        uint256 balanceBefore = dai.balanceOf(trader);

        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, 0, 0);

        // price up 10%
        priceFeed.setPrice(int256(INITIAL_PRICE * 110 / 100));

        trading.closePosition(0);
        uint256 balanceAfter = dai.balanceOf(trader);

        vm.stopPrank();

        assertGt(balanceAfter, balanceBefore - positionSize, "should have profit");
        console.log("profit:", (balanceAfter - (balanceBefore - positionSize)) / 1e18, "DAI");
    }

    function testCloseShortPositionWithLoss() public {
        uint256 positionSize = 1000e18;
        uint256 leverage = 2;

        vm.startPrank(trader);

        uint256 initialBalance = dai.balanceOf(trader);

        trading.initiateMarketOrder(PAIR_INDEX, false, leverage, positionSize, 0, 0);

        // price up 5%
        priceFeed.setPrice(int256(INITIAL_PRICE * 105 / 100));

        trading.closePosition(0);
        uint256 finalBalance = dai.balanceOf(trader);

        vm.stopPrank();

        assertLt(finalBalance, initialBalance, "should have loss");
        console.log("loss:", (initialBalance - finalBalance) / 1e18, "DAI");
    }

    function testMultiplePositions() public {
        uint256 positionSize = 500e18;
        uint256 leverage = 2;

        vm.startPrank(trader);

        // open positions
        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, 0, 0);
        trading.initiateMarketOrder(PAIR_INDEX, false, leverage, positionSize, 0, 0);

        IStorage.Trade memory trade1 = storageContract.getTrade(0);
        IStorage.Trade memory trade2 = storageContract.getTrade(1);

        assertEq(trade1.buy, true, "first should be long");
        assertEq(trade2.buy, false, "second should be short");

        // close both
        trading.closePosition(0);
        trading.closePosition(1);

        vm.stopPrank();

        IStorage.Trade memory closedTrade1 = storageContract.getTrade(0);
        IStorage.Trade memory closedTrade2 = storageContract.getTrade(1);

        assertEq(closedTrade1.trader, address(0), "first trade should be removed");
        assertEq(closedTrade2.trader, address(0), "second trade should be removed");
    }

    function testUnauthorizedClose() public {
        uint256 positionSize = 1000e18;
        uint256 leverage = 2;

        // trader1 open position
        vm.startPrank(trader);
        trading.initiateMarketOrder(PAIR_INDEX, true, leverage, positionSize, 0, 0);
        vm.stopPrank();

        // trader2 try to close trader 1 position
        address trader2 = address(2);
        vm.startPrank(trader2);
        vm.expectRevert("Not the trader");
        trading.closePosition(0);
        vm.stopPrank();
    }
}
