"use client";

import { useCallback, useEffect, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import { AUDIT_ACTION_LABEL, formatDateTime, messageFor } from "@/lib/messages";

type Entry = {
  id: number;
  createdAt: string;
  regionName: string | null;
  actorScope: string;
  actorName: string;
  action: string;
  targetTable: string;
  targetId: string | null;
  reason: string | null;
  before: unknown;
  after: unknown;
};

const SCOPE_LABEL: Record<string, string> = { region: "지역 운영자", super: "총괄", script: "관리 스크립트" };

function summary(e: Entry): string {
  const a = e.after as Record<string, unknown> | null;
  const b = e.before as Record<string, unknown> | null;
  if (e.action.startsWith("network.") && a) return `${a.label ?? ""} ${String(a.network ?? "").replace(/\/(32|128)$/, "")} · ${b?.status ? `${b.status} → ` : ""}${a.status}`;
  if (e.action === "students.import" && a) return `${a.count}명: ${((a.names as string[]) ?? []).slice(0, 5).join(", ")}${(a.count as number) > 5 ? " …" : ""}`;
  if (e.action === "enrollment.update" && a) return `상태 ${b?.status} → ${a.status}${a.last4Changed ? " · 뒷자리 재등록" : ""}`;
  if (e.action === "export.csv" && a) return `${a.from} ~ ${a.to} · ${a.rows}행`;
  if (e.action.startsWith("correction.") && a && "date" in a) return `${a.date} 기록`;
  return "";
}

export default function AuditBoard() {
  const { operator, region } = useOperator();
  const [allRegions, setAllRegions] = useState(false);
  const [items, setItems] = useState<Entry[] | null>(null);
  const [more, setMore] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchPage = useCallback(
    async (before?: number) => {
      const scope = operator.scope === "super" && allRegions ? "" : region;
      const r = await api(`/api/admin/audit?region=${encodeURIComponent(scope)}${before ? `&before=${before}` : ""}`);
      if (!r.ok) {
        setError(messageFor(r.code));
        return;
      }
      setItems((prev) => (before ? [...(prev ?? []), ...r.items] : r.items));
      setMore(r.items.length === 50);
    },
    [operator.scope, allRegions, region],
  );

  useEffect(() => {
    setItems(null);
    void fetchPage();
  }, [fetchPage]);

  return (
    <>
      <div className="a-title">
        <div>
          <h1>변경 이력</h1>
          <span className="small">허용 IP, 명단, 정정, 비밀번호, 자료 내보내기 등 운영 변경을 남깁니다. 지울 수 없습니다.</span>
        </div>
        {operator.scope === "super" && (
          <label className="row small">
            <input type="checkbox" checked={allRegions} onChange={(e) => setAllRegions(e.target.checked)} /> 전체 지역 보기
          </label>
        )}
      </div>
      {error && <p className="notice error">{error}</p>}
      <div className="table-card">
        <div className="table-wrap">
          <table>
            <thead><tr><th>시각</th><th>지역</th><th>처리자</th><th>구분</th><th>내용</th><th>사유</th></tr></thead>
            <tbody>
              {items?.map((e) => (
                <tr key={e.id}>
                  <td className="small">{formatDateTime(e.createdAt)}</td>
                  <td>{e.regionName ?? "—"}</td>
                  <td>{e.actorName} <span className="small">{SCOPE_LABEL[e.actorScope] ?? e.actorScope}</span></td>
                  <td><span className="tag brand">{AUDIT_ACTION_LABEL[e.action] ?? e.action}</span></td>
                  <td style={{ whiteSpace: "normal", minWidth: 220 }}>
                    {summary(e)}
                    <details>
                      <summary className="small">상세</summary>
                      <pre className="json">{JSON.stringify({ 변경전: e.before, 변경후: e.after }, null, 1)}</pre>
                    </details>
                  </td>
                  <td style={{ whiteSpace: "normal" }}>{e.reason ?? "—"}</td>
                </tr>
              ))}
              {items?.length === 0 && <tr><td colSpan={6} className="small center">이력이 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      {items && more && items.length > 0 && (
        <button className="btn plain block" style={{ marginTop: 12 }} onClick={() => fetchPage(items[items.length - 1].id)}>더 보기</button>
      )}
    </>
  );
}
