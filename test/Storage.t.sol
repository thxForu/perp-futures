// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "../src/Storage.sol";
import "./mocks/MockTradingContract.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract StorageTest is Test {
    Storage public storageContract;
    MockTradingContract public mockTrading;

    address public trader = address(1);

    function setUp() public {
        storageContract = new Storage();
        mockTrading = new MockTradingContract();

        storageContract.grantTradingRole(address(mockTrading));
    }

    function testCannotSetTradeUnauthorized() public {
        vm.startPrank(trader);
        vm.expectRevert("Only trading contract");
        storageContract.setTrade(
            0,
            IStorage.Trade({
                openPrice: 1000,
                leverage: 10,
                initialPosToken: 100,
                positionSizeDai: 1000,
                openFee: 10,
                tpPrice: 1100,
                slPrice: 900,
                orderType: 0,
                timestamp: block.timestamp,
                trader: trader,
                buy: true
            })
        );
        vm.stopPrank();
    }

    function testSetAndGetTrade() public {
        uint256 tradeId = 0;
        IStorage.Trade memory trade = IStorage.Trade({
            openPrice: 1000,
            leverage: 10,
            initialPosToken: 100,
            positionSizeDai: 1000,
            openFee: 10,
            tpPrice: 1100,
            slPrice: 900,
            orderType: 0,
            timestamp: block.timestamp,
            trader: trader,
            buy: true
        });

        vm.startPrank(address(mockTrading));
        storageContract.setTrade(tradeId, trade);

        IStorage.Trade memory retrievedTrade = storageContract.getTrade(tradeId);
        assertEq(retrievedTrade.openPrice, trade.openPrice);
        assertEq(retrievedTrade.leverage, trade.leverage);
        assertEq(retrievedTrade.trader, trade.trader);
        assertEq(retrievedTrade.buy, trade.buy);
        vm.stopPrank();

        uint256[] memory userTrades = storageContract.getUserTrades(trader);
        assertEq(userTrades.length, 1);
        assertEq(userTrades[0], tradeId);
    }

    function testRemoveTrade() public {
        uint256 tradeId = 0;
        IStorage.Trade memory trade = IStorage.Trade({
            openPrice: 1000,
            leverage: 10,
            initialPosToken: 100,
            positionSizeDai: 1000,
            openFee: 10,
            tpPrice: 1100,
            slPrice: 900,
            orderType: 0,
            timestamp: block.timestamp,
            trader: trader,
            buy: true
        });

        vm.startPrank(address(mockTrading));
        storageContract.setTrade(tradeId, trade);
        storageContract.removeTrade(tradeId);
        vm.stopPrank();

        IStorage.Trade memory emptyTrade = storageContract.getTrade(tradeId);
        assertEq(emptyTrade.trader, address(0));

        uint256[] memory userTrades = storageContract.getUserTrades(trader);
        assertEq(userTrades.length, 0);
    }

    function testMultipleTradesRemoval() public {
        vm.startPrank(address(mockTrading));

        for (uint256 i = 0; i < 3; i++) {
            IStorage.Trade memory trade = IStorage.Trade({
                openPrice: 1000 + i,
                leverage: 10,
                initialPosToken: 100,
                positionSizeDai: 1000,
                openFee: 10,
                tpPrice: 1100,
                slPrice: 900,
                orderType: 0,
                timestamp: block.timestamp,
                trader: trader,
                buy: true
            });
            storageContract.setTrade(i, trade);
        }

        uint256[] memory tradesBeforeRemoval = storageContract.getUserTrades(trader);
        assertEq(tradesBeforeRemoval.length, 3);

        storageContract.removeTrade(1);

        uint256[] memory tradesAfterRemoval = storageContract.getUserTrades(trader);
        assertEq(tradesAfterRemoval.length, 2);
        assertEq(tradesAfterRemoval[0], 0);
        assertEq(tradesAfterRemoval[1], 2);

        vm.stopPrank();
    }

    function testCannotSetInvalidTrade() public {
        vm.startPrank(address(mockTrading));

        vm.expectRevert("Invalid trader");
        storageContract.setTrade(
            0,
            IStorage.Trade({
                openPrice: 1000,
                leverage: 10,
                initialPosToken: 100,
                positionSizeDai: 1000,
                openFee: 10,
                tpPrice: 1100,
                slPrice: 900,
                orderType: 0,
                timestamp: block.timestamp,
                trader: address(0),
                buy: true
            })
        );

        vm.expectRevert("Min leverage is 2x");
        storageContract.setTrade(
            0,
            IStorage.Trade({
                openPrice: 1000,
                leverage: 1,
                initialPosToken: 100,
                positionSizeDai: 1000,
                openFee: 10,
                tpPrice: 1100,
                slPrice: 900,
                orderType: 0,
                timestamp: block.timestamp,
                trader: trader,
                buy: true
            })
        );

        vm.expectRevert("Max leverage is 150x");
        storageContract.setTrade(
            0,
            IStorage.Trade({
                openPrice: 1000,
                leverage: 151,
                initialPosToken: 100,
                positionSizeDai: 1000,
                openFee: 10,
                tpPrice: 1100,
                slPrice: 900,
                orderType: 0,
                timestamp: block.timestamp,
                trader: trader,
                buy: true
            })
        );

        vm.stopPrank();
    }

    function testCannotGrantTradingRoleUnauthorized() public {
        vm.startPrank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, trader, storageContract.DEFAULT_ADMIN_ROLE()
            )
        );
        storageContract.grantTradingRole(address(1));
        vm.stopPrank();
    }
}
