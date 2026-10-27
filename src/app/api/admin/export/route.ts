import { callApi } from "@/lib/db";
import { fail, respond } from "@/lib/http";
import { ACTION_LABEL, STATUS_LABEL, formatTime } from "@/lib/messages";
import { isDate, operatorRoute, param } from "@/lib/route";

type Row = {
  date: string;
  name: string;
  course: string;
  status: string;
  firstCheckInAt: string | null;
  lastCheckOutAt: string | null;
  corrected: boolean;
  timeline: { action: string; at: string; source?: string }[];
};

function cell(value: string): string {
  // 엑셀 수식으로 해석되지 않게 하고, 쉼표·따옴표를 감싼다.
  const safe = /^[=+\-@]/.test(value) ? `'${value}` : value;
  return /[",\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

// 기간 출결 CSV. 내보낸 사실은 DB 함수가 변경 이력에 남긴다.
export const GET = operatorRoute(async ({ token, url }) => {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  if (!isDate(from) || !isDate(to)) return fail("bad_request");
  const region = param(url, "region");
  const res = await callApi("api_operator_export", [token, region, from, to]);
  if (!res.ok) return respond(res);

  const header = ["날짜", "교육생", "과정", "최종 상태", "입실", "퇴실", "정정 반영", "기록 상세"];
  const lines = (res.rows as Row[]).map((r) =>
    [
      r.date, r.name, r.course, STATUS_LABEL[r.status] ?? r.status,
      formatTime(r.firstCheckInAt), formatTime(r.lastCheckOutAt), r.corrected ? "예" : "",
      r.timeline.map((t) => `${formatTime(t.at)} ${ACTION_LABEL[t.action]}${t.source === "corrected" ? "(정정)" : ""}`).join(" / "),
    ].map(cell).join(","),
  );
  const meta = `# ${res.regionName} 출결 ${from}~${to} · 생성 ${new Date(res.generatedAt as string).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })} · 보조 출결 자료`;
  const csv = "﻿" + [meta, header.join(","), ...lines].join("\r\n") + "\r\n";
  return new Response(csv, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="attendance_${region ?? "region"}_${from}_${to}.csv"`,
      "Cache-Control": "no-store",
    },
  });
});
