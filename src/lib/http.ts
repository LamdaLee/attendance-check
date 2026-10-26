import "server-only";
import { NextResponse } from "next/server";
import type { ApiResult } from "./db";
import { env } from "./env";

export const STUDENT_COOKIE = "att_s";
export const OPERATOR_COOKIE = "att_o";
export const STUDENT_SESSION_SECONDS = 10 * 60;
export const OPERATOR_SESSION_SECONDS = 8 * 60 * 60;

const STATUS_BY_CODE: Record<string, number> = {
  session_expired: 401,
  invalid_credentials: 401,
  forbidden: 403,
  network_denied: 403,
  not_found: 404,
  campus_not_found: 404,
  rate_limited: 429,
  version_conflict: 409,
  request_conflict: 409,
  last_active_network: 409,
  ip_unavailable: 400,
  bad_request: 400,
  server_error: 500,
};

export function respond(result: ApiResult, init?: { cookie?: { name: string; value: string; maxAge: number } }) {
  const status = result.ok ? 200 : (STATUS_BY_CODE[result.code ?? ""] ?? 422);
  const res = NextResponse.json(result, { status });
  if (init?.cookie) {
    res.cookies.set(init.cookie.name, init.cookie.value, {
      httpOnly: true,
      secure: env.isProduction,
      sameSite: "strict",
      path: "/",
      maxAge: init.cookie.maxAge,
    });
  }
  return res;
}

export function fail(code: string) {
  return respond({ ok: false, code });
}

export function readCookie(req: Request, name: string): string | undefined {
  const header = req.headers.get("cookie");
  if (!header) return undefined;
  for (const part of header.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return decodeURIComponent(v.join("="));
  }
  return undefined;
}

// 상태를 바꾸는 요청은 같은 출처에서 온 것만 받는다(SameSite 쿠키와 함께 CSRF 방어).
export function isSameOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (!origin) return false;
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host");
  try {
    return new URL(origin).host === host;
  } catch {
    return false;
  }
}

export async function readJson<T>(req: Request): Promise<T | null> {
  try {
    return (await req.json()) as T;
  } catch {
    return null;
  }
}

export async function guarded(handler: () => Promise<Response>): Promise<Response> {
  try {
    return await handler();
  } catch (err) {
    console.error(err);
    return fail("server_error");
  }
}
