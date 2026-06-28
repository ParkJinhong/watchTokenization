"""
시계 감정가 오라클 푸시 서비스
--------------------------------
오프체인 시계 시세(여기서는 데모용 랜덤워크)를 주기적으로 PriceOracle
컨트랙트에 푸시한다. 실제 운영에서는 감정 시스템/시세 API를 연동하면 된다.

공고 대응 포인트:
  - Python 기반 블록체인 연동 백엔드 (web3.py)
  - 트랜잭션 전송 + 예외 처리 + 재시도(nonce/네트워크 오류 대응)
  - REST 시세 소스 연동을 염두에 둔 구조 (fetch_price 교체만 하면 됨)

실행:
  1) 다른 터미널에서  npx hardhat node
  2) npm run deploy:local        # deployments.json 생성
  3) python oracle/oracle.py
"""

from __future__ import annotations

import json
import os
import random
import time
from pathlib import Path

from dotenv import load_dotenv
from web3 import Web3

load_dotenv()

ROOT = Path(__file__).resolve().parent.parent
DEPLOYMENTS = ROOT / "deployments.json"

RPC_URL = os.getenv("RPC_URL", "http://127.0.0.1:8545")
PRIVATE_KEY = os.getenv(
    "ORACLE_PRIVATE_KEY",
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
)
PUSH_INTERVAL = int(os.getenv("PUSH_INTERVAL_SECONDS", "10"))

# PriceOracle.setPrice 만 있으면 되므로 최소 ABI만 포함
ORACLE_ABI = json.loads(
    """
[
  {"inputs":[{"internalType":"address","name":"token","type":"address"},
             {"internalType":"uint256","name":"price","type":"uint256"}],
   "name":"setPrice","outputs":[],"stateMutability":"nonpayable","type":"function"},
  {"inputs":[{"internalType":"address","name":"token","type":"address"}],
   "name":"priceData","outputs":[{"internalType":"uint256","name":"price","type":"uint256"},
                                 {"internalType":"uint256","name":"updatedAt","type":"uint256"}],
   "stateMutability":"view","type":"function"}
]
"""
)


def load_deployments() -> dict:
    if not DEPLOYMENTS.exists():
        raise SystemExit(
            "deployments.json 이 없습니다. 먼저 `npm run deploy:local` 을 실행하세요."
        )
    return json.loads(DEPLOYMENTS.read_text(encoding="utf-8"))


def fetch_price(last_price: int) -> int:
    """
    데모용 시세 생성기 (랜덤워크).
    실제 운영에서는 이 함수만 감정 시스템/시세 REST API 호출로 교체하면 된다.
    가격 단위: 토큰 1개당 USDC (6 decimals)
    """
    drift = random.uniform(-0.08, 0.05)  # 매 틱 -8% ~ +5%
    new_price = int(last_price * (1 + drift))
    return max(new_price, 1)  # 0 가격은 컨트랙트가 거부하므로 하한 보장


def main() -> None:
    dep = load_deployments()
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        raise SystemExit(f"RPC 연결 실패: {RPC_URL} (hardhat node 가 떠 있나요?)")

    account = w3.eth.account.from_key(PRIVATE_KEY)
    oracle = w3.eth.contract(
        address=Web3.to_checksum_address(dep["oracle"]), abi=ORACLE_ABI
    )
    token = Web3.to_checksum_address(dep["watchToken"])

    print(f"[oracle] updater = {account.address}")
    print(f"[oracle] PriceOracle = {dep['oracle']}")
    print(f"[oracle] watchToken = {token}")
    print(f"[oracle] {PUSH_INTERVAL}초마다 가격 푸시 시작\n")

    price = int(dep.get("initialPrice", 100 * 10**6))

    while True:
        price = fetch_price(price)
        try:
            tx = oracle.functions.setPrice(token, price).build_transaction(
                {
                    "from": account.address,
                    "nonce": w3.eth.get_transaction_count(account.address),
                    "gas": 120_000,
                    "gasPrice": w3.eth.gas_price,
                }
            )
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)

            human = price / 10**6
            status = "ok" if receipt.status == 1 else "FAILED"
            print(
                f"[oracle] price={human:,.2f} USDC  tx={tx_hash.hex()[:10]}…  {status}"
            )
        except Exception as exc:  # 네트워크/논스 충돌 등은 다음 틱에 재시도
            print(f"[oracle] 푸시 실패, 다음 주기에 재시도: {exc}")

        time.sleep(PUSH_INTERVAL)


if __name__ == "__main__":
    main()
