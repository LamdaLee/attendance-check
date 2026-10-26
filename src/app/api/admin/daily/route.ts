import { callApi } from "@/lib/db";
import { hashToken } from "@/lib/crypto";
import { OPERATOR_COOKIE, fail, guarded, readCookie, respond } from "@/lib/http";

export async function GET(req: Request) {
  return guarded(async () => {
    const token = readCookie(req, OPERATOR_COOKIE);
    if (!token) return fail("session_expired");
    const url = new URL(req.url);
    const date = url.searchParams.get("date") ?? "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return fail("bad_request");
    // 지역 값은 참고용이다. 지역 운영자는 DB 함수에서 자기 지역으로 고정된다.
    const region = url.searchParams.get("region");
    return respond(await callApi("api_operator_daily", [hashToken(token), region, date]));
  });
}
