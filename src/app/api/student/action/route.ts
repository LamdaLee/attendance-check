import { callApi } from "@/lib/db";
import { hashToken } from "@/lib/crypto";
import { STUDENT_COOKIE, fail, guarded, isSameOrigin, readCookie, readJson, respond } from "@/lib/http";
import { getClientIp } from "@/lib/ip";

const ACTIONS = new Set(["check_in", "go_out", "return", "check_out"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Body = { action?: string; requestId?: string };

export async function POST(req: Request) {
  return guarded(async () => {
    if (!isSameOrigin(req)) return fail("forbidden");
    const token = readCookie(req, STUDENT_COOKIE);
    if (!token) return fail("session_expired");
    const ip = getClientIp(req);
    if (!ip) return fail("ip_unavailable");
    const body = await readJson<Body>(req);
    if (!body?.action || !ACTIONS.has(body.action) || !UUID.test(body.requestId ?? "")) {
      return fail("bad_request");
    }
    // 시각은 DB 서버 시각으로 기록한다. 클라이언트가 보낸 시각은 받지 않는다.
    return respond(await callApi("api_student_action", [hashToken(token), body.action, body.requestId, ip]));
  });
}
