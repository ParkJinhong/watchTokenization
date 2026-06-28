import { ethers, network } from "hardhat";
import { writeFileSync } from "fs";
import { join } from "path";

// 데모 파라미터
const TOTAL_SHARES = ethers.parseUnits("1000", 18); // 시계 1점 = 1,000 지분
const INIT_PRICE = 100n * 10n ** 6n; // 토큰당 100 USDC (6dp)
const MAX_STALENESS = 3600; // 1시간
const ANNUAL_INTEREST_BPS = 1000; // 연 10%
const LIQUIDITY = 500_000n * 10n ** 6n; // 금고 대출 재원 500,000 USDC

async function main() {
  const [deployer, borrower] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const WatchToken = await ethers.getContractFactory("WatchToken");
  const watch = await WatchToken.deploy(
    "Rolex Submariner #1234",
    "wROLEX1",
    0, // Grade.S
    "APP-2026-0001",
    TOTAL_SHARES,
    borrower.address
  );
  await watch.waitForDeployment();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();

  const PriceOracle = await ethers.getContractFactory("PriceOracle");
  const oracle = await PriceOracle.deploy(MAX_STALENESS);
  await oracle.waitForDeployment();

  const WatchVault = await ethers.getContractFactory("WatchVault");
  const vault = await WatchVault.deploy(
    await watch.getAddress(),
    await usdc.getAddress(),
    await oracle.getAddress(),
    ANNUAL_INTEREST_BPS
  );
  await vault.waitForDeployment();

  // 초기 가격 + 대출 재원
  await (await oracle.setPrice(await watch.getAddress(), INIT_PRICE)).wait();
  await (await usdc.mint(deployer.address, LIQUIDITY)).wait();
  await (await usdc.approve(await vault.getAddress(), LIQUIDITY)).wait();
  await (await vault.fundLiquidity(LIQUIDITY)).wait();

  const deployments = {
    network: network.name,
    watchToken: await watch.getAddress(),
    usdc: await usdc.getAddress(),
    oracle: await oracle.getAddress(),
    vault: await vault.getAddress(),
    initialPrice: INIT_PRICE.toString(),
  };

  const outPath = join(__dirname, "..", "deployments.json");
  writeFileSync(outPath, JSON.stringify(deployments, null, 2));

  console.log("\n=== 배포 완료 ===");
  console.table(deployments);
  console.log(`\ndeployments.json 저장됨 → ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
