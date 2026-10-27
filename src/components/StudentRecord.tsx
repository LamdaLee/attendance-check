"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import DayPanel from "./DayPanel";
import { TrainingTag } from "./RosterBoard";
import { api } from "@/lib/client";
import {
  REQUEST_STATUS_LABEL, STATUS_LABEL, formatDate, formatTime, leaveText, messageFor, todayInSeoul,
} from "@/lib/messages";

type Data = {
  student: {
    enrollmentId: number;
    name: string;
    course: string;
    status: string;
    trainingStatus: string;
    statusOn: string | null;
    regionName: string;
  };
  month: string;
  days: { date: string; status: string; firstCheckInAt: string | null; lastCheckOutAt: string | null; corrected: boolean }[];
  requests: { id: number; date: string; status: string }[];
  leaves: { id: number; startsOn: string; endsOn: string; kind: string; part: string; status: string; reason: string }[];
};

function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return d.toISOString().slice(0, 7);
}

export default function StudentRecord({ enrollmentId, initialDate }: { enrollmentId: number; initialDate?: string }) {
  const [month, setMonth] = useState((initialDate ?? todayInSeoul()).slice(0, 7));
  const [selected, setSelected] = useState<string>(initialDate ?? todayInSeoul());
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/students/${enrollmentId}?month=${month}`);
    if (!r.ok) setError(messageFor(r.code));
    else setData(r as unknown as Data);
  }, [enrollmentId, month]);

  useEffect(() => {
    void load();
  }, [load]);

  if (error) return <p className="notice error">{error}</p>;
  if (!data) return <p className="small">불러오는 중…</p>;

  const s = data.student;
  const requestByDate = new Map(data.requests.map((q) => [q.date, q]));
  const leaveOn = (date: string) =>
    data.leaves.find((l) => l.startsOn <= date && date <= l.endsOn && l.status === "registered");
  const counts = {
    days: data.days.length,
    corrected: data.days.filter((d) => d.corrected).length,
    pending: data.requests.filter((q) => q.status === "pending").length,
  };

  return (
    <>
      <div className="a-title">
        <div>
          <Link href="/admin/students" className="small">← 교육생 명단</Link>
          <h1>{s.name} <span className="scope-tag">{s.course}</span> <TrainingTag student={s} /></h1>
        </div>
        <div className="month-nav">
          <button className="btn plain sm" onClick={() => setMonth(shiftMonth(month, -1))}>‹ 이전 달</button>
          <b>{month.replace("-", "년 ")}월</b>
          <button className="btn plain sm" onClick={() => setMonth(shiftMonth(month, 1))} disabled={month >= todayInSeoul().slice(0, 7)}>다음 달 ›</button>
        </div>
      </div>

      <div className="stats" style={{ gridTemplateColumns: "repeat(5, 1fr)" }}>
        <div className="stat"><span>기록 있는 날</span><strong>{counts.days}</strong></div>
        <div className="stat"><span>정정 반영</span><strong>{counts.corrected}</strong></div>
        <div className="stat"><span>처리 대기 요청</span><strong>{counts.pending}</strong></div>
        <div className="stat"><span>공가 등록</span><strong>{data.leaves.filter((l) => l.status === "registered").length}</strong></div>
        <div className="stat"><span>지역</span><strong style={{ fontSize: 20 }}>{s.regionName}</strong></div>
      </div>

      {data.leaves.length > 0 && (
        <p className="small">
          이 달 공가:{" "}
          {data.leaves.map((l) => `${formatDate(l.startsOn)}${l.endsOn !== l.startsOn ? `~${formatDate(l.endsOn)}` : ""} ${leaveText(l)}${l.status === "cancelled" ? " (취소)" : ""}`).join(" · ")}
        </p>
      )}

      <div className="split">
        <div className="table-card">
          <div className="table-wrap">
            <table>
              <thead><tr><th>날짜</th><th>입실</th><th>퇴실</th><th>상태</th></tr></thead>
              <tbody>
                {data.days.map((d) => {
                  const q = requestByDate.get(d.date);
                  const l = leaveOn(d.date);
                  return (
                    <tr key={d.date} onClick={() => setSelected(d.date)} style={{ cursor: "pointer", background: selected === d.date ? "var(--brand-soft)" : undefined }}>
                      <td>{formatDate(d.date)}</td>
                      <td>{formatTime(d.firstCheckInAt)}</td>
                      <td>{formatTime(d.lastCheckOutAt)}</td>
                      <td>
                        <span className={`tag ${d.status}`}>{STATUS_LABEL[d.status]}</span>{" "}
                        {d.corrected && <span className="tag warn">정정</span>}{" "}
                        {q && <span className={`tag ${q.status}`}>요청 {REQUEST_STATUS_LABEL[q.status]}</span>}{" "}
                        {l && <span className="tag approved">공가 {leaveText(l)}</span>}
                      </td>
                    </tr>
                  );
                })}
                {data.days.length === 0 && <tr><td colSpan={4} className="small center">이 달의 기록이 없습니다.</td></tr>}
              </tbody>
            </table>
          </div>
          <div style={{ padding: 12 }}>
            <label className="field" style={{ margin: 0 }}>
              다른 날짜 보기 · 기록 없는 날 정정
              <input type="date" value={selected} max={todayInSeoul()} onChange={(e) => e.target.value && setSelected(e.target.value)} />
            </label>
          </div>
        </div>
        <DayPanel
          enrollmentId={enrollmentId}
          date={selected}
          requestId={requestByDate.get(selected)?.status === "pending" ? requestByDate.get(selected)!.id : null}
          onChanged={load}
        />
      </div>
    </>
  );
}
