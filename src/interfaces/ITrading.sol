// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./IStorage.sol";

interface ITrading {
    function getCurrentPrice(uint256 pairIndex) external view returns (uint256);
    function calculatePnL(IStorage.Trade memory trade, uint256 currentPrice) external pure returns (int256);

    function liquidatePosition(uint256 tradeId, address liquidator, uint256 reward) external;
}
