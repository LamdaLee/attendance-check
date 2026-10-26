import { callApi } from "@/lib/db";
import { hashToken } from "@/lib/crypto";
import { OPERATOR_COOKIE, fail, guarded, isSameOrigin, readCookie, respond } from "@/lib/http";

export async function POST(req: Request) {
  return guarded(async () => {
    if (!isSameOrigin(req)) return fail("forbidden");
    const token = readCookie(req, OPERATOR_COOKIE);
    if (token) await callApi("api_session_revoke", [hashToken(token)]);
    return respond({ ok: true }, { cookie: { name: OPERATOR_COOKIE, value: "", maxAge: 0 } });
  });
}
