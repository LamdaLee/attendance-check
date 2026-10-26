"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { ACTION_LABEL, STATUS_LABEL, formatTime, messageFor, todayInSeoul } from "@/lib/messages";

type Row = {
  enrollmentId: number;
  name: string;
  course: string;
  status: keyof typeof STATUS_LABEL;
  firstCheckInAt: string | null;
  lastCheckOutAt: string | null;
  lastAction: string | null;
  lastEventAt: string | null;
};

const REFRESH_MS = 15_000;
const STATUS_ORDER = ["in_class", "out", "checked_out", "not_in"] as const;

export default function DailyBoard() {
  const { operator, region } = useOperator();
  const [date, setDate] = useState(todayInSeoul());
  const [course, setCourse] = useState("");
  const [status, setStatus] = useState("");
  const [query, setQuery] = useState("");
  const [rows, setRows] = useState<Row[] | null>(null);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);
  const [failed, setFailed] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await fetch(`/api/admin/daily?region=${encodeURIComponent(region)}&date=${date}`, { cache: "no-store" });
      const r = await res.json();
      if (!r.ok) {
        if (r.code === "session_expired") window.location.replace("/admin");
        setFailed(messageFor(r.code));
        return;
      }
      setRows(r.rows);
      setUpdatedAt(new Date());
      setFailed(null);
    } catch {
      setFailed("갱신에 실패했습니다. 아래 자료는 최신이 아닐 수 있습니다.");
    }
  }, [region, date]);

  useEffect(() => {
    setRows(null);
    void load();
    const isToday = date === todayInSeoul();
    if (!isToday) return;
    const t = setInterval(load, REFRESH_MS);
    return () => clearInterval(t);
  }, [load, date]);

  const courses = useMemo(() => [...new Set((rows ?? []).map((r) => r.course))], [rows]);
  const filtered = useMemo(
    () =>
      (rows ?? []).filter(
        (r) => (!course || r.course === course) && (!status || r.status === status) && (!query || r.name.includes(query.trim())),
      ),
    [rows, course, status, query],
  );
  const counts = useMemo(() => {
    const base = Object.fromEntries(STATUS_ORDER.map((s) => [s, 0])) as Record<string, number>;
    for (const r of (rows ?? []).filter((r) => !course || r.course === course)) base[r.status]++;
    return base;
  }, [rows, course]);

  const regionName = operator.regions.find((r) => r.code === region)?.name ?? "";

  return (
    <>
      <div className="a-title">
        <div>
          <h1>{date === todayInSeoul() ? "오늘의 출결" : `${date} 출결`}</h1>
          <span className={`small${failed ? " no-print" : ""}`} style={failed ? { color: "var(--danger)" } : undefined}>
            {failed ?? (updatedAt ? `마지막 갱신 ${formatTime(updatedAt.toISOString(), true)}${date === todayInSeoul() ? " · 15초 자동 갱신" : ""}` : "불러오는 중…")}
          </span>
        </div>
        <button className="btn ghost no-print" onClick={() => window.print()}>캡처 · 인쇄</button>
      </div>

      <div className="print-meta">
        {regionName} · 대상일 {date} · 과정 {course || "전체"} · 상태 {status ? STATUS_LABEL[status] : "전체"}
        {query && ` · 이름 “${query}”`}<br />
        자료 생성 {updatedAt ? updatedAt.toLocaleString("ko-KR", { timeZone: "Asia/Seoul" }) : "—"} 한국시간 · 원본 기록 기준 ·
        보조 출결 자료이며 공식 LMS의 출석 인정 판정을 대신하지 않습니다.
      </div>

      <div className="filters">
        <label className="field">날짜<input type="date" value={date} onChange={(e) => e.target.value && setDate(e.target.value)} /></label>
        <label className="field">
          과정
          <select value={course} onChange={(e) => setCourse(e.target.value)}>
            <option value="">전체 과정</option>
            {courses.map((c) => <option key={c}>{c}</option>)}
          </select>
        </label>
        <label className="field">
          상태
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">전체 상태</option>
            {STATUS_ORDER.map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
          </select>
        </label>
        <label className="field">이름<input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="이름 검색" /></label>
      </div>

      <div className="stats">
        {STATUS_ORDER.map((s) => (
          <div className="stat" key={s}><span>{STATUS_LABEL[s]}</span><strong>{counts[s]}</strong></div>
        ))}
      </div>

      <div className="table-card">
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>이름</th><th>과정</th><th>입실</th><th>현재 상태</th><th>최근 기록</th><th>퇴실</th></tr>
            </thead>
            <tbody>
              {filtered.map((r) => (
                <tr key={r.enrollmentId}>
                  <td><b>{r.name}</b></td>
                  <td>{r.course}</td>
                  <td>{formatTime(r.firstCheckInAt)}</td>
                  <td><span className={`tag ${r.status}`}>{STATUS_LABEL[r.status]}</span></td>
                  <td>{r.lastAction ? `${formatTime(r.lastEventAt)} ${ACTION_LABEL[r.lastAction]}` : "—"}</td>
                  <td>{formatTime(r.lastCheckOutAt)}</td>
                </tr>
              ))}
              {rows && filtered.length === 0 && (
                <tr><td colSpan={6} className="small center">조건에 맞는 교육생이 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
      <p className="small">미입실은 공식 결석 판정이 아닙니다. 전화번호 뒷자리는 화면과 출력물에 표시하지 않습니다.</p>
    </>
  );
}
