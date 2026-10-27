import { callApi } from "@/lib/db";
import { hashToken, last4Hmac, newSessionToken, normalizeName } from "@/lib/crypto";
import {
  DEVICE_COOKIE, DEVICE_COOKIE_SECONDS, STUDENT_COOKIE, STUDENT_SESSION_SECONDS, fail, guarded, isSameOrigin, readCookie,
  readJson, respond,
} from "@/lib/http";
import { getClientIp } from "@/lib/ip";

type Body = { code?: string; name?: string; last4?: string };

export async function POST(req: Request) {
  return guarded(async () => {
    if (!isSameOrigin(req)) return fail("forbidden");
    const ip = getClientIp(req);
    if (!ip) return fail("ip_unavailable");
    const body = await readJson<Body>(req);
    const name = normalizeName(body?.name ?? "");
    if (!body?.code || !name || name.length > 40 || !/^\d{4}$/.test(body.last4 ?? "")) {
      return fail("bad_request");
    }

    const token = newSessionToken();
    const existing = readCookie(req, DEVICE_COOKIE);
    const device = existing && /^[A-Za-z0-9_-]{43}$/.test(existing) ? existing : newSessionToken();
    const result = await callApi("api_student_verify", [
      body.code, name, last4Hmac(body.last4!), ip, hashToken(token), STUDENT_SESSION_SECONDS, hashToken(device),
    ]);
    if (result.code === "not_found") result.code = "student_not_found";
    return respond(result, result.ok
      ? {
          cookies: [
            { name: STUDENT_COOKIE, value: token, maxAge: STUDENT_SESSION_SECONDS },
            { name: DEVICE_COOKIE, value: device, maxAge: DEVICE_COOKIE_SECONDS },
          ],
        }
      : undefined);
  });
}
