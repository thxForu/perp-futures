// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ITradingPool {
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event MarginUsed(address indexed user, uint256 amount);
    event MarginReleased(address indexed user, uint256 amount);
    event ProfitAdded(address indexed user, uint256 amount);
    event RewardPaid(address indexed liquidator, uint256 amount);

    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getAvailableBalance(address user) external view returns (uint256);

    function getTotalBalance(address user) external view returns (uint256);

    function lockMargin(address user, uint256 amount) external;

    function releaseMargin(address user, uint256 amount) external;

    function hasEnoughAvailableMargin(address user, uint256 amount) external view returns (bool);

    function addProfit(address user, uint256 amount) external;

    function transferReward(address liquidator, uint256 amount) external;
}
