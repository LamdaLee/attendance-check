import "server-only";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { env } from "./env";

export function newSessionToken(): string {
  return randomBytes(32).toString("base64url");
}

// DB에는 토큰 원문이 아닌 해시만 저장한다.
export function hashToken(token: string): Buffer {
  return createHash("sha256").update(token).digest();
}

// 명단 등록(scripts/admin.mjs)과 같은 규칙이어야 한다.
export function normalizeName(name: string): string {
  return name.normalize("NFC").replace(/\s+/g, "");
}

export function last4Hmac(last4: string): string {
  return createHmac("sha256", env.studentMatchSecret).update(last4).digest("hex");
}
