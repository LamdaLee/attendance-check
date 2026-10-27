import { callApi } from "@/lib/db";
import { fail } from "@/lib/http";
import { isId, operatorRoute } from "@/lib/route";

// 공가 서류 열람. 운영자 세션·지역 확인과 열람 기록은 DB 함수가 한다.
export const GET = operatorRoute(async ({ token, url }) => {
  const id = Number(url.pathname.split("/").pop());
  if (!isId(id)) return fail("bad_request");
  const r = await callApi("api_operator_leave_doc", [token, id]);
  if (!r.ok) return fail(r.code ?? "not_found");
  const body = Buffer.from(String(r.data), "base64");
  return new Response(body, {
    headers: {
      "Content-Type": String(r.mime),
      // 이미지는 바로 보여 주고, PDF 는 내려받게 한다 (브라우저 PDF 보기는 격리 설정과 맞지 않는다).
      "Content-Disposition": `${r.mime === "application/pdf" ? "attachment" : "inline"}; filename*=UTF-8''${encodeURIComponent(String(r.name))}`,
      "Content-Length": String(body.length),
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      // 올린 파일이 스크립트를 실행하지 못하게 격리한다.
      "Content-Security-Policy": "sandbox; default-src 'none'; img-src 'self' data: blob:; style-src 'unsafe-inline'; object-src 'self'",
    },
  });
});
