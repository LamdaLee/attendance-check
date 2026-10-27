"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import {
  LEAVE_KIND_LABEL, LEAVE_PART_LABEL, LEAVE_STATUS_CLASS, LEAVE_STATUS_LABEL, addDays, formatDate, formatDateTime, messageFor, todayInSeoul,
} from "@/lib/messages";

type Doc = { id: number; name: string; mime: string; size: number; uploadedAt: string };
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
  decidedAt: string | null;
  decidedBy: string | null;
  decisionNote: string | null;
  cancelledBy: string | null;
  cancelNote: string | null;
  version: number;
  docs: Doc[];
};
type Student = { enrollmentId: number; name: string; course: string; trainingStatus: string };

const kb = (n: number) => (n >= 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)}MB` : `${Math.max(1, Math.round(n / 1024))}KB`);

export default function LeavesBoard() {
  const { region } = useOperator();
  const today = todayInSeoul();
  const [from, setFrom] = useState(addDays(today, -21));
  const [to, setTo] = useState(addDays(today, 7));
  const [filter, setFilter] = useState("submitted");
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

  async function act(l: Leave, action: "approve" | "reject" | "cancel") {
    let note: string | null = "";
    if (action === "approve") {
      const warn = l.docs.length === 0 ? "\n올라온 서류가 없습니다. 서류를 따로 확인했을 때만 승인해 주세요." : "";
      if (!window.confirm(`${l.name} · ${LEAVE_KIND_LABEL[l.kind]} 공가를 승인할까요? 승인하면 그 날짜는 출석으로 인정됩니다.${warn}`)) return;
    } else {
      note = window.prompt(action === "reject" ? "반려 사유를 적어 주세요. 교육생에게 보이며, 교육생은 서류를 다시 올릴 수 있습니다." : "취소 사유를 적어 주세요. (교육생에게 보입니다)");
      if (note === null) return;
    }
    const r = action === "cancel"
      ? await api("/api/admin/leaves", { action: "cancel", id: l.id, note, version: l.version })
      : await api("/api/admin/leaves", { action: "decide", id: l.id, decision: action === "approve" ? "approved" : "rejected", note, version: l.version });
    if (!r.ok) setMessage({ kind: "error", text: messageFor(r.code) });
    else setMessage({ kind: "ok", text: `${l.name} 공가를 ${action === "approve" ? "승인" : action === "reject" ? "반려" : "취소"}했습니다.` });
    await load();
  }

  return (
    <>
      <div className="a-title">
        <div>
          <h1>공가</h1>
          <span className="small">병결·면접·예비군 등 공가 신청입니다. 교육생이 서류(사진·PDF)를 올리면 확인한 뒤 승인합니다. 승인된 날은 출석으로 인정됩니다.</span>
        </div>
        <button className="btn" onClick={() => { setAdding(true); setMessage(null); }}>공가 등록</button>
      </div>

      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      {adding && <AddLeave region={region} onDone={async (t) => { setAdding(false); setMessage({ kind: "ok", text: t }); await load(); }} onCancel={() => setAdding(false)} />}

      <div className="stats">
        <div className="stat"><span>확인 대기 (서류 제출)</span><strong>{count("submitted")}</strong></div>
        <div className="stat"><span>서류 미제출</span><strong>{count("registered")}</strong></div>
        <div className="stat"><span>승인</span><strong>{count("approved")}</strong></div>
        <div className="stat"><span>반려</span><strong>{count("rejected")}</strong></div>
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
            <thead><tr><th>기간</th><th>이름</th><th>과정</th><th>구분</th><th>사유</th><th>서류</th><th>상태</th><th>처리</th></tr></thead>
            <tbody>
              {filtered.map((l) => (
                <tr key={l.id}>
                  <td>{formatDate(l.startsOn)}{l.endsOn !== l.startsOn && <><br />~ {formatDate(l.endsOn)}</>}</td>
                  <td><Link href={`/admin/students/${l.enrollmentId}?date=${l.startsOn}`}><b>{l.name}</b></Link></td>
                  <td>{l.course}</td>
                  <td>{LEAVE_KIND_LABEL[l.kind]}<br /><span className="small">{LEAVE_PART_LABEL[l.part]}</span></td>
                  <td style={{ whiteSpace: "normal", minWidth: 180 }}>
                    {l.reason}
                    <div className="small">{l.createdBy === "student" ? "교육생 신청" : `운영자 ${l.createdName ?? ""} 등록`} · {formatDateTime(l.createdAt)}</div>
                    {l.decisionNote && <div className="small">처리 메모: {l.decisionNote}</div>}
                    {l.cancelNote && <div className="small">취소 사유: {l.cancelNote}</div>}
                  </td>
                  <td className="small" style={{ whiteSpace: "normal", minWidth: 150 }}>
                    {l.docs.length === 0 ? "—" : l.docs.map((d) => (
                      <div key={d.id}>
                        <a href={`/api/admin/leaves/docs/${d.id}`} target="_blank" rel="noopener noreferrer">{d.name}</a> ({kb(d.size)})
                      </div>
                    ))}
                  </td>
                  <td>
                    <span className={`tag ${LEAVE_STATUS_CLASS[l.status]}`}>{LEAVE_STATUS_LABEL[l.status]}</span>
                    {(l.decidedBy || l.cancelledBy) && <div className="small">{l.cancelledBy ?? l.decidedBy}</div>}
                  </td>
                  <td>
                    <span className="row" style={{ gap: 6, flexWrap: "nowrap" }}>
                      {["registered", "submitted", "rejected"].includes(l.status) && <button className="btn sm" onClick={() => act(l, "approve")}>승인</button>}
                      {["registered", "submitted"].includes(l.status) && <button className="btn plain sm" onClick={() => act(l, "reject")}>반려</button>}
                      {l.status !== "cancelled" && <button className="btn plain sm" onClick={() => act(l, "cancel")}>취소</button>}
                    </span>
                  </td>
                </tr>
              ))}
              {items && filtered.length === 0 && <tr><td colSpan={8} className="small center">해당하는 공가가 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      <p className="small">
        승인된 공가 날은 출석으로 인정됩니다(하루 전체 공가, 또는 일부 시간 공가로 입실한 날). 승인 전에는 판정에 반영하지 않습니다.
        서류를 열면 열람 기록이, 승인·반려·취소는 처리 기록이 변경 이력에 남습니다.
      </p>
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
  const [approve, setApprove] = useState(false);
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
    if (approve) {
      const d = await api("/api/admin/leaves", { action: "decide", id: r.id, decision: "approved", note: "운영자가 서류 확인", version: 1 });
      if (!d.ok) {
        onDone(`${name} 공가를 등록했지만 승인하지 못했습니다: ${messageFor(d.code)}`);
        return;
      }
    }
    onDone(`${name} 공가를 ${approve ? "등록하고 승인" : "등록"}했습니다.`);
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
      <label className="row small" style={{ gap: 6 }}>
        <input type="checkbox" checked={approve} onChange={(e) => setApprove(e.target.checked)} style={{ width: "auto", margin: 0 }} />
        서류를 이미 받아 확인했습니다 (바로 승인)
      </label>
      {error && <p className="notice error">{error}</p>}
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn plain" onClick={onCancel}>취소</button>
        <button className="btn">등록</button>
      </div>
    </form>
  );
}
