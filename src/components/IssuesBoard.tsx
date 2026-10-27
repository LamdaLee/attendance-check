"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import { ACTION_LABEL, ISSUE_LABEL, REQUEST_STATUS_LABEL, addDays, formatDate, formatTime, messageFor, todayInSeoul } from "@/lib/messages";

type Item = {
  date: string;
  enrollmentId: number;
  name: string;
  course: string;
  kind: keyof typeof ISSUE_LABEL;
  lastAction: string | null;
  lastEventAt: string | null;
  requestStatus: string | null;
};

export default function IssuesBoard() {
  const { region } = useOperator();
  const yesterday = addDays(todayInSeoul(), -1);
  const [from, setFrom] = useState(addDays(yesterday, -6));
  const [to, setTo] = useState(yesterday);
  const [kind, setKind] = useState("");
  const [items, setItems] = useState<Item[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/issues?region=${encodeURIComponent(region)}&from=${from}&to=${to}`);
    if (!r.ok) setError(messageFor(r.code));
    else {
      setItems(r.items);
      setError(null);
    }
  }, [region, from, to]);

  useEffect(() => {
    setItems(null);
    void load();
  }, [load]);

  const filtered = useMemo(() => (items ?? []).filter((i) => !kind || i.kind === kind), [items, kind]);
  const count = (k: string) => (items ?? []).filter((i) => i.kind === k).length;

  return (
    <>
      <div className="a-title">
        <div>
          <h1>누락 확인</h1>
          <span className="small">지난 날짜 중 확인이 필요한 기록입니다. 결석이나 조퇴로 단정하지 않습니다. 오늘은 포함하지 않습니다.</span>
        </div>
      </div>
      <div className="filters">
        <label className="field">시작일<input type="date" value={from} max={to} onChange={(e) => e.target.value && setFrom(e.target.value)} /></label>
        <label className="field">종료일<input type="date" value={to} max={yesterday} onChange={(e) => e.target.value && setTo(e.target.value)} /></label>
        <label className="field">
          구분
          <select value={kind} onChange={(e) => setKind(e.target.value)}>
            <option value="">전체</option>
            {Object.entries(ISSUE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </label>
      </div>
      {error && <p className="notice error">{error}</p>}
      <div className="stats" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
        {Object.entries(ISSUE_LABEL).map(([k, v]) => <div className="stat" key={k}><span>{v}</span><strong>{count(k)}</strong></div>)}
      </div>
      <div className="table-card">
        <div className="table-wrap">
          <table>
            <thead><tr><th>날짜</th><th>이름</th><th>과정</th><th>확인 사항</th><th>마지막 기록</th><th>정정 요청</th><th></th></tr></thead>
            <tbody>
              {filtered.map((i) => (
                <tr key={`${i.date}-${i.enrollmentId}-${i.kind}`}>
                  <td>{formatDate(i.date)}</td>
                  <td><b>{i.name}</b></td>
                  <td>{i.course}</td>
                  <td><span className={`tag ${i.kind === "no_record" ? "" : "warn"}`}>{ISSUE_LABEL[i.kind]}</span></td>
                  <td className="small">{i.lastAction ? `${formatTime(i.lastEventAt)} ${ACTION_LABEL[i.lastAction]}` : "—"}</td>
                  <td>{i.requestStatus ? <span className={`tag ${i.requestStatus}`}>{REQUEST_STATUS_LABEL[i.requestStatus]}</span> : "—"}</td>
                  <td><Link className="btn plain sm" href={`/admin/students/${i.enrollmentId}?date=${i.date}`}>확인 · 정정</Link></td>
                </tr>
              ))}
              {items && filtered.length === 0 && <tr><td colSpan={7} className="small center">확인할 항목이 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      <p className="small">“기록 없음”은 같은 과정의 다른 교육생 기록이 있는 날인데 기록이 하나도 없는 경우입니다.</p>
    </>
  );
}
