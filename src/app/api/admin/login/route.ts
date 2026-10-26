import { callApi } from "@/lib/db";
import { hashToken, newSessionToken } from "@/lib/crypto";
import { OPERATOR_COOKIE, OPERATOR_SESSION_SECONDS, fail, guarded, isSameOrigin, readJson, respond } from "@/lib/http";
import { getClientIp } from "@/lib/ip";

type Body = { scope?: string; password?: string; operatorName?: string };

export async function POST(req: Request) {
  return guarded(async () => {
    if (!isSameOrigin(req)) return fail("forbidden");
    // 운영자 화면은 교육장 IP 제한을 두지 않는다. IP는 시도 횟수 제한에만 쓴다.
    const ip = getClientIp(req);
    if (!ip) return fail("ip_unavailable");
    const body = await readJson<Body>(req);
    if (!body?.scope || !body.password || (body.operatorName ?? "").length > 40) return fail("bad_request");

    const token = newSessionToken();
    const result = await callApi("api_operator_login", [
      body.scope, body.password, body.operatorName ?? "", ip, hashToken(token), OPERATOR_SESSION_SECONDS,
    ]);
    return respond(result, result.ok
      ? { cookie: { name: OPERATOR_COOKIE, value: token, maxAge: OPERATOR_SESSION_SECONDS } }
      : undefined);
  });
}
