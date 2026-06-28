// 의존성 없는 정적 파일 서버 + 로컬 체인 RPC 프록시
// - 정적 파일: frontend/ 디렉터리
// - POST /rpc  →  http://127.0.0.1:8545 로 프록시 (같은 origin으로 통일 → 폰/터널 접속 가능)
import http from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join, extname, dirname } from "node:path";

const ROOT = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT ? Number(process.env.PORT) : 5173;
const RPC_HOST = "127.0.0.1";
const RPC_PORT = 8545;
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};

const server = http.createServer(async (req, res) => {
  // --- RPC 프록시 ---
  if (req.url === "/rpc") {
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "content-type",
      });
      res.end();
      return;
    }
    const proxy = http.request(
      { host: RPC_HOST, port: RPC_PORT, method: "POST", path: "/", headers: { "content-type": "application/json" } },
      (pr) => {
        res.writeHead(pr.statusCode || 502, { "content-type": "application/json", "Access-Control-Allow-Origin": "*" });
        pr.pipe(res);
      }
    );
    proxy.on("error", (e) => {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "RPC 연결 실패: " + e.message }));
    });
    req.pipe(proxy);
    return;
  }

  // --- 정적 파일 ---
  try {
    let path = decodeURIComponent((req.url || "/").split("?")[0]);
    if (path === "/") path = "/index.html";
    const file = join(ROOT, path);
    if (!file.startsWith(ROOT)) {
      res.writeHead(403).end("forbidden");
      return;
    }
    const data = await readFile(file);
    res.writeHead(200, { "Content-Type": MIME[extname(file)] || "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404).end("not found");
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`프론트엔드: http://localhost:${PORT}  (RPC 프록시 /rpc → ${RPC_HOST}:${RPC_PORT})`);
});
