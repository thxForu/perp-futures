// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IStorage.sol";
import "./interfaces/ITrading.sol";
import "./interfaces/IOrderBook.sol";

contract Trading is ITrading, ReentrancyGuard, Pausable, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IERC20 public immutable dai;
    uint256 public currentTradeId;
    IStorage public immutable storageContract;
    IOrderBook public orderBook;
    address public liquidatorContract;

    uint256 private constant PRECISION = 10000;
    uint256 public tradingFee = 10; // 0.1%

    mapping(uint256 => AggregatorV3Interface) public priceFeeds;

    constructor(address _storage, address _dai) {
        require(_storage != address(0), "Invalid storage");
        require(_dai != address(0), "Invalid DAI");
        storageContract = IStorage(_storage);
        dai = IERC20(_dai);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
    }

    modifier onlyLiquidator() {
        require(msg.sender == liquidatorContract, "Only liquidator");
        _;
    }

    function initiateMarketOrder(
        uint256 _pairIndex,
        bool _buy,
        uint256 _leverage,
        uint256 _positionSizeDai,
        uint256 _tpPrice,
        uint256 _slPrice
    ) external override nonReentrant whenNotPaused returns (uint256 tradeId) {
        require(_leverage >= 2 && _leverage <= 150, "Invalid leverage");
        require(_positionSizeDai > 0, "Invalid position size");

        uint256 currentPrice = getCurrentPrice(_pairIndex);
        require(currentPrice > 0, "Invalid price");

        // Calculate and collect fee
        uint256 fee = (_positionSizeDai * tradingFee) / PRECISION;
        require(dai.transferFrom(msg.sender, address(this), _positionSizeDai + fee), "DAI transfer failed");

        // Store trade
        tradeId = currentTradeId++;

        storageContract.setTrade(
            tradeId,
            IStorage.Trade({
                openPrice: currentPrice,
                leverage: _leverage,
                initialPosToken: _positionSizeDai,
                positionSizeDai: _positionSizeDai,
                openFee: fee,
                tpPrice: _tpPrice,
                slPrice: _slPrice,
                orderType: 0,
                timestamp: block.timestamp,
                trader: msg.sender,
                buy: _buy
            })
        );

        emit MarketOrderInitiated(msg.sender, _pairIndex, _buy, _leverage, currentPrice, _positionSizeDai);

        return tradeId;
    }

    function closePosition(uint256 _tradeId) external override nonReentrant whenNotPaused {
        IStorage.Trade memory trade = storageContract.getTrade(_tradeId);
        require(trade.trader == msg.sender, "Not the trader");
        require(trade.positionSizeDai > 0, "Position not found");

        uint256 currentPrice = getCurrentPrice(0);
        require(currentPrice > 0, "Invalid price");

        int256 pnl = calculatePnL(trade, currentPrice);

        // Calculate amount to return to trader
        uint256 amountToReturn;
        if (pnl >= 0) {
            amountToReturn = trade.positionSizeDai + uint256(pnl);
        } else {
            amountToReturn = trade.positionSizeDai > uint256(-pnl) ? trade.positionSizeDai - uint256(-pnl) : 0;
        }

        // Remove trade before transfer to prevent reentrancy
        storageContract.removeTrade(_tradeId);

        // Transfer funds back to trader
        require(dai.transfer(trade.trader, amountToReturn), "Transfer failed");

        emit PositionClosed(trade.trader, _tradeId, currentPrice, pnl);
    }

    function liquidatePosition(uint256 tradeId, address liquidator, uint256 reward)
        external
        override
        nonReentrant
        whenNotPaused
        onlyLiquidator
    {
        IStorage.Trade memory trade = storageContract.getTrade(tradeId);
        require(trade.trader != address(0), "Trade not found");

        uint256 currentPrice = getCurrentPrice(0);
        int256 pnl = calculatePnL(trade, currentPrice);

        uint256 remainingBalance = trade.positionSizeDai;
        if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            remainingBalance = remainingBalance > loss ? remainingBalance - loss : 0;
        }

        require(dai.balanceOf(address(this)) >= reward, "Insufficient contract balance");

        // Remove trade before transfers
        storageContract.removeTrade(tradeId);

        // Transfer reward to liquidator
        if (reward > 0) {
            require(dai.transfer(liquidator, reward), "Reward transfer failed");
        }

        // Return remaining balance to trader
        if (remainingBalance > reward && remainingBalance - reward > 0) {
            require(dai.transfer(trade.trader, remainingBalance - reward), "Return transfer failed");
        }

        emit PositionLiquidated(tradeId, trade.trader, liquidator, currentPrice, reward);
    }

    function calculatePnL(IStorage.Trade memory _trade, uint256 _currentPrice) public pure override returns (int256) {
        uint256 openPrice = _trade.openPrice;
        uint256 size = _trade.positionSizeDai * _trade.leverage;
        bool isLong = _trade.buy;

        if (isLong) {
            if (_currentPrice > openPrice) {
                return int256((size * (_currentPrice - openPrice)) / openPrice);
            } else {
                return -int256((size * (openPrice - _currentPrice)) / openPrice);
            }
        } else {
            if (_currentPrice < openPrice) {
                return int256((size * (openPrice - _currentPrice)) / openPrice);
            } else {
                return -int256((size * (_currentPrice - openPrice)) / openPrice);
            }
        }
    }

    function getCurrentPrice(uint256 _pairIndex) public view override returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[_pairIndex];
        require(address(priceFeed) != address(0), "Price feed not found");

        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");

        return uint256(price);
    }

    // Admin functions
    function setLiquidator(address _liquidator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_liquidator != address(0), "Invalid liquidator");
        liquidatorContract = _liquidator;
    }

    function setOrderBook(address _orderBook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_orderBook != address(0), "Invalid order book");
        orderBook = IOrderBook(_orderBook);
        _grantRole(EXECUTOR_ROLE, _orderBook);
    }

    function setPriceFeed(uint256 _pairIndex, address _feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feed != address(0), "Invalid feed address");
        priceFeeds[_pairIndex] = AggregatorV3Interface(_feed);
    }

    function setTradingFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fee < PRECISION, "Fee too high");
        tradingFee = _fee;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
