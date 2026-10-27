import { callApi } from "@/lib/db";
import { fail, guarded, respond } from "@/lib/http";

// 교육장 지역의 학생 화면 바로가기 (본인 확인 전에도 보임, 개인정보 없음)
export async function GET(_req: Request, { params }: { params: Promise<{ code: string }> }) {
  return guarded(async () => {
    const { code } = await params;
    if (!code || code.length > 64) return fail("bad_request");
    return respond(await callApi("api_campus_links", [code]));
  });
}
