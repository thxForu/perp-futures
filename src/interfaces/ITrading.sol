// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./IStorage.sol";

interface ITrading {
    event MarketOrderInitiated(
        address indexed trader,
        uint256 indexed pairIndex,
        bool indexed buy,
        uint256 leverage,
        uint256 price,
        uint256 positionSizeDai
    );

    event PositionClosed(address indexed trader, uint256 indexed tradeId, uint256 price, int256 pnl);

    event PositionLiquidated(
        uint256 indexed tradeId, address indexed trader, address indexed liquidator, uint256 price, uint256 reward
    );

    function initiateMarketOrder(
        uint256 pairIndex,
        bool buy,
        uint256 leverage,
        uint256 positionSizeDai,
        uint256 tpPrice,
        uint256 slPrice
    ) external returns (uint256 tradeId);

    function closePosition(uint256 tradeId) external;

    function liquidatePosition(uint256 tradeId, address liquidator, uint256 reward) external;

    function calculatePnL(IStorage.Trade memory trade, uint256 currentPrice) external pure returns (int256);

    function getCurrentPrice(uint256 pairIndex) external view returns (uint256);
}
