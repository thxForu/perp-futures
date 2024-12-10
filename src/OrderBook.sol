// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IStorage.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/ITradingPool.sol";

contract OrderBook is IOrderBook, Pausable, AccessControl, ReentrancyGuard {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userOrders;
    mapping(uint256 => uint256) public orderIndexes;

    uint256 public currentOrderId;
    OrderLimits public limits;

    IStorage public immutable storageContract;
    ITrading public immutable tradingContract;
    ITradingPool public immutable tradingPool;

    constructor(address _storage, address _trading, address _tradingPool, OrderLimits memory _limits) {
        require(_storage != address(0), "Invalid storage");
        require(_trading != address(0), "Invalid trading");
        require(_limits.minSize > 0, "Invalid min size");
        require(_limits.maxSize > _limits.minSize, "Invalid max size");
        require(_limits.minLeverage > 0, "Invalid min leverage");
        require(_limits.maxLeverage > _limits.minLeverage, "Invalid max leverage");
        require(_limits.maxExpiry > 0, "Invalid max expiry");

        storageContract = IStorage(_storage);
        tradingContract = ITrading(_trading);
        tradingPool = ITradingPool(_tradingPool);
        limits = _limits;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
    }

    function _validateOrderParams(uint256 size, uint256 leverage, uint256 expiry) internal view {
        require(size >= limits.minSize && size <= limits.maxSize, "Invalid size");
        require(leverage >= limits.minLeverage && leverage <= limits.maxLeverage, "Invalid leverage");
        require(expiry > block.timestamp && expiry <= block.timestamp + limits.maxExpiry, "Invalid expiry");
    }

    function _createOrder(
        uint256 pairIndex,
        bool buy,
        uint256 price,
        uint256 size,
        uint256 leverage,
        uint256 expiry,
        OrderType orderType,
        uint256 triggerPrice
    ) internal returns (uint256) {
        uint256 requiredMargin = calculateRequiredMargin(size, leverage);

        require(tradingPool.hasEnoughAvailableMargin(msg.sender, requiredMargin), "Insufficient margin");

        uint256 orderId = currentOrderId++;

        orders[orderId] = Order({
            trader: msg.sender,
            pairIndex: pairIndex,
            buy: buy,
            price: price,
            size: size,
            leverage: leverage,
            timestamp: block.timestamp,
            expiry: expiry,
            orderType: orderType,
            status: OrderStatus.Active,
            triggerType: TriggerType.None,
            triggerPrice: triggerPrice,
            filledAmount: 0,
            remainingAmount: size
        });

        userOrders[msg.sender].push(orderId);
        orderIndexes[orderId] = userOrders[msg.sender].length - 1;

        return orderId;
    }

    function calculateRequiredMargin(uint256 size, uint256 leverage) internal view returns (uint256) {
        uint256 baseMargin = size / leverage;

        uint256 fee = (size * tradingContract.tradingFee()) / 10000;

        return baseMargin + fee;
    }

    function createLimitOrder(
        uint256 pairIndex,
        bool buy,
        uint256 price,
        uint256 size,
        uint256 leverage,
        uint256 expiry
    ) external override nonReentrant whenNotPaused returns (uint256) {
        require(price > 0, "Invalid price");
        _validateOrderParams(size, leverage, expiry);

        uint256 orderId = _createOrder(pairIndex, buy, price, size, leverage, expiry, OrderType.Limit, 0);

        emit OrderCreated(orderId, msg.sender, price, size, buy, OrderType.Limit, leverage, expiry);

        return orderId;
    }

    function createStopLimitOrder(
        uint256 pairIndex,
        bool buy,
        uint256 triggerPrice,
        uint256 limitPrice,
        uint256 size,
        uint256 leverage,
        uint256 expiry
    ) external override nonReentrant whenNotPaused returns (uint256) {
        require(triggerPrice > 0 && limitPrice > 0, "Invalid prices");
        _validateOrderParams(size, leverage, expiry);

        if (buy) {
            require(triggerPrice >= limitPrice, "Invalid trigger price for buy");
        } else {
            require(triggerPrice <= limitPrice, "Invalid trigger price for sell");
        }

        uint256 orderId =
            _createOrder(pairIndex, buy, limitPrice, size, leverage, expiry, OrderType.StopLimit, triggerPrice);

        emit OrderCreated(orderId, msg.sender, limitPrice, size, buy, OrderType.StopLimit, leverage, expiry);

        return orderId;
    }

    function _validateExecution(Order memory order) internal view returns (bool) {
        if (order.status != OrderStatus.Active || block.timestamp >= order.expiry) {
            return false;
        }

        uint256 requiredMargin = calculateRequiredMargin(order.size, order.leverage);
        if (!tradingPool.hasEnoughAvailableMargin(order.trader, requiredMargin)) {
            return false;
        }

        uint256 currentPrice = tradingContract.getCurrentPrice(order.pairIndex);

        if (order.orderType == OrderType.StopLimit) {
            bool triggerMet = order.buy ? currentPrice >= order.triggerPrice : currentPrice <= order.triggerPrice;

            if (!triggerMet) {
                return false;
            }
        }

        return order.buy ? currentPrice <= order.price : currentPrice >= order.price;
    }

    function executeOrder(uint256 orderId) external override nonReentrant whenNotPaused returns (bool) {
        require(hasRole(EXECUTOR_ROLE, msg.sender), "Not executor");

        Order storage order = orders[orderId];
        require(_validateExecution(order), "Order not executable");

        uint256 tradeId =
            tradingContract.initiateMarketOrder(order.pairIndex, order.buy, order.leverage, order.size, 0, 0);

        order.status = OrderStatus.Filled;
        order.filledAmount = order.size;
        order.remainingAmount = 0;

        _removeOrder(orderId);

        emit OrderFilled(orderId, tradingContract.getCurrentPrice(order.pairIndex), order.size, 0);

        return true;
    }

    function updateOrder(uint256 orderId, uint256 newPrice, uint256 newSize)
        external
        override
        nonReentrant
        whenNotPaused
    {
        Order storage order = orders[orderId];
        require(order.trader == msg.sender, "Not order owner");
        require(order.status == OrderStatus.Active, "Order not active");
        require(newPrice > 0, "Invalid price");
        require(newSize >= limits.minSize && newSize <= limits.maxSize, "Invalid size");

        order.price = newPrice;
        order.size = newSize;
        order.remainingAmount = newSize;

        emit OrderUpdated(orderId, newPrice, newSize);
    }

    function cancelOrder(uint256 orderId) external override nonReentrant {
        Order storage order = orders[orderId];
        require(order.trader == msg.sender, "Not order owner");
        require(order.status == OrderStatus.Active, "Order not active");

        order.status = OrderStatus.Cancelled;
        _removeOrder(orderId);

        emit OrderCancelled(orderId, "User cancelled");
    }

    function checkOrderExecutable(uint256 orderId) public view override returns (bool) {
        Order memory order = orders[orderId];
        return _validateExecution(order);
    }

    function getOrder(uint256 orderId) external view override returns (Order memory) {
        return orders[orderId];
    }

    function getActiveOrders(address trader) external view override returns (uint256[] memory) {
        uint256[] memory userOrderList = userOrders[trader];
        uint256[] memory activeOrders = new uint256[](userOrderList.length);
        uint256 count = 0;

        for (uint256 i = 0; i < userOrderList.length; i++) {
            uint256 orderId = userOrderList[i];
            if (orders[orderId].status == OrderStatus.Active) {
                activeOrders[count] = orderId;
                count++;
            }
        }

        assembly {
            mstore(activeOrders, count)
        }

        return activeOrders;
    }

    function _removeOrder(uint256 orderId) internal {
        Order storage order = orders[orderId];
        uint256 index = orderIndexes[orderId];
        uint256[] storage userOrderList = userOrders[order.trader];
        uint256 lastOrderId = userOrderList[userOrderList.length - 1];

        if (orderId != lastOrderId) {
            userOrderList[index] = lastOrderId;
            orderIndexes[lastOrderId] = index;
        }

        userOrderList.pop();
        delete orderIndexes[orderId];
    }

    // Admin functions
    function setLimits(OrderLimits memory _limits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_limits.minSize > 0, "Invalid min size");
        require(_limits.maxSize > _limits.minSize, "Invalid max size");
        require(_limits.minLeverage > 0, "Invalid min leverage");
        require(_limits.maxLeverage > _limits.minLeverage, "Invalid max leverage");
        require(_limits.maxExpiry > 0, "Invalid max expiry");

        limits = _limits;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
