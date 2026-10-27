import "server-only";
import { NextResponse } from "next/server";
import type { ApiResult } from "./db";
import { env } from "./env";

export const STUDENT_COOKIE = "att_s";
export const OPERATOR_COOKIE = "att_o";
// 같은 기기에서 여러 명이 출결했는지 보기 위한 브라우저 표시 (개인을 식별하지 않는 무작위 값)
export const DEVICE_COOKIE = "att_d";
export const DEVICE_COOKIE_SECONDS = 365 * 24 * 60 * 60;
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
  invalid_code: 422,
  presence_required: 403,
  code_inactive: 422,
  ip_unavailable: 400,
  bad_request: 400,
  server_error: 500,
};

type Cookie = { name: string; value: string; maxAge: number };

export function respond(result: ApiResult, init?: { cookie?: Cookie; cookies?: Cookie[] }) {
  const status = result.ok ? 200 : (STATUS_BY_CODE[result.code ?? ""] ?? 422);
  const res = NextResponse.json(result, { status });
  for (const c of [...(init?.cookie ? [init.cookie] : []), ...(init?.cookies ?? [])]) {
    res.cookies.set(c.name, c.value, {
      httpOnly: true,
      secure: env.isProduction,
      sameSite: "strict",
      path: "/",
      maxAge: c.maxAge,
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
