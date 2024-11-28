// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IStorage {
    struct Trade {
        uint256 openPrice;
        uint256 leverage;
        uint256 initialPosToken;
        uint256 positionSizeDai;
        uint256 openFee;
        uint256 tpPrice;
        uint256 slPrice;
        uint256 orderType;
        uint256 timestamp;
        address trader;
        bool buy;
    }

    function setTrade(uint256 tradeId, Trade memory trade) external;
    function getTrade(uint256 tradeId) external view returns (Trade memory);
    function getUserTrades(address user) external view returns (uint256[] memory);
    function removeTrade(uint256 tradeId) external;
}
