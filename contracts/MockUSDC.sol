// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice 데모/테스트용 스테이블코인. 실제 USDC와 동일하게 6 decimals를 사용해
///         소수점 자릿수 불일치(흔한 실수 케이스)를 의도적으로 재현한다.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice 데모 편의를 위한 자유 발행 (운영 환경에서는 제거 대상)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
