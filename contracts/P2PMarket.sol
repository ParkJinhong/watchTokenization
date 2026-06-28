// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title P2PMarket
/// @notice 시계 분할 토큰을 USDC로 사고파는 단순 P2P 주문 거래소.
///  - 매도 등록: 토큰을 에스크로하고 가격에 내놓음 → 매수자가 USDC로 체결
///  - 매수 등록: USDC를 에스크로하고 매수가를 제시 → 매도자가 토큰으로 체결
///  - 부분 체결 / 취소 지원
/// @dev 가격 단위: 토큰 1개(1e18)당 USDC(6 decimals).
contract P2PMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Sell,
        Buy
    }

    struct Order {
        uint256 id;
        address maker;
        address token;
        Side side;
        uint256 amount; // 최초 수량
        uint256 remaining; // 남은 수량
        uint256 price; // 토큰당 USDC(6dp)
        bool active;
    }

    IERC20 public immutable payToken; // USDC
    Order[] public orders;

    event OrderCreated(uint256 indexed id, address indexed maker, address token, uint8 side, uint256 amount, uint256 price);
    event OrderFilled(uint256 indexed id, address indexed taker, uint256 fillAmount);
    event OrderCancelled(uint256 indexed id);

    constructor(address payToken_) {
        payToken = IERC20(payToken_);
    }

    function ordersCount() external view returns (uint256) {
        return orders.length;
    }

    function allOrders() external view returns (Order[] memory) {
        return orders;
    }

    function cost(uint256 amount, uint256 price) public pure returns (uint256) {
        return (amount * price) / 1e18;
    }

    /// @notice 매도 등록 — 토큰을 에스크로
    function createSell(address token, uint256 amount, uint256 price) external nonReentrant returns (uint256 id) {
        require(amount > 0 && price > 0, "bad params");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        id = orders.length;
        orders.push(Order(id, msg.sender, token, Side.Sell, amount, amount, price, true));
        emit OrderCreated(id, msg.sender, token, uint8(Side.Sell), amount, price);
    }

    /// @notice 매수 등록 — USDC를 에스크로
    function createBuy(address token, uint256 amount, uint256 price) external nonReentrant returns (uint256 id) {
        require(amount > 0 && price > 0, "bad params");
        payToken.safeTransferFrom(msg.sender, address(this), cost(amount, price));
        id = orders.length;
        orders.push(Order(id, msg.sender, token, Side.Buy, amount, amount, price, true));
        emit OrderCreated(id, msg.sender, token, uint8(Side.Buy), amount, price);
    }

    /// @notice 매도 주문 체결 — 매수자가 USDC를 지불하고 토큰을 받음
    function fillSell(uint256 id, uint256 fillAmount) external nonReentrant {
        Order storage o = orders[id];
        require(o.active && o.side == Side.Sell, "not fillable");
        require(fillAmount > 0 && fillAmount <= o.remaining, "bad amount");
        uint256 pay = cost(fillAmount, o.price);
        o.remaining -= fillAmount;
        if (o.remaining == 0) o.active = false;
        payToken.safeTransferFrom(msg.sender, o.maker, pay); // 매수자 → 매도자
        IERC20(o.token).safeTransfer(msg.sender, fillAmount); // 에스크로 → 매수자
        emit OrderFilled(id, msg.sender, fillAmount);
    }

    /// @notice 매수 주문 체결 — 매도자가 토큰을 넘기고 USDC를 받음
    function fillBuy(uint256 id, uint256 fillAmount) external nonReentrant {
        Order storage o = orders[id];
        require(o.active && o.side == Side.Buy, "not fillable");
        require(fillAmount > 0 && fillAmount <= o.remaining, "bad amount");
        uint256 pay = cost(fillAmount, o.price);
        o.remaining -= fillAmount;
        if (o.remaining == 0) o.active = false;
        IERC20(o.token).safeTransferFrom(msg.sender, o.maker, fillAmount); // 매도자 → 매수자
        payToken.safeTransfer(msg.sender, pay); // 에스크로 → 매도자
        emit OrderFilled(id, msg.sender, fillAmount);
    }

    /// @notice 주문 취소 — 에스크로 환불
    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.active && o.maker == msg.sender, "not your active order");
        o.active = false;
        if (o.side == Side.Sell) {
            IERC20(o.token).safeTransfer(o.maker, o.remaining);
        } else {
            payToken.safeTransfer(o.maker, cost(o.remaining, o.price));
        }
        emit OrderCancelled(id);
    }
}
