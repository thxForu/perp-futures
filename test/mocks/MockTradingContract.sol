// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "../../src/Storage.sol";

contract MockTradingContract {
    Storage public storageContract;

    constructor() {}

    function setStorageContract(address _storage) external {
        storageContract = Storage(_storage);
    }
}
