import { ethers, artifacts, network } from "hardhat";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";

// 토큰화 시장 웹 테스트 도구 배포
// - MockUSDC / WatchFactory / P2PMarket 배포
// - 데모 계정에 USDC 지급
// - 프론트엔드가 읽을 frontend/contracts.js (주소 + ABI) 생성
async function main() {
  const signers = await ethers.getSigners();
  const deployer = signers[0];

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();

  const WatchFactory = await ethers.getContractFactory("WatchFactory");
  const factory = await WatchFactory.deploy(await usdc.getAddress());
  await factory.waitForDeployment();

  const P2PMarket = await ethers.getContractFactory("P2PMarket");
  const market = await P2PMarket.deploy(await usdc.getAddress());
  await market.waitForDeployment();

  // 데모 계정 5개에 USDC 100만씩 지급
  for (const s of signers.slice(0, 5)) {
    await (await usdc.mint(s.address, 1_000_000n * 10n ** 6n)).wait();
  }

  const addresses = {
    network: network.name,
    usdc: await usdc.getAddress(),
    factory: await factory.getAddress(),
    market: await market.getAddress(),
  };

  const abis = {
    MockUSDC: (await artifacts.readArtifact("MockUSDC")).abi,
    WatchFactory: (await artifacts.readArtifact("WatchFactory")).abi,
    P2PMarket: (await artifacts.readArtifact("P2PMarket")).abi,
    WatchShare: (await artifacts.readArtifact("WatchShare")).abi,
  };

  const dir = join(__dirname, "..", "frontend");
  mkdirSync(dir, { recursive: true });
  const content = `// 자동 생성 파일 — deploy-app.ts 실행 시 갱신됨\nwindow.APP = ${JSON.stringify(
    { addresses, abis },
    null,
    2
  )};\n`;
  writeFileSync(join(dir, "contracts.js"), content);

  console.log("=== 토큰화 앱 배포 완료 ===");
  console.table(addresses);
  console.log("frontend/contracts.js 생성됨");
  console.log("이제:  npm run app  →  http://localhost:5173");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
