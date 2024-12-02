// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ILiquidator {
    struct LiquidationThresholds {
        uint256 maintenanceMargin; // 0.5% = 50
        uint256 liquidationFee; // 1% = 100
        uint256 maxLiquidationDiscount; // 2% = 200
    }

    function checkLiquidation(uint256 tradeId) external view returns (bool);
    function liquidate(uint256 tradeId) external returns (uint256 reward);

    event PositionLiquidated(uint256 indexed tradeId, address indexed trader, uint256 reward);

    function calculateLiquidationReward(uint256 positionSize) external view returns (uint256);

    function setThresholds(LiquidationThresholds calldata thresholds) external;

    event ThresholdsUpdated(uint256 maintenanceMargin, uint256 liquidationFee, uint256 maxLiquidationDiscount);

    event LiquidationAttemptFailed(uint256 indexed tradeId, string reason);
}
