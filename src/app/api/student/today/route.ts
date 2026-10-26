import { callApi } from "@/lib/db";
import { hashToken } from "@/lib/crypto";
import { STUDENT_COOKIE, fail, guarded, readCookie, respond } from "@/lib/http";

export async function GET(req: Request) {
  return guarded(async () => {
    const token = readCookie(req, STUDENT_COOKIE);
    if (!token) return fail("session_expired");
    return respond(await callApi("api_student_today", [hashToken(token)]));
  });
}
