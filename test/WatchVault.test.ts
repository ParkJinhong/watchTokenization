import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

// 단위 헬퍼
const usdc = (n: number) => BigInt(Math.round(n * 1e6)); // USDC 6 decimals
const shares = (n: number) => ethers.parseUnits(n.toString(), 18); // WatchToken 18 decimals

// 시나리오 기준값
// - 시계 1점 = 1,000 지분, 토큰당 초기가 100 USDC → 시계 평가액 100,000 USDC
const TOTAL_SHARES = shares(1000);
const INIT_PRICE = usdc(100); // 토큰 1개당 100 USDC
const MAX_STALENESS = 3600; // 1시간

describe("WatchVault", () => {
  async function deployFixture() {
    const [deployer, borrower, liquidator] = await ethers.getSigners();

    const WatchToken = await ethers.getContractFactory("WatchToken");
    // grade S = 0
    const watch = await WatchToken.deploy(
      "Rolex Submariner #1234",
      "wROLEX1",
      0,
      "APP-2026-0001",
      TOTAL_SHARES,
      borrower.address
    );

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdcToken = await MockUSDC.deploy();

    const PriceOracle = await ethers.getContractFactory("PriceOracle");
    const oracle = await PriceOracle.deploy(MAX_STALENESS);

    const WatchVault = await ethers.getContractFactory("WatchVault");
    // 연 이자 10% (1000 bps)
    const vault = await WatchVault.deploy(
      await watch.getAddress(),
      await usdcToken.getAddress(),
      await oracle.getAddress(),
      1000
    );

    // 초기 가격 설정
    await oracle.setPrice(await watch.getAddress(), INIT_PRICE);

    // 금고에 대출 재원 공급
    await usdcToken.mint(deployer.address, usdc(1_000_000));
    await usdcToken.approve(await vault.getAddress(), usdc(1_000_000));
    await vault.fundLiquidity(usdc(500_000));

    // 청산자에게 상환용 USDC 지급
    await usdcToken.mint(liquidator.address, usdc(200_000));

    return { deployer, borrower, liquidator, watch, usdcToken, oracle, vault };
  }

  async function depositAll(ctx: Awaited<ReturnType<typeof deployFixture>>) {
    const { borrower, watch, vault } = ctx;
    await watch.connect(borrower).approve(await vault.getAddress(), TOTAL_SHARES);
    await vault.connect(borrower).deposit(TOTAL_SHARES);
  }

  describe("토큰화", () => {
    it("등급/식별자/총발행량이 올바르게 설정된다", async () => {
      const { watch, borrower } = await loadFixture(deployFixture);
      expect(await watch.grade()).to.equal(0); // S
      expect(await watch.referenceId()).to.equal("APP-2026-0001");
      expect(await watch.totalSupply()).to.equal(TOTAL_SHARES);
      expect(await watch.balanceOf(borrower.address)).to.equal(TOTAL_SHARES);
    });
  });

  describe("대출", () => {
    it("담보 평가액의 50%까지 대출할 수 있다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, vault, usdcToken } = ctx;

      // 평가액 100,000 → 최대 50,000
      expect(await vault.collateralValue(borrower.address)).to.equal(usdc(100_000));
      expect(await vault.availableToBorrow(borrower.address)).to.equal(usdc(50_000));

      await expect(vault.connect(borrower).borrow(usdc(50_000))).to.emit(vault, "Borrowed");
      expect(await usdcToken.balanceOf(borrower.address)).to.equal(usdc(50_000));
    });

    it("50% 한도를 넘으면 revert 한다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, vault } = ctx;
      await expect(vault.connect(borrower).borrow(usdc(50_001))).to.be.revertedWithCustomError(
        vault,
        "ExceedsMaxLtv"
      );
    });
  });

  describe("청산", () => {
    it("가격이 50% 이하로 하락하면 청산 가능 상태가 된다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, vault, oracle, watch } = ctx;

      await vault.connect(borrower).borrow(usdc(50_000)); // 최대 대출
      expect(await vault.isLiquidatable(borrower.address)).to.equal(false);

      // 토큰당 가격 100 → 49 (51% 하락) → 평가액 49,000 < 부채 50,000
      await oracle.setPrice(await watch.getAddress(), usdc(49));
      expect(await vault.isLiquidatable(borrower.address)).to.equal(true);
    });

    it("청산자가 부채를 갚고 담보를 전량 인수한다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, liquidator, vault, oracle, watch, usdcToken } = ctx;

      await vault.connect(borrower).borrow(usdc(50_000));
      await oracle.setPrice(await watch.getAddress(), usdc(49));

      await usdcToken.connect(liquidator).approve(await vault.getAddress(), usdc(200_000));
      await expect(vault.connect(liquidator).liquidate(borrower.address)).to.emit(vault, "Liquidated");

      // 담보가 청산자에게 넘어가고 포지션이 비워진다
      expect(await watch.balanceOf(liquidator.address)).to.equal(TOTAL_SHARES);
      const pos = await vault.positions(borrower.address);
      expect(pos.collateral).to.equal(0n);
      expect(pos.principal).to.equal(0n);
    });

    it("건전한 포지션은 청산할 수 없다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, liquidator, vault, usdcToken } = ctx;

      await vault.connect(borrower).borrow(usdc(30_000)); // LTV 30%
      await usdcToken.connect(liquidator).approve(await vault.getAddress(), usdc(200_000));
      await expect(vault.connect(liquidator).liquidate(borrower.address)).to.be.revertedWithCustomError(
        vault,
        "NotLiquidatable"
      );
    });
  });

  describe("이자 / 상환", () => {
    it("시간이 지나면 이자가 누적된다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, vault } = ctx;

      await vault.connect(borrower).borrow(usdc(10_000));
      await time.increase(365 * 24 * 3600); // 1년

      // 연 10% → 약 1,000 USDC 이자 (단리)
      const debt = await vault.debtOf(borrower.address);
      expect(debt).to.be.closeTo(usdc(11_000), usdc(1));
    });

    it("상환하면 부채가 줄어든다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, vault, usdcToken } = ctx;

      await vault.connect(borrower).borrow(usdc(10_000));
      await usdcToken.connect(borrower).approve(await vault.getAddress(), usdc(10_000));
      await vault.connect(borrower).repay(usdc(4_000));

      const debt = await vault.debtOf(borrower.address);
      expect(debt).to.be.closeTo(usdc(6_000), usdc(1));
    });
  });

  describe("오라클 예외 처리", () => {
    it("stale 가격이면 대출 관련 조회가 revert 한다", async () => {
      const ctx = await loadFixture(deployFixture);
      await depositAll(ctx);
      const { borrower, vault, oracle } = ctx;

      await time.increase(MAX_STALENESS + 1);
      await expect(vault.collateralValue(borrower.address)).to.be.revertedWithCustomError(
        oracle,
        "StalePrice"
      );
    });

    it("0 가격은 설정할 수 없다", async () => {
      const ctx = await loadFixture(deployFixture);
      const { oracle, watch } = ctx;
      await expect(oracle.setPrice(await watch.getAddress(), 0)).to.be.revertedWithCustomError(
        oracle,
        "ZeroPrice"
      );
    });

    it("updater가 아니면 가격을 설정할 수 없다", async () => {
      const ctx = await loadFixture(deployFixture);
      const { oracle, watch, borrower } = ctx;
      await expect(
        oracle.connect(borrower).setPrice(await watch.getAddress(), usdc(100))
      ).to.be.revertedWithCustomError(oracle, "NotUpdater");
    });
  });
});
