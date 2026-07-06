import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

const usdc = (n: number) => BigInt(Math.round(n * 1e6));
const shares = (n: number) => ethers.parseUnits(n.toString(), 18);
const PRICE = usdc(10); // 토큰 1개당 10 USDC

describe("토큰화 시장 (WatchShare · Factory · P2PMarket)", () => {
  async function deployFixture() {
    const [company, investorA, investorB, consignor] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdcToken = await MockUSDC.deploy();

    const WatchFactory = await ethers.getContractFactory("WatchFactory");
    const factory = await WatchFactory.deploy(await usdcToken.getAddress());

    const P2PMarket = await ethers.getContractFactory("P2PMarket");
    const market = await P2PMarket.deploy(await usdcToken.getAddress());

    for (const s of [company, investorA, investorB, consignor]) {
      await usdcToken.mint(s.address, usdc(1_000_000));
    }

    return { company, investorA, investorB, consignor, usdcToken, factory, market };
  }

  async function attach(addr: string) {
    return ethers.getContractAt("WatchShare", addr);
  }

  describe("발행 — 3가지 방법", () => {
    it("① 회사 보유분: 전량 회사에 발행", async () => {
      const { company, factory } = await loadFixture(deployFixture);
      await factory.issueCompany("Rolex #1", "wRLX1", 0, "REF-1", shares(1000), "ipfs://rolex1");
      const list = await factory.allWatches();
      expect(list.length).to.equal(1);
      expect(list[0].imageURI).to.equal("ipfs://rolex1");
      const token = await attach(list[0].token);
      expect(await token.totalSupply()).to.equal(shares(1000));
      expect(await token.balanceOf(company.address)).to.equal(shares(1000));
      expect(await token.issueMethod()).to.equal(0);
    });

    it("② 자금 모집: 기여 투자자에게 분배 발행", async () => {
      const { investorA, investorB, factory } = await loadFixture(deployFixture);
      await factory.issueCrowdfund(
        "Rolex #2",
        "wRLX2",
        1,
        "REF-2",
        [investorA.address, investorB.address],
        [shares(600), shares(400)],
        ""
      );
      const list = await factory.allWatches();
      const token = await attach(list[0].token);
      expect(await token.balanceOf(investorA.address)).to.equal(shares(600));
      expect(await token.balanceOf(investorB.address)).to.equal(shares(400));
      expect(await token.issueMethod()).to.equal(1);
    });

    it("③ 중개: 의뢰인에게 전량 발행", async () => {
      const { consignor, factory } = await loadFixture(deployFixture);
      await factory.issueConsignment("Omega #1", "wOMG1", 2, "REF-3", shares(500), consignor.address, "");
      const list = await factory.allWatches();
      const token = await attach(list[0].token);
      expect(await token.balanceOf(consignor.address)).to.equal(shares(500));
      expect(await token.issueMethod()).to.equal(2);
    });

    it("같은 이름으로 재발행하면 거부된다 (중복 토큰화 차단)", async () => {
      const { company, factory } = await loadFixture(deployFixture);
      await factory.issueCompany("Rolex #1", "wRLX1", 0, "REF-1", shares(1000), "ipfs://rolex1");
      await expect(
        factory.connect(company).issueCompany("Rolex #1", "wRLX1b", 0, "REF-9", shares(500), "")
      ).to.be.revertedWith("name already used");
    });
  });

  describe("대여 수수료 배당", () => {
    it("보유 비율대로 배당되고 출금된다", async () => {
      const { company, investorA, investorB, factory, usdcToken } = await loadFixture(deployFixture);
      await factory.issueCrowdfund(
        "Rolex #3",
        "wRLX3",
        0,
        "REF-4",
        [investorA.address, investorB.address],
        [shares(700), shares(300)],
        ""
      );
      const token = await attach((await factory.allWatches())[0].token);

      // 회사가 대여 수수료 1,000 USDC 분배
      await usdcToken.connect(company).approve(await token.getAddress(), usdc(1000));
      await token.connect(company).distributeRentalFee(usdc(1000));

      // 누적-per-share 배당은 정수 나눗셈 dust(±1)가 정상
      expect(await token.withdrawableDividendOf(investorA.address)).to.be.closeTo(usdc(700), 10n);
      expect(await token.withdrawableDividendOf(investorB.address)).to.be.closeTo(usdc(300), 10n);

      const before = await usdcToken.balanceOf(investorA.address);
      await token.connect(investorA).withdrawDividend();
      expect(await usdcToken.balanceOf(investorA.address)).to.be.closeTo(before + usdc(700), 10n);
      expect(await token.withdrawableDividendOf(investorA.address)).to.equal(0n);
    });

    it("거래로 토큰이 이동해도 배당 지분이 정확히 따라간다", async () => {
      const { company, investorA, factory, usdcToken } = await loadFixture(deployFixture);
      await factory.issueCompany("Rolex #4", "wRLX4", 0, "REF-5", shares(1000), "");
      const token = await attach((await factory.allWatches())[0].token);

      // 1차 분배: 회사 100% 보유 → 전액 회사 몫
      await usdcToken.connect(company).approve(await token.getAddress(), usdc(2000));
      await token.connect(company).distributeRentalFee(usdc(1000));

      // 회사가 절반을 투자자A에게 전송
      await token.connect(company).transfer(investorA.address, shares(500));

      // 2차 분배: 50:50 보유 → 각 500
      await token.connect(company).distributeRentalFee(usdc(1000));

      // 회사: 1000(1차 전액) + 500(2차 절반) = 1500, 투자자A: 0 + 500 = 500 (±dust)
      expect(await token.withdrawableDividendOf(company.address)).to.be.closeTo(usdc(1500), 10n);
      expect(await token.withdrawableDividendOf(investorA.address)).to.be.closeTo(usdc(500), 10n);
    });
  });

  describe("P2P 거래", () => {
    it("매도 등록 → 매수자가 체결(부분 체결 포함)", async () => {
      const { company, investorA, factory, market, usdcToken } = await loadFixture(deployFixture);
      await factory.issueCompany("Rolex #5", "wRLX5", 0, "REF-6", shares(1000), "");
      const token = await attach((await factory.allWatches())[0].token);
      const mAddr = await market.getAddress();

      // 회사: 100주 매도 등록 (토큰당 10 USDC)
      await token.connect(company).approve(mAddr, shares(100));
      await market.connect(company).createSell(await token.getAddress(), shares(100), PRICE);

      // 투자자A: 40주 부분 체결 → 400 USDC 지불
      await usdcToken.connect(investorA).approve(mAddr, usdc(400));
      const companyUsdcBefore = await usdcToken.balanceOf(company.address);
      await market.connect(investorA).fillSell(0, shares(40));

      expect(await token.balanceOf(investorA.address)).to.equal(shares(40));
      expect(await usdcToken.balanceOf(company.address)).to.equal(companyUsdcBefore + usdc(400));
      const order = await market.orders(0);
      expect(order.remaining).to.equal(shares(60));
      expect(order.active).to.equal(true);
    });

    it("매수 등록 → 매도자가 체결", async () => {
      const { company, investorA, factory, market, usdcToken } = await loadFixture(deployFixture);
      await factory.issueCompany("Rolex #6", "wRLX6", 0, "REF-7", shares(1000), "");
      const token = await attach((await factory.allWatches())[0].token);
      const mAddr = await market.getAddress();

      // 투자자A: 50주 매수 등록 (10 USDC) → 500 USDC 에스크로
      await usdcToken.connect(investorA).approve(mAddr, usdc(500));
      await market.connect(investorA).createBuy(await token.getAddress(), shares(50), PRICE);

      // 회사: 토큰 넘기고 체결
      await token.connect(company).approve(mAddr, shares(50));
      const aUsdcBefore = await usdcToken.balanceOf(investorA.address);
      await market.connect(company).fillBuy(0, shares(50));

      expect(await token.balanceOf(investorA.address)).to.equal(shares(50));
      expect(await usdcToken.balanceOf(investorA.address)).to.equal(aUsdcBefore); // 에스크로에서 이미 차감됨
      const order = await market.orders(0);
      expect(order.active).to.equal(false);
    });

    it("매도 주문 취소 시 토큰이 환불된다", async () => {
      const { company, factory, market } = await loadFixture(deployFixture);
      await factory.issueCompany("Rolex #7", "wRLX7", 0, "REF-8", shares(1000), "");
      const token = await attach((await factory.allWatches())[0].token);
      const mAddr = await market.getAddress();

      await token.connect(company).approve(mAddr, shares(100));
      await market.connect(company).createSell(await token.getAddress(), shares(100), PRICE);
      expect(await token.balanceOf(company.address)).to.equal(shares(900));

      await market.connect(company).cancel(0);
      expect(await token.balanceOf(company.address)).to.equal(shares(1000));
    });
  });
});
