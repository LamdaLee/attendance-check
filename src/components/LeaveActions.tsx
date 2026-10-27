"use client";

import { useState } from "react";
import { api } from "@/lib/client";
import { LEAVE_KIND_LABEL, formatDate, messageFor } from "@/lib/messages";

// 결석·지각·조퇴를 공가로 처리: 운영자가 LMS 등에서 서류를 확인한 뒤 그 날짜를 바로 승인 공가로 등록한다.
export function LeaveQuick({ enrollmentId, date, defaultFull, defaultReason, onDone }: {
  enrollmentId: number;
  date: string;
  defaultFull: boolean;
  defaultReason?: string;
  onDone: () => Promise<void> | void;
}) {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState("sick");
  const [part, setPart] = useState(defaultFull ? "full" : "partial");
  const [reason, setReason] = useState(defaultReason ?? "");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function save() {
    setBusy(true);
    setError(null);
    const r = await api("/api/admin/leaves", { action: "create", enrollmentId, from: date, to: date, kind, part, reason });
    if (r.ok) {
      const d = await api("/api/admin/leaves", { action: "decide", id: r.id, decision: "approved", note: "운영자 공가 처리", version: 1 });
      if (!d.ok) setError(messageFor(d.code));
    } else setError(messageFor(r.code));
    setBusy(false);
    if (r.ok) {
      setOpen(false);
      await onDone();
    }
  }

  if (!open) return <button className="btn plain sm no-print" onClick={() => setOpen(true)}>공가 처리</button>;
  return (
    <div className="no-print" style={{ display: "grid", gap: 6, minWidth: 220 }}>
      <span className="row" style={{ gap: 6 }}>
        <select className="time-sm" style={{ width: "auto" }} value={kind} onChange={(e) => setKind(e.target.value)}>
          {Object.entries(LEAVE_KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <select className="time-sm" style={{ width: "auto" }} value={part} onChange={(e) => setPart(e.target.value)}>
          <option value="full">하루 전체</option>
          <option value="partial">일부 시간</option>
        </select>
      </span>
      <input className="time-sm" style={{ width: "100%" }} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="사유 (예: 병원 진료, LMS 서류 확인)" maxLength={300} />
      <span className="row" style={{ gap: 6 }}>
        <button className="btn sm" onClick={save} disabled={busy || reason.trim().length < 2}>공가로 승인</button>
        <button className="btn plain sm" onClick={() => setOpen(false)}>취소</button>
      </span>
      {error && <span className="small" style={{ color: "var(--danger)", whiteSpace: "normal" }}>{error}</span>}
    </div>
  );
}

// 잘못 처리한 공가 되돌리기 (사유 필수, 변경 이력에 남음)
export function LeaveCancel({ leaveId, name, date, region, onDone }: {
  leaveId: number;
  name: string;
  date: string;
  region: string;
  onDone: () => Promise<void> | void;
}) {
  const [error, setError] = useState<string | null>(null);
  async function cancel() {
    const note = window.prompt(`${name}의 ${formatDate(date)} 공가를 취소합니다. 취소 사유를 적어 주세요.`);
    if (note === null) return;
    const list = await api(`/api/admin/leaves?region=${encodeURIComponent(region)}&from=${date}&to=${date}`);
    const leave = (list.leaves as { id: number; version: number }[] | undefined)?.find((l) => l.id === leaveId);
    if (!leave) return setError(messageFor(list.code ?? "not_found"));
    const r = await api("/api/admin/leaves", { action: "cancel", id: leave.id, note, version: leave.version });
    if (!r.ok) return setError(messageFor(r.code));
    await onDone();
  }
  return (
    <>
      <button className="btn plain sm no-print" onClick={cancel}>공가 취소</button>
      {error && <div className="small" style={{ color: "var(--danger)" }}>{error}</div>}
    </>
  );
}
