// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ILiquidator.sol";
import "./interfaces/IStorage.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/ITradingPool.sol";

contract Liquidator is ILiquidator, ReentrancyGuard, Pausable, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 private constant PRECISION = 10000;

    IStorage public immutable storageContract;
    ITrading public immutable tradingContract;
    ITradingPool public immutable tradingPool;
    LiquidationThresholds public thresholds;

    constructor(address _storage, address _trading, address _tradingPool, LiquidationThresholds memory _thresholds) {
        require(_storage != address(0), "Invalid storage");
        require(_trading != address(0), "Invalid trading");
        require(_tradingPool != address(0), "Invalid trading pool");
        require(_thresholds.maintenanceMargin > 0, "Invalid maintenance margin");
        require(_thresholds.liquidationFee > 0, "Invalid liquidation fee");

        storageContract = IStorage(_storage);
        tradingContract = ITrading(_trading);
        tradingPool = ITradingPool(_tradingPool);
        thresholds = _thresholds;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function checkLiquidation(uint256 tradeId) public view override returns (bool) {
        if (paused()) return false;

        IStorage.Trade memory trade = storageContract.getTrade(tradeId);
        if (trade.trader == address(0)) return false;

        uint256 currentPrice = tradingContract.getCurrentPrice(0); // TODO: add pair index to Trade
        require(currentPrice > 0, "Invalid price");

        int256 unrealizedPnL = tradingContract.calculatePnL(trade, currentPrice);

        uint256 positionValue;
        if (unrealizedPnL >= 0) {
            positionValue = trade.positionSizeDai + uint256(unrealizedPnL);
        } else {
            positionValue =
                trade.positionSizeDai > uint256(-unrealizedPnL) ? trade.positionSizeDai - uint256(-unrealizedPnL) : 0;
        }

        uint256 requiredMargin = (trade.positionSizeDai * thresholds.maintenanceMargin) / PRECISION;

        return positionValue < requiredMargin;
    }

    function liquidate(uint256 tradeId) external override nonReentrant whenNotPaused returns (uint256 reward) {
        require(checkLiquidation(tradeId), "Position cannot be liquidated");

        IStorage.Trade memory trade = storageContract.getTrade(tradeId);
        require(trade.trader != address(0), "Trade not found");

        // calculate reward for liquidator
        reward = calculateLiquidationReward(trade.positionSizeDai);

        tradingPool.releaseMargin(trade.trader, trade.positionSizeDai + trade.openFee);

        // pay liquidator reward through trading pool
        tradingPool.transferReward(msg.sender, reward);

        storageContract.removeTrade(tradeId);

        emit PositionLiquidated(tradeId, trade.trader, msg.sender, reward);
        return reward;
    }

    function calculateLiquidationReward(uint256 positionSize) public view returns (uint256) {
        uint256 reward = (positionSize * thresholds.liquidationFee) / PRECISION;

        uint256 maxDiscount = (positionSize * thresholds.maxLiquidationDiscount) / PRECISION;
        return reward > maxDiscount ? maxDiscount : reward;
    }

    function setThresholds(LiquidationThresholds memory _thresholds) external override onlyRole(ADMIN_ROLE) {
        require(_thresholds.maintenanceMargin > 0, "Invalid maintenance margin");
        require(_thresholds.liquidationFee > 0, "Invalid liquidation fee");
        require(_thresholds.maxLiquidationDiscount > 0, "Invalid max discount");

        thresholds = _thresholds;
        emit ThresholdsUpdated(
            _thresholds.maintenanceMargin, _thresholds.liquidationFee, _thresholds.maxLiquidationDiscount
        );
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
