// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ITradingPool.sol";

contract TradingPool is ITradingPool, ReentrancyGuard, AccessControl {
    bytes32 public constant TRADING_ROLE = keccak256("TRADING_ROLE");

    IERC20 public immutable dai;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lockedMargins;

    constructor(address _dai) {
        require(_dai != address(0), "Invalid DAI address");
        dai = IERC20(_dai);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function deposit(uint256 amount) external override nonReentrant {
        require(amount > 0, "Invalid amount");
        require(dai.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external override nonReentrant {
        require(amount > 0, "Invalid amount");
        require(getAvailableBalance(msg.sender) >= amount, "Insufficient available balance");

        balances[msg.sender] -= amount;
        require(dai.transfer(msg.sender, amount), "Transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    function addProfit(address user, uint256 amount) external override nonReentrant onlyRole(TRADING_ROLE) {
        require(amount > 0, "Invalid amount");
        balances[user] += amount;
        emit ProfitAdded(user, amount);
    }

    function transferReward(address liquidator, uint256 amount) external override nonReentrant onlyRole(TRADING_ROLE) {
        require(amount > 0, "Invalid amount");
        require(liquidator != address(0), "Invalid liquidator address");

        balances[liquidator] += amount;
        emit RewardPaid(liquidator, amount);
    }

    function getAvailableBalance(address user) public view override returns (uint256) {
        return balances[user] - lockedMargins[user];
    }

    function getTotalBalance(address user) external view override returns (uint256) {
        return balances[user];
    }

    function lockMargin(address user, uint256 amount) external override nonReentrant onlyRole(TRADING_ROLE) {
        require(amount > 0, "Invalid amount");
        require(getAvailableBalance(user) >= amount, "Insufficient available balance");

        lockedMargins[user] += amount;
        emit MarginUsed(user, amount);
    }

    function releaseMargin(address user, uint256 amount) external override nonReentrant onlyRole(TRADING_ROLE) {
        require(amount > 0, "Invalid amount");
        require(lockedMargins[user] >= amount, "Invalid locked amount");

        lockedMargins[user] -= amount;
        emit MarginReleased(user, amount);
    }

    function hasEnoughAvailableMargin(address user, uint256 amount) external view override returns (bool) {
        return getAvailableBalance(user) >= amount;
    }

    function grantTradingRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(TRADING_ROLE, account);
    }

    function revokeTradingRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(TRADING_ROLE, account);
    }
}
