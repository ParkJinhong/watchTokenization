// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PriceOracle
/// @notice 오프체인 시계 감정가를 온체인으로 푸시하는 단순 오라클.
///         백엔드(oracle.py)만 updater 권한으로 가격을 갱신하며,
///         일정 시간 이상 갱신되지 않은 가격은 stale로 간주해 사용을 막는다.
/// @dev 가격 단위: WatchToken 1개(1e18)당 USDC 금액(6 decimals).
contract PriceOracle is Ownable {
    struct PriceData {
        uint256 price; // USDC(6dp) per 1 WatchToken(1e18)
        uint256 updatedAt;
    }

    mapping(address => PriceData) private _prices;
    mapping(address => bool) public isUpdater;

    /// @notice 이 시간(초)보다 오래된 가격은 stale로 간주
    uint256 public maxStaleness;

    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);
    event UpdaterSet(address indexed updater, bool allowed);
    event MaxStalenessSet(uint256 maxStaleness);

    error NotUpdater();
    error ZeroPrice();
    error NoPrice();
    error StalePrice();

    constructor(uint256 maxStaleness_) Ownable(msg.sender) {
        maxStaleness = maxStaleness_;
        isUpdater[msg.sender] = true;
        emit UpdaterSet(msg.sender, true);
    }

    modifier onlyUpdater() {
        if (!isUpdater[msg.sender]) revert NotUpdater();
        _;
    }

    function setUpdater(address updater, bool allowed) external onlyOwner {
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed);
    }

    function setMaxStaleness(uint256 maxStaleness_) external onlyOwner {
        maxStaleness = maxStaleness_;
        emit MaxStalenessSet(maxStaleness_);
    }

    /// @notice 시계 토큰의 최신 감정가를 갱신한다. updater만 호출 가능.
    function setPrice(address token, uint256 price) external onlyUpdater {
        if (price == 0) revert ZeroPrice();
        _prices[token] = PriceData({price: price, updatedAt: block.timestamp});
        emit PriceUpdated(token, price, block.timestamp);
    }

    /// @notice 유효(non-stale)한 최신 가격을 반환. 미설정/만료 시 revert.
    function getPrice(address token) external view returns (uint256) {
        PriceData memory data = _prices[token];
        if (data.updatedAt == 0) revert NoPrice();
        if (block.timestamp - data.updatedAt > maxStaleness) revert StalePrice();
        return data.price;
    }

    /// @notice revert 없이 원시 가격 데이터를 조회 (모니터링/디버깅용)
    function priceData(address token) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = _prices[token];
        return (data.price, data.updatedAt);
    }
}
