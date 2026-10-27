"use client";

import { useCallback, useEffect, useState } from "react";
import { api, kstHHMM, kstIso } from "@/lib/client";
import { ACTION_LABEL, REQUEST_STATUS_LABEL, formatDate, formatDateTime, formatTime, messageFor } from "@/lib/messages";

type Item = { action: string; at: string; source?: string; method?: string };
type Day = {
  enrollmentId: number;
  name: string;
  course: string;
  date: string;
  version: number;
  original: Item[];
  timeline: Item[];
  corrections: { id: number; createdAt: string; operatorName: string; basis: string; before: Item[]; after: Item[]; requestId: number | null }[];
  requests: { id: number; reason: string; status: string; createdAt: string; decidedBy: string | null; note: string | null }[];
};
type Row = { action: string; time: string; at: string | null; originalAt: string | null };

function Timeline({ items, empty }: { items: Item[]; empty: string }) {
  if (items.length === 0) return <p className="small">{empty}</p>;
  return (
    <ul className="tl">
      {items.map((t, i) => (
        <li key={i} className={t.source === "corrected" ? "corrected" : undefined}>
          <time>{formatTime(t.at)}</time>
          {ACTION_LABEL[t.action]}
          {t.source === "corrected" && <span className="tag warn">정정</span>}
          {t.method === "code" && <span className="tag brand">출석코드</span>}
        </li>
      ))}
    </ul>
  );
}

