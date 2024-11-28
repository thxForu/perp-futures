// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IStorage.sol";

contract Trading is ReentrancyGuard {
    IERC20 public immutable dai;

    uint256 public currentTradeId;
    IStorage public immutable storageContract;
    mapping(uint256 => AggregatorV3Interface) public priceFeeds;

    event MarketOrderInitiated(
        address indexed trader,
        uint256 indexed pairIndex,
        bool indexed buy,
        uint256 leverage,
        uint256 price,
        uint256 positionSizeDai
    );

    constructor(address _storage, address _dai) {
        require(_storage != address(0), "Invalid storage");
        require(_dai != address(0), "Invalid DAI");
        storageContract = IStorage(_storage);
        dai = IERC20(_dai);
    }

    function initiateMarketOrder(
        uint256 _pairIndex,
        bool _buy,
        uint256 _leverage,
        uint256 _positionSizeDai,
        uint256 _tpPrice,
        uint256 _slPrice
    ) external nonReentrant {
        uint256 currentPrice = getCurrentPrice(_pairIndex);
        require(currentPrice > 0, "Invalid price");

        uint256 fee = _positionSizeDai / 10000;

        require(dai.transferFrom(msg.sender, address(this), _positionSizeDai), "DAI transfer failed");

        storageContract.setTrade(
            currentTradeId,
            IStorage.Trade({
                openPrice: currentPrice,
                leverage: _leverage,
                initialPosToken: _positionSizeDai,
                positionSizeDai: _positionSizeDai,
                openFee: fee,
                tpPrice: _tpPrice,
                slPrice: _slPrice,
                orderType: 0, // TODO: add order type
                timestamp: block.timestamp,
                trader: msg.sender,
                buy: _buy
            })
        );

        emit MarketOrderInitiated(msg.sender, _pairIndex, _buy, _leverage, currentPrice, _positionSizeDai);

        currentTradeId++;
    }

    event PositionClosed(address indexed trader, uint256 indexed tradeId, uint256 price, int256 pnl);

    function closePosition(uint256 _tradeId) external nonReentrant {
        IStorage.Trade memory trade = storageContract.getTrade(_tradeId);
        require(trade.trader == msg.sender, "Not the trader");
        require(trade.positionSizeDai > 0, "Position not found");

        uint256 currentPrice = getCurrentPrice(0);
        require(currentPrice > 0, "Invalid price");

        int256 pnl = calculatePnL(trade, currentPrice);

        uint256 amountToReturn;
        if (pnl >= 0) {
            amountToReturn = trade.positionSizeDai + uint256(pnl);
        } else {
            amountToReturn = trade.positionSizeDai - uint256(-pnl);
        }

        storageContract.removeTrade(_tradeId);

        require(dai.transfer(trade.trader, amountToReturn), "Transfer failed");

        emit PositionClosed(trade.trader, _tradeId, currentPrice, pnl);
    }

    function calculatePnL(IStorage.Trade memory _trade, uint256 _currentPrice) public pure returns (int256) {
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

    function getCurrentPrice(uint256 _pairIndex) public view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[_pairIndex];
        require(address(priceFeed) != address(0), "Price feed not found");

        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");

        return uint256(price);
    }

    // for testing
    function setPriceFeed(uint256 _pairIndex, address _feed) external {
        require(_feed != address(0), "Invalid feed address");
        priceFeeds[_pairIndex] = AggregatorV3Interface(_feed);
    }
}
