// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "../src/OrderBook.sol";
import "../src/Storage.sol";
import "../src/Trading.sol";
import "./mocks/MockDai.sol";
import "./mocks/MockPriceFeed.sol";

contract OrderBookTest is Test {
    OrderBook public orderBook;
    Trading public trading;
    Storage public storageContract;
    MockPriceFeed public priceFeed;
    MockDai public dai;

    address public trader = address(1);
    address public executor = address(2);
    uint256 public constant INITIAL_DAI = 10000e18;
    uint256 public constant INITIAL_PRICE = 2000e8;
    uint256 public constant PAIR_INDEX = 0;

    OrderBook.OrderLimits limits = OrderBook.OrderLimits({
        minSize: 100e18, // 100 DAI
        maxSize: 10000e18, // 10,000 DAI
        minLeverage: 2, // 2x
        maxLeverage: 150, // 150x
        maxExpiry: 7 days // 1 week
    });

    function setUp() public {
        dai = new MockDai();
        priceFeed = new MockPriceFeed(int256(INITIAL_PRICE));

        storageContract = new Storage();
        trading = new Trading(address(storageContract), address(dai));
        orderBook = new OrderBook(address(storageContract), address(trading), limits);

        storageContract.grantTradingRole(address(trading));
        trading.setOrderBook(address(orderBook));
        orderBook.grantRole(orderBook.EXECUTOR_ROLE(), executor);

        trading.setPriceFeed(PAIR_INDEX, address(priceFeed));

        dai.mint(trader, INITIAL_DAI);
        dai.mint(address(trading), INITIAL_DAI * 2);

        vm.startPrank(trader);
        dai.approve(address(trading), type(uint256).max);
        vm.stopPrank();
    }

    function testInitialSetup() public {
        assertEq(address(orderBook.storageContract()), address(storageContract));
        assertEq(address(orderBook.tradingContract()), address(trading));

        (uint256 minSize, uint256 maxSize, uint256 minLev, uint256 maxLev, uint256 maxExp) = orderBook.limits();
        assertEq(minSize, limits.minSize);
        assertEq(maxSize, limits.maxSize);
        assertEq(minLev, limits.minLeverage);
        assertEq(maxLev, limits.maxLeverage);
        assertEq(maxExp, limits.maxExpiry);

        assertTrue(orderBook.hasRole(orderBook.EXECUTOR_ROLE(), executor));
    }

    function testCreateLimitOrder() public {
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE * 95 / 100; // 5% below market
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId = orderBook.createLimitOrder(
            PAIR_INDEX,
            true, // buy
            price,
            size,
            leverage,
            expiry
        );
        vm.stopPrank();

        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(order.trader, trader);
        assertEq(order.pairIndex, PAIR_INDEX);
        assertTrue(order.buy);
        assertEq(order.price, price);
        assertEq(order.size, size);
        assertEq(order.leverage, leverage);
        assertEq(order.expiry, expiry);
        assertEq(uint256(order.orderType), uint256(IOrderBook.OrderType.Limit));
        assertEq(uint256(order.status), uint256(IOrderBook.OrderStatus.Active));
    }

    function testCannotCreateInvalidLimitOrder() public {
        uint256 size = 50e18; // below min size
        uint256 price = INITIAL_PRICE;
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        vm.expectRevert("Invalid size");
        orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);
        vm.stopPrank();

        // test max size
        size = 11000e18; // above max size
        vm.startPrank(trader);
        vm.expectRevert("Invalid size");
        orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);
        vm.stopPrank();

        // test leverage limits
        size = 1000e18;
        leverage = 1; // below min leverage
        vm.startPrank(trader);
        vm.expectRevert("Invalid leverage");
        orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);
        vm.stopPrank();

        // test expiry
        leverage = 10;
        expiry = block.timestamp - 1; // expired
        vm.startPrank(trader);
        vm.expectRevert("Invalid expiry");
        orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);
        vm.stopPrank();
    }

    // TODO: 
    // function testCreateStopLimitOrder() public {
    //     uint256 size = 1000e18;
    //     uint256 triggerPrice = INITIAL_PRICE * 105 / 100; // 5% above market
    //     uint256 limitPrice = INITIAL_PRICE * 106 / 100; // 6% above market
    //     uint256 leverage = 10;
    //     uint256 expiry = block.timestamp + 1 days;

    //     vm.startPrank(trader);
    //     uint256 orderId = orderBook.createStopLimitOrder(
    //         PAIR_INDEX,
    //         false, // sell
    //         triggerPrice,
    //         limitPrice,
    //         size,
    //         leverage,
    //         expiry
    //     );
    //     vm.stopPrank();

    //     IOrderBook.Order memory order = orderBook.getOrder(orderId);
    //     assertEq(order.trader, trader);
    //     assertEq(order.price, limitPrice);
    //     assertEq(order.triggerPrice, triggerPrice);
    //     assertEq(uint256(order.orderType), uint256(IOrderBook.OrderType.StopLimit));
    // }

    function testExecuteOrder() public {
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE * 105 / 100; // 5% above market
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId = orderBook.createLimitOrder(
            PAIR_INDEX,
            false, // sell
            price,
            size,
            leverage,
            expiry
        );
        vm.stopPrank();

        // Increase price to trigger order
        priceFeed.setPrice(int256(price));

        dai.mint(trader, size / 10); // add 10% for fees

        vm.startPrank(executor);
        bool success = orderBook.executeOrder(orderId);
        vm.stopPrank();

        assertTrue(success, "Order should be executed");

        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(IOrderBook.OrderStatus.Filled));
    }

    function testCancelOrder() public {
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE;
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId = orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);

        orderBook.cancelOrder(orderId);
        vm.stopPrank();

        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(IOrderBook.OrderStatus.Cancelled));
    }

    function testCannotCancelOtherTraderOrder() public {
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE;
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId = orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);
        vm.stopPrank();

        address otherTrader = address(3);
        vm.startPrank(otherTrader);
        vm.expectRevert("Not order owner");
        orderBook.cancelOrder(orderId);
        vm.stopPrank();
    }

    function testUpdateOrder() public {
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE;
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId = orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);

        uint256 newPrice = INITIAL_PRICE * 95 / 100;
        uint256 newSize = 1500e18;

        orderBook.updateOrder(orderId, newPrice, newSize);
        vm.stopPrank();

        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(order.price, newPrice);
        assertEq(order.size, newSize);
        assertEq(order.remainingAmount, newSize);
    }

    function testGetActiveOrders() public {
        // create multiple orders
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE;
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId1 = orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);
        uint256 orderId2 = orderBook.createLimitOrder(PAIR_INDEX, false, price, size, leverage, expiry);
        uint256 orderId3 = orderBook.createLimitOrder(PAIR_INDEX, true, price, size, leverage, expiry);

        // cancel one order
        orderBook.cancelOrder(orderId2);
        vm.stopPrank();

        uint256[] memory activeOrders = orderBook.getActiveOrders(trader);
        assertEq(activeOrders.length, 2);
        assertEq(activeOrders[0], orderId1);
        assertEq(activeOrders[1], orderId3);
    }

    function testCheckOrderExecutable() public {
        uint256 size = 1000e18;
        uint256 price = INITIAL_PRICE * 95 / 100; // 5% below market
        uint256 leverage = 10;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(trader);
        uint256 orderId = orderBook.createLimitOrder(
            PAIR_INDEX,
            true, // buy
            price,
            size,
            leverage,
            expiry
        );
        vm.stopPrank();

        // initially not executable (price too high)
        assertFalse(orderBook.checkOrderExecutable(orderId));

        // lower price to make executable
        priceFeed.setPrice(int256(price));
        assertTrue(orderBook.checkOrderExecutable(orderId));
    }
}