function Editor({ day, requestId, onDone }: { day: Day; requestId: number | null; onDone: (msg: string) => void }) {
  const [rows, setRows] = useState<Row[]>(() =>
    day.timeline.map((t) => ({ action: t.action, time: kstHHMM(t.at), at: t.at, originalAt: t.at })),
  );
  const [basis, setBasis] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  function update(i: number, patch: Partial<Row>) {
    setRows((rs) =>
      rs.map((r, j) => {
        if (j !== i) return r;
        const next = { ...r, ...patch };
        // 시각을 바꾸지 않은 원본 행은 원래 초 단위 시각을 그대로 보낸다.
        if (patch.time !== undefined) {
          next.at = next.originalAt && kstHHMM(next.originalAt) === patch.time ? next.originalAt : patch.time ? kstIso(day.date, patch.time) : null;
        }
        return next;
      }),
    );
  }

  function addRow() {
    const last = rows[rows.length - 1]?.action;
    const action = !last ? "check_in" : last === "go_out" ? "return" : "check_out";
    setRows([...rows, { action, time: "", at: null, originalAt: null }]);
  }

  async function save() {
    setError(null);
    if (rows.some((r) => !r.at)) {
      setError("모든 행에 시각을 입력해 주세요.");
      return;
    }
    setBusy(true);
    const r = await api("/api/admin/corrections", {
      action: "save",
      enrollmentId: day.enrollmentId,
      date: day.date,
      timeline: rows.map((x) => ({ action: x.action, at: x.at })),
      basis,
      requestId,
      expectedVersion: day.version,
    });
    setBusy(false);
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    onDone(requestId ? "요청을 승인하고 정정을 반영했습니다." : "정정을 반영했습니다.");
  }

  return (
    <div className="card" style={{ boxShadow: "none", border: "1.5px solid var(--line)", marginTop: 12 }}>
      <h2>{requestId ? "승인하며 정정" : "직권 정정"}</h2>
      <p className="small">정정 후의 하루 기록 전체를 입력합니다. 원본 기록은 지워지지 않고 그대로 보관됩니다.</p>
      {rows.map((r, i) => (
        <div className="editor-row" key={i}>
          <select value={r.action} onChange={(e) => update(i, { action: e.target.value })} aria-label="구분">
            {Object.entries(ACTION_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
          <input type="time" value={r.time} onChange={(e) => update(i, { time: e.target.value })} aria-label="시각" />
          <button type="button" onClick={() => setRows(rows.filter((_, j) => j !== i))} aria-label="행 삭제">×</button>
        </div>
      ))}
      <button type="button" className="btn ghost sm" onClick={addRow}>+ 기록 추가</button>
      <label className="field" style={{ marginTop: 14 }}>
        확인 근거와 처리 내용 (필수)
        <textarea value={basis} onChange={(e) => setBasis(e.target.value)} placeholder="예: 현장 출석부와 대조하여 18:05 퇴실 반영" />
      </label>
      {error && <p className="notice error">{error}</p>}
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button className="btn" onClick={save} disabled={busy}>{requestId ? "승인하고 반영" : "정정 반영"}</button>
      </div>
    </div>
  );
}

export default function DayPanel({
  enrollmentId,
  date,
  requestId = null,
  onChanged,
}: {
  enrollmentId: number;
  date: string;
  requestId?: number | null;
  onChanged?: () => void;
}) {
  const [day, setDay] = useState<Day | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [mode, setMode] = useState<"view" | "edit" | "reject">("view");
  const [note, setNote] = useState("");
  const [message, setMessage] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/day?enrollment=${enrollmentId}&date=${date}`);
    if (!r.ok) setError(messageFor(r.code));
    else {
      setDay(r as unknown as Day);
      setError(null);
    }
  }, [enrollmentId, date]);

  useEffect(() => {
    setDay(null);
    setMode("view");
    setMessage(null);
    void load();
  }, [load, requestId]);

  async function reject() {
    const r = await api("/api/admin/corrections", { action: "reject", requestId, basis: note });
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    setMode("view");
    setMessage("요청을 반려했습니다.");
    await load();
    onChanged?.();
  }

  if (error && !day) return <div className="panel"><p className="notice error">{error}</p></div>;
  if (!day) return <div className="panel small">불러오는 중…</div>;

  const pending = requestId ? day.requests.find((q) => q.id === requestId && q.status === "pending") : null;
  const changed = JSON.stringify(day.original.map((o) => [o.action, o.at])) !== JSON.stringify(day.timeline.map((o) => [o.action, o.at]));

  return (
    <div className="panel">
      <div className="row between">
        <div>
          <h2>{day.name} · {day.course}</h2>
          <span className="small">{formatDate(day.date)}</span>
        </div>
        {mode === "view" && (
          <div className="row">
            {pending ? (
              <>
                <button className="btn plain sm" onClick={() => setMode("reject")}>반려</button>
                <button className="btn sm" onClick={() => setMode("edit")}>승인하며 정정</button>
              </>
            ) : (
              <button className="btn ghost sm" onClick={() => setMode("edit")}>기록 정정</button>
            )}
          </div>
        )}
      </div>

      {message && <p className="notice ok">{message}</p>}
      {error && <p className="notice error">{error}</p>}

      {day.requests.length > 0 && (
        <div style={{ marginTop: 12 }}>
          {day.requests.map((q) => (
            <div key={q.id} className="notice" style={{ marginBottom: 8 }}>
              <span className={`tag ${q.status}`}>{REQUEST_STATUS_LABEL[q.status]}</span>{" "}
              <b>교육생 요청</b> · {formatDateTime(q.createdAt)}
              <div style={{ marginTop: 4 }}>{q.reason}</div>
              {q.note && <div className="small">처리: {q.decidedBy} · {q.note}</div>}
            </div>
          ))}
        </div>
      )}

      <div className="cols" style={{ marginTop: 12 }}>
        <div>
          <h4 style={{ margin: "0 0 8px" }}>원본 기록</h4>
          <Timeline items={day.original} empty="원본 기록이 없습니다." />
        </div>
        <div>
          <h4 style={{ margin: "0 0 8px" }}>현재 반영 기록 {changed && <span className="tag warn">정정 반영</span>}</h4>
          <Timeline items={day.timeline} empty="반영된 기록이 없습니다." />
        </div>
      </div>

      {mode === "edit" && (
        <Editor
          day={day}
          requestId={pending ? requestId : null}
          onDone={async (msg) => {
            setMode("view");
            setMessage(msg);
            await load();
            onChanged?.();
          }}
        />
      )}

      {mode === "reject" && (
        <div className="card" style={{ boxShadow: "none", border: "1.5px solid var(--line)", marginTop: 12 }}>
          <label className="field">
            반려 사유 (교육생에게 보입니다)
            <textarea value={note} onChange={(e) => setNote(e.target.value)} placeholder="예: 해당 시간 현장 확인 자료가 없어 반영하지 않습니다." />
          </label>
          <div className="row" style={{ justifyContent: "flex-end" }}>
            <button className="btn plain" onClick={() => setMode("view")}>취소</button>
            <button className="btn danger" onClick={reject}>반려</button>
          </div>
        </div>
      )}

      {day.corrections.length > 0 && (
        <details style={{ marginTop: 14 }}>
          <summary className="small">정정 이력 {day.corrections.length}건</summary>
          <ul className="mini-list">
            {day.corrections.map((c) => (
              <li key={c.id} style={{ display: "block" }}>
                <b>{c.operatorName}</b> · {formatDateTime(c.createdAt)} {c.requestId ? <span className="tag brand">요청 승인</span> : <span className="tag">직권</span>}
                <div className="small">{c.basis}</div>
                <div className="small">
                  변경 전: {c.before.map((t) => `${formatTime(t.at)} ${ACTION_LABEL[t.action]}`).join(", ") || "없음"}
                  <br />
                  변경 후: {c.after.map((t) => `${formatTime(t.at)} ${ACTION_LABEL[t.action]}`).join(", ") || "없음"}
                </div>
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}
