import { callApi } from "@/lib/db";
import { hashToken } from "@/lib/crypto";
import { OPERATOR_COOKIE, fail, guarded, readCookie, respond } from "@/lib/http";
import { getClientIp } from "@/lib/ip";

// "현재 접속 IP 확인": 서버가 보는 주소를 그대로 보여준다. 자동 등록하지 않는다.
export async function GET(req: Request) {
  return guarded(async () => {
    const token = readCookie(req, OPERATOR_COOKIE);
    if (!token) return fail("session_expired");
    const me = await callApi("api_operator_me", [hashToken(token)]);
    if (!me.ok) return respond(me);
    const ip = getClientIp(req);
    if (!ip) return fail("ip_unavailable");
    return respond({ ok: true, ip });
  });
}
