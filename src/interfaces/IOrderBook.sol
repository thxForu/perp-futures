// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IOrderBook {
    enum OrderType {
        Market,
        Limit,
        StopLimit
    }
    enum OrderStatus {
        Active,
        Filled,
        Cancelled,
        Expired
    }
    enum TriggerType {
        None,
        StopLoss,
        TakeProfit
    }

    struct Order {
        address trader;
        uint256 pairIndex;
        bool buy;
        uint256 price;
        uint256 size;
        uint256 leverage;
        uint256 timestamp;
        uint256 expiry;
        OrderType orderType;
        OrderStatus status;
        TriggerType triggerType;
        uint256 triggerPrice;
        uint256 filledAmount;
        uint256 remainingAmount;
    }

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        uint256 price,
        uint256 size,
        bool buy,
        OrderType orderType,
        uint256 leverage,
        uint256 expiry
    );

    event OrderUpdated(uint256 indexed orderId, uint256 newPrice, uint256 newSize);

    event OrderFilled(uint256 indexed orderId, uint256 fillPrice, uint256 fillAmount, uint256 remainingAmount);

    event OrderCancelled(uint256 indexed orderId, string reason);

    event OrderExpired(uint256 indexed orderId);

    function createLimitOrder(
        uint256 pairIndex,
        bool buy,
        uint256 price,
        uint256 size,
        uint256 leverage,
        uint256 expiry
    ) external returns (uint256);

    function createStopLimitOrder(
        uint256 pairIndex,
        bool buy,
        uint256 triggerPrice,
        uint256 limitPrice,
        uint256 size,
        uint256 leverage,
        uint256 expiry
    ) external returns (uint256);

    function updateOrder(uint256 orderId, uint256 newPrice, uint256 newSize) external;

    function cancelOrder(uint256 orderId) external;

    function executeOrder(uint256 orderId) external returns (bool);

    function getOrder(uint256 orderId) external view returns (Order memory);

    function getActiveOrders(address trader) external view returns (uint256[] memory);

    function checkOrderExecutable(uint256 orderId) external view returns (bool);
}
