import "server-only";
import { hashToken } from "./crypto";
import { OPERATOR_COOKIE, STUDENT_COOKIE, fail, guarded, isSameOrigin, readCookie } from "./http";

type Ctx = { token: Buffer; url: URL; req: Request };

// 운영자 API 공통: 쿠키 세션 확인, 상태 변경 요청은 같은 출처만
export function operatorRoute(handler: (ctx: Ctx) => Promise<Response>, opts: { mutation?: boolean } = {}) {
  return (req: Request) =>
    guarded(async () => {
      if (opts.mutation && !isSameOrigin(req)) return fail("forbidden");
      const raw = readCookie(req, OPERATOR_COOKIE);
      if (!raw) return fail("session_expired");
      return handler({ token: hashToken(raw), url: new URL(req.url), req });
    });
}

export function studentRoute(handler: (ctx: Ctx) => Promise<Response>, opts: { mutation?: boolean } = {}) {
  return (req: Request) =>
    guarded(async () => {
      if (opts.mutation && !isSameOrigin(req)) return fail("forbidden");
      const raw = readCookie(req, STUDENT_COOKIE);
      if (!raw) return fail("session_expired");
      return handler({ token: hashToken(raw), url: new URL(req.url), req });
    });
}

export const isDate = (v: unknown): v is string => typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v);
export const isId = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v > 0;

export function param(url: URL, name: string): string | null {
  const v = url.searchParams.get(name);
  return v === null || v === "" ? null : v;
}
