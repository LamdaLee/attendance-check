import { callApi } from "@/lib/db";
import { guarded, respond } from "@/lib/http";
import { getClientIp } from "@/lib/ip";

// 첫 화면: 지금 접속한 회선이 어느 교육장인지와 교육장 목록 (개인정보 없음)
export async function GET(req: Request) {
  return guarded(async () => respond(await callApi("api_entry", [getClientIp(req)])));
}
