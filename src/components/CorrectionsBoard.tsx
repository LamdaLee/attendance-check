"use client";

import { useCallback, useEffect, useState } from "react";
import { useOperator } from "./AdminShell";
import DayPanel from "./DayPanel";
import { api } from "@/lib/client";
import { REQUEST_STATUS_LABEL, formatDate, formatDateTime, messageFor } from "@/lib/messages";

type Request = {
  id: number;
  enrollmentId: number;
  name: string;
  course: string;
  date: string;
  reason: string;
  status: string;
  createdAt: string;
};

const TABS = [
  { value: "pending", label: "처리 대기" },
  { value: "approved", label: "승인" },
  { value: "rejected", label: "반려" },
  { value: "", label: "전체" },
];

export default function CorrectionsBoard() {
  const { region } = useOperator();
  const [status, setStatus] = useState("pending");
  const [items, setItems] = useState<Request[] | null>(null);
  const [selected, setSelected] = useState<Request | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/corrections?region=${encodeURIComponent(region)}&status=${status}`);
    if (!r.ok) setError(messageFor(r.code));
    else {
      setItems(r.requests);
      setError(null);
    }
  }, [region, status]);

  useEffect(() => {
    setItems(null);
    setSelected(null);
    void load();
  }, [load]);

  return (
    <>
      <div className="a-title">
        <div>
          <h1>정정 요청</h1>
          <span className="small">교육생이 보낸 요청을 원본 기록과 비교해 승인하거나 반려합니다. 원본은 지워지지 않습니다.</span>
        </div>
      </div>
      <div className="tabs">
        {TABS.map((t) => (
          <button key={t.value} className={status === t.value ? "on" : undefined} onClick={() => setStatus(t.value)}>{t.label}</button>
        ))}
      </div>
      {error && <p className="notice error">{error}</p>}
      <div className="split">
        <div className="list">
          {!items && <p className="small" style={{ padding: 16 }}>불러오는 중…</p>}
          {items?.length === 0 && <p className="small" style={{ padding: 16 }}>요청이 없습니다.</p>}
          {items?.map((q) => (
            <button key={q.id} className={`item${selected?.id === q.id ? " on" : ""}`} onClick={() => setSelected(q)}>
              <div className="row between">
                <b>{q.name} <span className="small">{q.course}</span></b>
                <span className={`tag ${q.status}`}>{REQUEST_STATUS_LABEL[q.status]}</span>
              </div>
              <div>{formatDate(q.date)} 기록</div>
              <div className="meta">{q.reason}</div>
              <div className="meta">요청 {formatDateTime(q.createdAt)}</div>
            </button>
          ))}
        </div>
        {selected ? (
          <DayPanel
            key={selected.id}
            enrollmentId={selected.enrollmentId}
            date={selected.date}
            requestId={selected.status === "pending" ? selected.id : null}
            onChanged={load}
          />
        ) : (
          <div className="panel small">왼쪽 목록에서 요청을 선택하세요.</div>
        )}
      </div>
    </>
  );
}
