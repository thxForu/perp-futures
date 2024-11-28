// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IStorage.sol";

// TODO: is Ownable
contract Storage is IStorage {
    mapping(uint256 => Trade) private trades;
    mapping(address => uint256[]) private userTrades;
    address public tradingContract;

    event PositionOpened(address indexed trader, uint256 size, bool isLong, uint256 leverage);

    modifier onlyTrading() {
        require(msg.sender == tradingContract, "Only trading contract");
        _;
    }

    function setTradingContract(address _tradingContract) public {
        // onlyOwner
        tradingContract = _tradingContract;
    }

    function setTrade(uint256 tradeId, Trade memory trade) external override onlyTrading {
        require(trade.trader != address(0), "Invalid trader");
        require(trade.leverage >= 2, "Min leverage is 2x");

        trades[tradeId] = trade;
        userTrades[trade.trader].push(tradeId);

        emit PositionOpened(trade.trader, trade.positionSizeDai, trade.buy, trade.leverage);
    }

    function removeTrade(uint256 tradeId) external onlyTrading {
        address trader = trades[tradeId].trader;
        require(trader != address(0), "Trade not found");

        // TODO: remove loop. used just for dev testing.
        uint256[] storage userTradeList = userTrades[trader];
        for (uint256 i = 0; i < userTradeList.length; i++) {
            if (userTradeList[i] == tradeId) {
                // move last element to removed trade.
                userTradeList[i] = userTradeList[userTradeList.length - 1];
                userTradeList.pop();
                break;
            }
        }

        delete trades[tradeId];
    }

    function getTrade(uint256 tradeId) external view override returns (Trade memory) {
        return trades[tradeId];
    }

    function getUserTrades(address user) external view override returns (uint256[] memory) {
        return userTrades[user];
    }
}
