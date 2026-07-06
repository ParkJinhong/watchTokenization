// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WatchShare} from "./WatchShare.sol";

/// @title WatchFactory
/// @notice 시계 분할 지분 토큰(WatchShare)을 세 가지 방법으로 발행한다.
///  ① 회사 보유분 토큰화  ② 자금 모집 후 분배  ③ 토큰화 희망자 중개
contract WatchFactory {
    struct WatchInfo {
        address token;
        string name;
        string symbol;
        WatchShare.Grade grade;
        WatchShare.IssueMethod method;
        uint256 totalShares;
        string imageURI; // 시계 사진 (URL 또는 IPFS 주소)
    }

    address public immutable dividendToken; // USDC
    WatchInfo[] public watches;
    mapping(bytes32 => bool) public nameTaken; // 이름 중복 방지 (keccak256(name) → 사용됨)

    event WatchIssued(address indexed token, uint8 method, uint256 totalShares);

    constructor(address dividendToken_) {
        dividendToken = dividendToken_;
    }

    function watchCount() external view returns (uint256) {
        return watches.length;
    }

    function allWatches() external view returns (WatchInfo[] memory) {
        return watches;
    }

    /// @notice ① 회사 보유분 토큰화 — 전량을 회사(호출자)에게 발행
    function issueCompany(
        string memory name,
        string memory symbol,
        WatchShare.Grade grade,
        string memory refId,
        uint256 totalShares,
        string memory imageURI
    ) external returns (address) {
        address[] memory holders = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        holders[0] = msg.sender;
        amounts[0] = totalShares;
        return _create(name, symbol, grade, refId, WatchShare.IssueMethod.Company, holders, amounts, totalShares, imageURI);
    }

    /// @notice ② 자금 모집 후 구입 — 기여한 투자자들에게 지분을 분배 발행
    function issueCrowdfund(
        string memory name,
        string memory symbol,
        WatchShare.Grade grade,
        string memory refId,
        address[] memory holders,
        uint256[] memory amounts,
        string memory imageURI
    ) external returns (address) {
        uint256 total;
        for (uint256 i; i < amounts.length; i++) {
            total += amounts[i];
        }
        return _create(name, symbol, grade, refId, WatchShare.IssueMethod.Crowdfund, holders, amounts, total, imageURI);
    }

    /// @notice ③ 토큰화 희망자 중개 — 의뢰인에게 전량 발행
    function issueConsignment(
        string memory name,
        string memory symbol,
        WatchShare.Grade grade,
        string memory refId,
        uint256 totalShares,
        address consignor,
        string memory imageURI
    ) external returns (address) {
        address[] memory holders = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        holders[0] = consignor;
        amounts[0] = totalShares;
        return _create(name, symbol, grade, refId, WatchShare.IssueMethod.Consignment, holders, amounts, totalShares, imageURI);
    }

    function _create(
        string memory name,
        string memory symbol,
        WatchShare.Grade grade,
        string memory refId,
        WatchShare.IssueMethod method,
        address[] memory holders,
        uint256[] memory amounts,
        uint256 totalShares,
        string memory imageURI
    ) internal returns (address) {
        bytes32 key = keccak256(bytes(name));
        require(!nameTaken[key], "name already used"); // 같은 이름(=같은 시계)의 중복 토큰화 차단
        nameTaken[key] = true;
        WatchShare token = new WatchShare(name, symbol, grade, refId, method, dividendToken, holders, amounts);
        watches.push(WatchInfo(address(token), name, symbol, grade, method, totalShares, imageURI));
        emit WatchIssued(address(token), uint8(method), totalShares);
        return address(token);
    }
}
