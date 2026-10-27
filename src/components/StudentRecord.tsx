"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { CertificateOverlay, birthValid, formatBirth, type CertificateData } from "./Certificate";
import DayPanel from "./DayPanel";
import { TrainingTag } from "./RosterBoard";
import { api } from "@/lib/client";
import {
  LEAVE_STATUS_CLASS, LEAVE_STATUS_LABEL, REQUEST_STATUS_LABEL, STATUS_LABEL, formatDate, formatDateTime, formatTime, leaveText, messageFor, todayInSeoul,
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
    data.leaves.find((l) => l.startsOn <= date && date <= l.endsOn && ["registered", "submitted", "approved"].includes(l.status));
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
        <div className="stat"><span>공가 (승인 / 신청)</span><strong>{data.leaves.filter((l) => l.status === "approved").length} / {data.leaves.filter((l) => l.status !== "cancelled").length}</strong></div>
        <div className="stat"><span>지역</span><strong style={{ fontSize: 20 }}>{s.regionName}</strong></div>
      </div>

      {data.leaves.length > 0 && (
        <p className="small">
          이 달 공가:{" "}
          {data.leaves.map((l) => `${formatDate(l.startsOn)}${l.endsOn !== l.startsOn ? `~${formatDate(l.endsOn)}` : ""} ${leaveText(l)} (${LEAVE_STATUS_LABEL[l.status]})`).join(" · ")}
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
                        {l && <span className={`tag ${LEAVE_STATUS_CLASS[l.status]}`}>공가 {leaveText(l)} · {LEAVE_STATUS_LABEL[l.status]}</span>}
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

      <CertificatePanel enrollmentId={enrollmentId} />
    </>
  );
}

// 운영자 출석확인서 발급과 발급 이력
type Issued = { code: string; from: string; to: string; issuedAt: string; issuedBy: string; summary: { days: number; rate: number | null } };

function CertificatePanel({ enrollmentId }: { enrollmentId: number }) {
  const today = todayInSeoul();
  const [from, setFrom] = useState(today.slice(0, 8) + "01");
  const [to, setTo] = useState(today);
  const [birth, setBirth] = useState("");
  const [cert, setCert] = useState<CertificateData | null>(null);
  const [history, setHistory] = useState<Issued[]>([]);
  const [error, setError] = useState<string | null>(null);

  const loadHistory = useCallback(async () => {
    const r = await api(`/api/admin/certificate?enrollment=${enrollmentId}`);
    if (r.ok) setHistory(r.certificates);
  }, [enrollmentId]);

  useEffect(() => {
    void loadHistory();
  }, [loadHistory]);

  async function issue(e: React.FormEvent) {
    e.preventDefault();
    if (birth && !birthValid(birth)) {
      setError("생년월일을 8자리 숫자로 입력해 주세요. 비워 두면 빈칸으로 출력됩니다.");
      return;
    }
    setError(null);
    const r = await api("/api/admin/certificate", { enrollmentId, from, to });
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    setCert(r as unknown as CertificateData);
    await loadHistory();
  }

  return (
    <div className="panel" style={{ marginTop: 14 }}>
      <h2>출석확인서</h2>
      <p className="small">외부 기관 제출용 출석확인서를 기간을 정해 출력합니다. 생년월일은 출력에만 쓰고 저장하지 않습니다. 교육생도 휴대폰에서 직접 만들 수 있습니다.</p>
      <form className="row" onSubmit={issue}>
        <label className="field" style={{ margin: 0 }}>시작일<input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} required /></label>
        <label className="field" style={{ margin: 0 }}>종료일<input type="date" value={to} min={from} max={today} onChange={(e) => setTo(e.target.value)} required /></label>
        <label className="field" style={{ margin: 0 }}>생년월일<input value={birth} onChange={(e) => setBirth(formatBirth(e.target.value))} inputMode="numeric" placeholder="19990101" /></label>
        <button className="btn" style={{ alignSelf: "flex-end" }}>확인서 만들기</button>
      </form>
      {error && <p className="notice error">{error}</p>}
      {history.length > 0 && (
        <ul className="mini-list" style={{ marginTop: 10 }}>
          {history.map((h) => (
            <li key={h.code}>
              <span><b className="mono">{h.code}</b> · {formatDate(h.from)} ~ {formatDate(h.to)} · 수업 {h.summary.days}일 · 출석률 {h.summary.rate ?? "—"}%</span>
              <span className="small">{h.issuedBy === "본인" ? "교육생 본인" : h.issuedBy} · {formatDateTime(h.issuedAt)}</span>
            </li>
          ))}
        </ul>
      )}
      {cert && <CertificateOverlay data={cert} birth={birth} onClose={() => setCert(null)} />}
    </div>
  );
}
