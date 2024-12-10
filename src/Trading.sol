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
import "./interfaces/ITradingPool.sol";

contract Trading is ITrading, ReentrancyGuard, Pausable, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    uint256 public currentTradeId;
    ITradingPool public immutable tradingPool;
    IStorage public immutable storageContract;
    IOrderBook public orderBook;
    address public liquidatorContract;

    uint256 private constant PRECISION = 10000;
    uint256 public tradingFee = 10; // 0.1%

    mapping(uint256 => AggregatorV3Interface) public priceFeeds;

    constructor(address _storage, address _tradingPool) {
        require(_storage != address(0), "Invalid storage");
        require(_tradingPool != address(0), "Invalid trading pool");

        storageContract = IStorage(_storage);
        tradingPool = ITradingPool(_tradingPool);

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

        uint256 baseMargin = _positionSizeDai / _leverage;
        uint256 fee = (_positionSizeDai * tradingFee) / PRECISION;
        uint256 requiredMargin = baseMargin + fee;

        address trader;
        if (msg.sender == address(orderBook)) {
            trader = tx.origin;
        } else {
            trader = msg.sender;
        }

        require(tradingPool.hasEnoughAvailableMargin(trader, requiredMargin), "Insufficient margin");
        tradingPool.lockMargin(trader, requiredMargin);

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
                trader: trader,
                buy: _buy
            })
        );

        emit MarketOrderInitiated(trader, _pairIndex, _buy, _leverage, currentPrice, _positionSizeDai);

        return tradeId;
    }

    function closePosition(uint256 _tradeId) external override nonReentrant whenNotPaused {
        IStorage.Trade memory trade = storageContract.getTrade(_tradeId);
        require(trade.trader == msg.sender, "Not the trader");
        require(trade.positionSizeDai > 0, "Position not found");

        uint256 currentPrice = getCurrentPrice(0);
        require(currentPrice > 0, "Invalid price");

        int256 pnl = calculatePnL(trade, currentPrice);

        tradingPool.releaseMargin(trade.trader, trade.positionSizeDai + trade.openFee);

        if (pnl > 0) {
            tradingPool.addProfit(trade.trader, uint256(pnl));
        }

        storageContract.removeTrade(_tradeId);

        emit PositionClosed(trade.trader, _tradeId, currentPrice, pnl);
    }

    function liquidatePosition(uint256 tradeId, address liquidator, uint256 reward)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(msg.sender == liquidatorContract, "Only liquidator");
        IStorage.Trade memory trade = storageContract.getTrade(tradeId);
        require(trade.trader != address(0), "Trade not found");

        uint256 currentPrice = getCurrentPrice(0);
        int256 pnl = calculatePnL(trade, currentPrice);

        tradingPool.releaseMargin(trade.trader, trade.positionSizeDai + trade.openFee);

        if (pnl > 0) {
            tradingPool.addProfit(trade.trader, uint256(pnl));
        }

        storageContract.removeTrade(tradeId);

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
