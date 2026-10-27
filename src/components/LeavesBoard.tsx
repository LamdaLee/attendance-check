"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import {
  LEAVE_KIND_LABEL, LEAVE_PART_LABEL, LEAVE_STATUS_LABEL, addDays, formatDate, formatDateTime, messageFor, todayInSeoul,
} from "@/lib/messages";

type Leave = {
  id: number;
  enrollmentId: number;
  name: string;
  course: string;
  startsOn: string;
  endsOn: string;
  kind: string;
  part: string;
  reason: string;
  status: string;
  createdBy: "student" | "operator";
  createdName: string | null;
  createdAt: string;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancelNote: string | null;
  version: number;
};
type Student = { enrollmentId: number; name: string; course: string; trainingStatus: string };


export default function LeavesBoard() {
  const { region } = useOperator();
  const today = todayInSeoul();
  const [from, setFrom] = useState(addDays(today, -7));
  const [to, setTo] = useState(addDays(today, 21));
  const [filter, setFilter] = useState("registered");
  const [items, setItems] = useState<Leave[] | null>(null);
  const [adding, setAdding] = useState(false);
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/leaves?region=${encodeURIComponent(region)}&from=${from}&to=${to}`);
    if (!r.ok) setMessage({ kind: "error", text: messageFor(r.code) });
    else setItems(r.leaves);
  }, [region, from, to]);

  useEffect(() => {
    setItems(null);
    void load();
  }, [load]);

  const filtered = useMemo(() => (items ?? []).filter((l) => !filter || l.status === filter), [items, filter]);
  const count = (s: string) => (items ?? []).filter((l) => l.status === s).length;
  const active = (items ?? []).filter((l) => l.status === "registered");
  const onToday = active.filter((l) => l.startsOn <= today && today <= l.endsOn).length;
  const upcoming = active.filter((l) => l.startsOn > today).length;

  async function cancel(l: Leave) {
    const note = window.prompt(`${l.name} · ${LEAVE_KIND_LABEL[l.kind]} 공가를 취소합니다. 취소 사유를 적어 주세요. (교육생에게 보입니다)`);
    if (note === null) return;
    const r = await api("/api/admin/leaves", { action: "cancel", id: l.id, note, version: l.version });
    if (!r.ok) setMessage({ kind: "error", text: messageFor(r.code) });
    else setMessage({ kind: "ok", text: `${l.name} 공가를 취소했습니다.` });
    await load();
  }

  return (
    <>
      <div className="a-title">
        <div>
          <h1>공가</h1>
          <span className="small">병결·면접·예비군 등 공가 일정입니다. 교육생이 휴대폰으로 등록하거나 운영자가 대신 등록합니다. 증빙 서류는 LMS에 직접 올립니다.</span>
        </div>
        <button className="btn" onClick={() => { setAdding(true); setMessage(null); }}>공가 등록</button>
      </div>

      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      {adding && <AddLeave region={region} onDone={async (t) => { setAdding(false); setMessage({ kind: "ok", text: t }); await load(); }} onCancel={() => setAdding(false)} />}

      <div className="stats">
        <div className="stat"><span>오늘 공가</span><strong>{onToday}</strong></div>
        <div className="stat"><span>예정 공가</span><strong>{upcoming}</strong></div>
        <div className="stat"><span>기간 내 등록</span><strong>{count("registered")}</strong></div>
        <div className="stat"><span>취소</span><strong>{count("cancelled")}</strong></div>
      </div>

      <div className="filters">
        <label className="field">시작일<input type="date" value={from} max={to} onChange={(e) => e.target.value && setFrom(e.target.value)} /></label>
        <label className="field">종료일<input type="date" value={to} min={from} onChange={(e) => e.target.value && setTo(e.target.value)} /></label>
        <label className="field">
          상태
          <select value={filter} onChange={(e) => setFilter(e.target.value)}>
            {Object.entries(LEAVE_STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            <option value="">전체</option>
          </select>
        </label>
      </div>

      <div className="table-card">
        <div className="table-wrap">
          <table>
            <thead><tr><th>기간</th><th>이름</th><th>과정</th><th>구분</th><th>사유</th><th>등록</th><th>상태</th><th /></tr></thead>
            <tbody>
              {filtered.map((l) => (
                <tr key={l.id}>
                  <td>{formatDate(l.startsOn)}{l.endsOn !== l.startsOn && <><br />~ {formatDate(l.endsOn)}</>}</td>
                  <td><Link href={`/admin/students/${l.enrollmentId}?date=${l.startsOn}`}><b>{l.name}</b></Link></td>
                  <td>{l.course}</td>
                  <td>{LEAVE_KIND_LABEL[l.kind]}<br /><span className="small">{LEAVE_PART_LABEL[l.part]}</span></td>
                  <td style={{ whiteSpace: "normal", minWidth: 200 }}>
                    {l.reason}
                    {l.cancelNote && <div className="small">취소 사유: {l.cancelNote}</div>}
                  </td>
                  <td className="small">{l.createdBy === "student" ? "교육생" : `운영자 ${l.createdName ?? ""}`}<br />{formatDateTime(l.createdAt)}</td>
                  <td>
                    <span className={`tag ${l.status === "registered" ? "approved" : "rejected"}`}>{LEAVE_STATUS_LABEL[l.status]}</span>
                    {l.cancelledBy && <div className="small">{l.cancelledBy}</div>}
                  </td>
                  <td>{l.status === "registered" && <button className="btn plain sm" onClick={() => cancel(l)}>취소</button>}</td>
                </tr>
              ))}
              {items && filtered.length === 0 && <tr><td colSpan={8} className="small center">해당하는 공가가 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      <p className="small">등록된 공가는 출결 일보에 바로 반영됩니다(하루 전체 공가는 결석, 일부 시간 공가는 지각·조퇴를 공가로 표시). 운영자 등록과 취소는 변경 이력에 남습니다.</p>
    </>
  );
}

function AddLeave({ region, onDone, onCancel }: { region: string; onDone: (t: string) => void; onCancel: () => void }) {
  const today = todayInSeoul();
  const [students, setStudents] = useState<Student[]>([]);
  const [enrollmentId, setEnrollmentId] = useState<number | "">("");
  const [kind, setKind] = useState("sick");
  const [part, setPart] = useState("full");
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(today);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api(`/api/admin/students?region=${encodeURIComponent(region)}`).then((r) => {
      if (r.ok) setStudents((r.students as Student[]).filter((s) => s.trainingStatus === "training"));
    });
  }, [region]);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!enrollmentId) return;
    const r = await api("/api/admin/leaves", { action: "create", enrollmentId, from, to: to < from ? from : to, kind, part, reason });
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    const name = students.find((s) => s.enrollmentId === enrollmentId)?.name ?? "";
    onDone(`${name} 공가를 등록했습니다.`);
  }

  return (
    <form className="panel" onSubmit={save}>
      <h2>공가 등록</h2>
      <div className="grid-2" style={{ gridTemplateColumns: "2fr 1fr 1fr 1fr 1fr" }}>
        <label className="field">
          교육생
          <select value={enrollmentId} onChange={(e) => setEnrollmentId(e.target.value ? Number(e.target.value) : "")} required>
            <option value="">선택</option>
            {students.map((s) => <option key={s.enrollmentId} value={s.enrollmentId}>{s.course} · {s.name}</option>)}
          </select>
        </label>
        <label className="field">
          구분
          <select value={kind} onChange={(e) => setKind(e.target.value)}>
            {Object.entries(LEAVE_KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </label>
        <label className="field">
          시간
          <select value={part} onChange={(e) => setPart(e.target.value)}>
            {Object.entries(LEAVE_PART_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </label>
        <label className="field">시작일<input type="date" value={from} onChange={(e) => { setFrom(e.target.value); if (to < e.target.value) setTo(e.target.value); }} required /></label>
        <label className="field">종료일<input type="date" value={to} min={from} max={addDays(from, 13)} onChange={(e) => setTo(e.target.value)} required /></label>
      </div>
      <label className="field">
        사유
        <input value={reason} onChange={(e) => setReason(e.target.value)} required maxLength={300} placeholder="예: 예비군 동원훈련" />
      </label>
      {error && <p className="notice error">{error}</p>}
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn plain" onClick={onCancel}>취소</button>
        <button className="btn">등록</button>
      </div>
    </form>
  );
}
