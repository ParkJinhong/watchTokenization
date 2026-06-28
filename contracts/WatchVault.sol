// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PriceOracle} from "./PriceOracle.sol";

/// @title WatchVault
/// @notice 시계 분할 토큰(WatchToken)을 담보로 USDC를 대출해주는 금고.
///  - 신규 대출 한도: 담보 평가액의 50% (MAX_LTV)
///  - 청산: 담보 평가액이 부채 이하로 떨어지면(= 시계가가 대출시점의 50% 이하로 하락)
///          누구나 청산할 수 있다. 청산자는 부채를 대신 갚고 담보 전량을 인수한다.
/// @dev 평가액 계산 단위
///  - 담보 수량: WatchToken, 18 decimals
///  - 가격: WatchToken 1개(1e18)당 USDC(6dp)
///  - 평가액/부채: USDC, 6 decimals
contract WatchVault is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 5_000; // 신규 대출 한도 50%
    uint256 public constant LIQUIDATION_LTV_BPS = 10_000; // 청산 임계 LTV 100% (가격 50% 하락 지점)

    IERC20 public immutable collateralToken; // WatchToken
    IERC20 public immutable loanToken; // USDC
    PriceOracle public immutable oracle;

    /// @notice 연 환산 이자율(bps). 단순화를 위해 선형(단리) 누적.
    uint256 public annualInterestBps;

    struct Position {
        uint256 collateral; // 예치된 WatchToken 수량 (1e18)
        uint256 principal; // 대출 원금 (USDC, 6dp)
        uint256 accruedInterest; // 누적 이자 (USDC, 6dp)
        uint256 lastAccrued; // 마지막 이자 반영 시각
    }

    mapping(address => Position) public positions;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);
    event LiquidityFunded(address indexed from, uint256 amount);
    event AnnualInterestSet(uint256 bps);

    error ZeroAmount();
    error InsufficientCollateral();
    error ExceedsMaxLtv();
    error NoDebt();
    error NotLiquidatable();

    constructor(address collateralToken_, address loanToken_, address oracle_, uint256 annualInterestBps_)
        Ownable(msg.sender)
    {
        collateralToken = IERC20(collateralToken_);
        loanToken = IERC20(loanToken_);
        oracle = PriceOracle(oracle_);
        annualInterestBps = annualInterestBps_;
    }

    // ----------------------------------------------------------------
    // 운영
    // ----------------------------------------------------------------

    function setAnnualInterestBps(uint256 bps) external onlyOwner {
        annualInterestBps = bps;
        emit AnnualInterestSet(bps);
    }

    /// @notice 대출 재원(USDC)을 금고에 공급한다.
    function fundLiquidity(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        loanToken.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityFunded(msg.sender, amount);
    }

    // ----------------------------------------------------------------
    // 사용자 액션
    // ----------------------------------------------------------------

    /// @notice 시계 토큰을 담보로 예치한다.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        positions[msg.sender].collateral += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice 담보 일부를 인출한다. 인출 후에도 LTV 한도를 지켜야 한다.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage p = positions[msg.sender];
        if (amount > p.collateral) revert InsufficientCollateral();
        p.collateral -= amount;

        uint256 debt = p.principal + p.accruedInterest;
        if (debt > 0 && debt > _maxBorrow(p.collateral)) revert ExceedsMaxLtv();

        collateralToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice 담보 평가액의 50% 한도 내에서 USDC를 대출한다.
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage p = positions[msg.sender];

        uint256 newDebt = p.principal + p.accruedInterest + amount;
        if (newDebt > _maxBorrow(p.collateral)) revert ExceedsMaxLtv();

        p.principal += amount;
        loanToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice 부채(이자 → 원금 순)를 상환한다. 초과 입력 시 부채만큼만 상환.
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 debt = p.principal + p.accruedInterest;
        if (debt == 0) revert NoDebt();

        uint256 pay = amount > debt ? debt : amount;
        if (pay >= p.accruedInterest) {
            uint256 toPrincipal = pay - p.accruedInterest;
            p.accruedInterest = 0;
            p.principal -= toPrincipal;
        } else {
            p.accruedInterest -= pay;
        }

        loanToken.safeTransferFrom(msg.sender, address(this), pay);
        emit Repaid(msg.sender, pay);
    }

    /// @notice 담보가 부족해진(underwater) 포지션을 청산한다.
    ///         청산자는 부채 전액을 상환하고 담보 전량을 인수한다.
    function liquidate(address user) external nonReentrant {
        _accrue(user);
        Position storage p = positions[user];
        uint256 debt = p.principal + p.accruedInterest;
        if (debt == 0) revert NoDebt();
        if (!_isLiquidatable(p.collateral, debt)) revert NotLiquidatable();

        uint256 seized = p.collateral;
        p.collateral = 0;
        p.principal = 0;
        p.accruedInterest = 0;

        loanToken.safeTransferFrom(msg.sender, address(this), debt);
        collateralToken.safeTransfer(msg.sender, seized);
        emit Liquidated(user, msg.sender, debt, seized);
    }

    // ----------------------------------------------------------------
    // 조회
    // ----------------------------------------------------------------

    /// @notice 이자까지 반영한 현재 총부채(USDC, 6dp)
    function debtOf(address user) public view returns (uint256) {
        Position memory p = positions[user];
        return p.principal + p.accruedInterest + _pendingInterest(p);
    }

    /// @notice 담보 평가액(USDC, 6dp) — stale/미설정 가격이면 revert
    function collateralValue(address user) public view returns (uint256) {
        return _collateralValue(positions[user].collateral);
    }

    /// @notice 현재 추가 대출 가능액(USDC, 6dp)
    function availableToBorrow(address user) external view returns (uint256) {
        uint256 limit = _maxBorrow(positions[user].collateral);
        uint256 debt = debtOf(user);
        return limit > debt ? limit - debt : 0;
    }

    /// @notice 청산 가능 여부
    function isLiquidatable(address user) external view returns (bool) {
        Position memory p = positions[user];
        uint256 debt = p.principal + p.accruedInterest + _pendingInterest(p);
        if (debt == 0) return false;
        return _isLiquidatable(p.collateral, debt);
    }

    // ----------------------------------------------------------------
    // 내부 로직
    // ----------------------------------------------------------------

    function _accrue(address user) internal {
        Position storage p = positions[user];
        if (p.principal == 0) {
            p.lastAccrued = block.timestamp;
            return;
        }
        uint256 pending = _pendingInterest(p);
        if (pending > 0) {
            p.accruedInterest += pending;
        }
        p.lastAccrued = block.timestamp;
    }

    function _pendingInterest(Position memory p) internal view returns (uint256) {
        if (p.principal == 0 || p.lastAccrued == 0) return 0;
        uint256 dt = block.timestamp - p.lastAccrued;
        if (dt == 0) return 0;
        return (p.principal * annualInterestBps * dt) / (365 days * BPS);
    }

    function _collateralValue(uint256 collateral) internal view returns (uint256) {
        uint256 price = oracle.getPrice(address(collateralToken)); // USDC(6dp) per 1e18 token
        return (collateral * price) / 1e18;
    }

    function _maxBorrow(uint256 collateral) internal view returns (uint256) {
        return (_collateralValue(collateral) * MAX_LTV_BPS) / BPS;
    }

    function _isLiquidatable(uint256 collateral, uint256 debt) internal view returns (bool) {
        // 담보가치 * BPS <= 부채 * 청산임계LTV  ⇒  LTV >= 임계
        return _collateralValue(collateral) * BPS <= debt * LIQUIDATION_LTV_BPS;
    }
}
