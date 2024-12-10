// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IStorage.sol";

contract Storage is IStorage, AccessControl {
    bytes32 public constant TRADING_ROLE = keccak256("TRADING_ROLE");

    mapping(uint256 => Trade) private trades;
    mapping(address => uint256[]) private userTrades;
    mapping(uint256 => TradeIndex) private tradeIndexes;
    uint256 public totalTrades;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyTrading() {
        require(hasRole(TRADING_ROLE, msg.sender), "Only trading contract");
        _;
    }

    function setTrade(uint256 tradeId, Trade memory trade) external override onlyTrading {
        require(trade.trader != address(0), "Invalid trader");
        require(trade.leverage >= 2, "Min leverage is 2x");
        require(trade.leverage <= 150, "Max leverage is 150x");
        require(!tradeIndexes[tradeId].exists, "Trade ID already exists");

        trades[tradeId] = trade;

        userTrades[trade.trader].push(tradeId);

        tradeIndexes[tradeId] = TradeIndex({arrayIndex: userTrades[trade.trader].length - 1, exists: true});

        totalTrades++;

        emit PositionOpened(trade.trader, tradeId, trade.positionSizeDai, trade.buy, trade.leverage);
    }

    function removeTrade(uint256 tradeId) external override onlyTrading {
        Trade memory trade = trades[tradeId];
        require(trade.trader != address(0), "Trade not found");

        TradeIndex memory index = tradeIndexes[tradeId];
        require(index.exists, "Trade index not found");

        uint256[] storage userTradeList = userTrades[trade.trader];
        uint256 lastTradeId = userTradeList[userTradeList.length - 1];

        if (tradeId != lastTradeId) {
            // move last element to the removed position
            userTradeList[index.arrayIndex] = lastTradeId;
            // udate index for the moved element
            tradeIndexes[lastTradeId].arrayIndex = index.arrayIndex;
        }

        userTradeList.pop();

        delete trades[tradeId];
        delete tradeIndexes[tradeId];

        emit PositionRemoved(trade.trader, tradeId);
    }

    function getTrade(uint256 tradeId) external view override returns (Trade memory) {
        return trades[tradeId];
    }

    function getUserTrades(address user) external view override returns (uint256[] memory) {
        return userTrades[user];
    }

    function grantTradingRole(address tradingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tradingContract != address(0), "Invalid trading contract");
        grantRole(TRADING_ROLE, tradingContract);
    }

    function revokeTradingRole(address tradingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tradingContract != address(0), "Invalid trading contract");
        revokeRole(TRADING_ROLE, tradingContract);
    }

    function getUserTradesCount(address user) external view returns (uint256) {
        return userTrades[user].length;
    }

    function getTradeExists(uint256 tradeId) external view returns (bool) {
        return tradeIndexes[tradeId].exists;
    }

    function getTradeIndex(uint256 tradeId) external view returns (uint256) {
        require(tradeIndexes[tradeId].exists, "Trade index not found");
        return tradeIndexes[tradeId].arrayIndex;
    }
}
