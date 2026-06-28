// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WatchShare
/// @notice 시계 1점의 분할 지분 ERC-20. 대여 수익(USDC)을 보유 비율대로
///         배당받고(claim) 출금할 수 있다. 토큰이 거래로 이동해도 배당 지분이
///         정확히 따라가도록 누적-per-share 방식으로 정산한다.
/// @dev 배당 단위: USDC(6 decimals). 지분 단위: 18 decimals.
contract WatchShare is ERC20 {
    using SafeERC20 for IERC20;

    enum Grade {
        S,
        A,
        B,
        C
    }
    enum IssueMethod {
        Company, // ① 회사 보유분 토큰화
        Crowdfund, // ② 자금 모집 후 구입·분배
        Consignment // ③ 토큰화 희망자 중개
    }

    Grade public immutable grade;
    IssueMethod public immutable issueMethod;
    string public referenceId;
    IERC20 public immutable dividendToken; // USDC

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) public withdrawnDividendOf;
    uint256 public totalDividendsDistributed;

    event RentalFeeDistributed(address indexed from, uint256 amount);
    event DividendWithdrawn(address indexed account, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        Grade grade_,
        string memory referenceId_,
        IssueMethod method_,
        address dividendToken_,
        address[] memory holders_,
        uint256[] memory amounts_
    ) ERC20(name_, symbol_) {
        require(holders_.length == amounts_.length && holders_.length > 0, "bad distribution");
        grade = grade_;
        referenceId = referenceId_;
        issueMethod = method_;
        dividendToken = IERC20(dividendToken_);
        for (uint256 i; i < holders_.length; i++) {
            _mint(holders_[i], amounts_[i]);
        }
        require(totalSupply() > 0, "zero supply");
    }

    /// @notice 대여 수익을 입금해 전체 보유자에게 분배한다(보유 비율 비례).
    function distributeRentalFee(uint256 amount) external {
        require(amount > 0, "zero amount");
        uint256 supply = totalSupply();
        dividendToken.safeTransferFrom(msg.sender, address(this), amount);
        magnifiedDividendPerShare += (amount * MAGNITUDE) / supply;
        totalDividendsDistributed += amount;
        emit RentalFeeDistributed(msg.sender, amount);
    }

    /// @notice 보유자가 받을 수 있는 누적 배당 총액(출금분 포함)
    function accumulativeDividendOf(address account) public view returns (uint256) {
        return
            uint256(int256(magnifiedDividendPerShare * balanceOf(account)) + magnifiedCorrections[account]) /
            MAGNITUDE;
    }

    /// @notice 아직 출금하지 않은 청구 가능 배당
    function withdrawableDividendOf(address account) public view returns (uint256) {
        return accumulativeDividendOf(account) - withdrawnDividendOf[account];
    }

    /// @notice 청구 가능 배당을 출금한다.
    function withdrawDividend() external {
        uint256 amount = withdrawableDividendOf(msg.sender);
        require(amount > 0, "nothing to withdraw");
        withdrawnDividendOf[msg.sender] += amount;
        dividendToken.safeTransfer(msg.sender, amount);
        emit DividendWithdrawn(msg.sender, amount);
    }

    /// @dev mint/burn/transfer 시 배당 지분 보정 — 토큰이 이동해도 배당이 정확히 따라간다.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        int256 corr = int256(magnifiedDividendPerShare * value);
        magnifiedCorrections[from] += corr;
        magnifiedCorrections[to] -= corr;
    }
}
