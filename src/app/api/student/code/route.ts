import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { getClientIp } from "@/lib/ip";
import { studentRoute } from "@/lib/route";

// 오늘의 출석코드로 현장 확인
export const POST = studentRoute(
  async ({ token, req }) => {
    const ip = getClientIp(req);
    if (!ip) return fail("ip_unavailable");
    const body = await readJson<{ code?: string }>(req);
    const code = (body?.code ?? "").replace(/\s/g, "");
    if (!/^\d{6}$/.test(code)) return fail("invalid_code");
    return respond(await callApi("api_student_code", [token, code, ip]));
  },
  { mutation: true },
);
