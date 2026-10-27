"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import { NOTICE_LABEL, addDays, formatDate, formatDateTime, messageFor, todayInSeoul } from "@/lib/messages";

type Notice = {
  id: number;
  date: string;
  enrollmentId: number;
  name: string;
  course: string;
  kind: string;
  expectedTime: string | null;
  reason: string;
  status: string;
  createdAt: string;
};

export default function NoticesBoard() {
  const { region } = useOperator();
  const today = todayInSeoul();
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(addDays(today, 14));
  const [showCancelled, setShowCancelled] = useState(false);
  const [items, setItems] = useState<Notice[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/notices?region=${encodeURIComponent(region)}&from=${from}&to=${to}`);
    if (!r.ok) setError(messageFor(r.code));
    else {
      setItems(r.notices);
      setError(null);
    }
  }, [region, from, to]);

  useEffect(() => {
    setItems(null);
    void load();
  }, [load]);

  const filtered = useMemo(() => (items ?? []).filter((n) => showCancelled || n.status === "submitted"), [items, showCancelled]);
  const todayCount = (k: string) => (items ?? []).filter((n) => n.date === today && n.kind === k && n.status === "submitted").length;

  return (
    <>
      <div className="a-title">
        <div>
          <h1>사전 알림</h1>
          <span className="small">교육생이 미리 보낸 지각·결석·조퇴 예정 알림입니다. 출결 기록을 바꾸지 않는 안내 정보입니다.</span>
        </div>
      </div>
      <div className="stats" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
        {Object.entries(NOTICE_LABEL).map(([k, v]) => <div className="stat" key={k}><span>오늘 {v}</span><strong>{todayCount(k)}</strong></div>)}
      </div>
      <div className="filters">
        <label className="field">시작일<input type="date" value={from} max={to} onChange={(e) => e.target.value && setFrom(e.target.value)} /></label>
        <label className="field">종료일<input type="date" value={to} min={from} onChange={(e) => e.target.value && setTo(e.target.value)} /></label>
        <label className="field" style={{ flex: "0 0 auto" }}>
          <span className="row" style={{ marginTop: 22 }}>
            <input type="checkbox" checked={showCancelled} onChange={(e) => setShowCancelled(e.target.checked)} style={{ width: "auto", margin: 0 }} />
            취소된 알림도 보기
          </span>
        </label>
      </div>
      {error && <p className="notice error">{error}</p>}
      <div className="table-card">
        <div className="table-wrap">
          <table>
            <thead><tr><th>날짜</th><th>이름</th><th>과정</th><th>구분</th><th>예정 시각</th><th>사유</th><th>보낸 시각</th></tr></thead>
            <tbody>
              {filtered.map((n) => (
                <tr key={n.id} style={n.status === "cancelled" ? { opacity: 0.5 } : undefined}>
                  <td>{formatDate(n.date)}</td>
                  <td><Link href={`/admin/students/${n.enrollmentId}?date=${n.date}`}><b>{n.name}</b></Link></td>
                  <td>{n.course}</td>
                  <td>
                    <span className={`tag ${n.kind === "absent" ? "danger" : "warn"}`}>{NOTICE_LABEL[n.kind]}</span>
                    {n.status === "cancelled" && <span className="tag"> 취소됨</span>}
                  </td>
                  <td>{n.expectedTime ?? "—"}</td>
                  <td style={{ whiteSpace: "normal", minWidth: 200 }}>{n.reason}</td>
                  <td className="small">{formatDateTime(n.createdAt)}</td>
                </tr>
              ))}
              {items && filtered.length === 0 && <tr><td colSpan={7} className="small center">알림이 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
