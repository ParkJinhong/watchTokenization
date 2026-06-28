# Watch Tokenization — 시계 분할 토큰화 dApp

[![CI](https://github.com/ParkJinhong/watchTokenization/actions/workflows/ci.yml/badge.svg)](https://github.com/ParkJinhong/watchTokenization/actions/workflows/ci.yml)

실물 명품 시계를 **ERC-20으로 분할 토큰화**하여 누구나 소액으로 투자·거래하고, 시계 **대여 수익을 보유 비율대로 배당**받는 dApp 데모입니다. 브라우저에서 토큰 발행 → P2P 거래 → 배당까지 전 과정을 테스트할 수 있습니다.

> 명품 시계 거래 인프라 → 디지털 자산화(토큰화)로 확장하는 사업 흐름을 가정한 포트폴리오 프로젝트입니다.

📄 **기획·리스크 분석 → [문서(HTML)](docs/시계토큰화_기획_리스크.html)** · 🗺️ **구조도 → [전체](docs/구조도.html)** · [토큰화 시장](docs/구조도_토큰화시장.html)

## 핵심 기능

| 기능 | 설명 |
|---|---|
| **토큰 발행 (3가지)** | ① 회사 보유분 토큰화 ② 자금 모집 후 투자자 분배 ③ 토큰화 희망자 중개 |
| **P2P 거래** | 매도/매수 주문 등록 · 부분 체결 · 취소 (USDC 결제) |
| **대여 수익 배당** | 회사가 대여 수익을 입금하면 보유 비율대로 분배, 보유자가 청구(claim) 출금 |
| **거래 이동 정합성** | 토큰이 거래로 손바뀜해도 배당 지분이 정확히 따라감 (누적 per-share 보정) |

## 컨트랙트

| 컨트랙트 | 역할 |
|---|---|
| `WatchShare.sol` | 시계 분할 지분 ERC-20 + 대여수익 배당(누적 per-share, claim) |
| `WatchFactory.sol` | 3가지 방법으로 WatchShare 발행 |
| `P2PMarket.sol` | 매도·매수 주문 거래소 (에스크로, 부분 체결, ReentrancyGuard) |
| `MockUSDC.sol` | 결제·배당 통화 (실제 USDC와 동일한 6 decimals) |

## 실행

### 1. 설치 & 테스트

```bash
npm install
npm run compile
npm test
```

### 2. 웹 테스트 도구 (로컬)

MetaMask 없이 Hardhat 기본 계정을 골라가며 테스트합니다.

```bash
# 터미널 A — 로컬 체인
npx hardhat node

# 터미널 B — 배포 (frontend/contracts.js 생성)
npm run deploy:app

# 터미널 C — 프론트엔드 서버
npm run app          # → http://localhost:5173
```

브라우저에서 `http://localhost:5173` 접속 후, 상단에서 **계정(회사/투자자A·B·C)**을 바꿔가며:

1. **토큰 발행** — 세 가지 방법 중 선택
2. **P2P 거래** — 투자자로 매수, 회사로 매도 등 체결
3. **대여 수수료** — 회사가 10초마다 자동 분배(또는 1회)
4. **배당 출금** — 보유자가 자기 몫 청구

## 테스트 커버리지 (`test/Tokenization.test.ts`)

- 발행 3가지 방법(회사/모집/중개) 및 분배 정확성
- 대여 수익 배당 — 보유 비율 비례, **거래로 토큰 이동 시 지분 추적**
- P2P 거래 — 매도/매수 등록, 부분 체결, 취소 환불

## 기술 스택

Solidity 0.8.24 · Hardhat · TypeScript · Ethers.js v6 · OpenZeppelin 5 · Vanilla JS 프론트엔드(빌드리스, Ethers CDN)

## 한계 / 다음 단계 (의도적 범위 제한)

- AMM(유니스왑형) 거래는 P2P 다음 단계로
- 증권형 토큰(ERC-3643)·KYC·실물 custody는 서비스화 로드맵 (상세: 기획·리스크 문서)
