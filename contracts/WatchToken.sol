// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title WatchToken
/// @notice 실물 명품 시계 한 점을 분할 소유하기 위한 ERC-20 토큰.
///         총발행량(totalSupply)이 시계 1점의 100% 지분을 의미한다.
///         예) 1,000개 발행 → 1토큰 = 시계 지분의 0.1%
contract WatchToken is ERC20, Ownable {
    /// @notice 시계 컨디션 등급 (S가 최상)
    enum Grade {
        S,
        A,
        B,
        C
    }

    /// @notice 컨디션 등급 (발행 시 고정)
    Grade public immutable grade;

    /// @notice 실물 시계 식별자(감정서/시리얼 번호 등)
    string public referenceId;

    /// @param name_        토큰 이름 (예: "Rolex Submariner #1234")
    /// @param symbol_      토큰 심볼 (예: "wROLEX1")
    /// @param grade_       컨디션 등급
    /// @param referenceId_ 실물 시계 식별자
    /// @param totalShares_ 총 발행 지분 수량 (18 decimals)
    /// @param holder_      최초 지분 보유자(회사 금고 등)
    constructor(
        string memory name_,
        string memory symbol_,
        Grade grade_,
        string memory referenceId_,
        uint256 totalShares_,
        address holder_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        grade = grade_;
        referenceId = referenceId_;
        _mint(holder_, totalShares_);
    }
}
