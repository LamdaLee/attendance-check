"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api, kstHHMM } from "@/lib/client";
import {
  LEAVE_STATUS_LABEL, TRAINING_STATUS_LABEL, formatDate, formatDateTime, formatTime, leaveText, messageFor, noticeText,
  todayInSeoul,
} from "@/lib/messages";

type Leave = { id: number; kind: string; part: string; status: string; reason: string };
type Row = {
  enrollmentId: number;
  name: string;
  course: string;
  courseId: number;
  state: string;
  statusOn: string | null;
  dayStatus: string;
  firstCheckInAt: string | null;
  lastCheckOutAt: string | null;
  corrected: boolean;
  late: boolean;
  early: boolean;
  leave: Leave | null;
  notices: { kind: string; expectedTime: string | null; reason: string }[];
  note: { text: string; version: number; updatedBy: string; updatedAt: string } | null;
};
type Course = { id: number; name: string; classStart: string; classEnd: string };
type Data = { date: string; today: string; now: string; courses: Course[]; rows: Row[] };

// 판정: 결석은 과정 종료 시각이 지나야 확정한다. 그 전에는 미입실.
type Judged = Row & {
  current: boolean;
  absent: boolean;
  notYet: boolean;
  missingOut: boolean;
  // 서류가 확인된 공가. 하루 전체 공가만 결석을 덮고, 지각·조퇴는 일부 시간 공가도 덮는다.
  excusedAbsent: boolean;
  excusedTime: boolean;
  flags: { label: string; cls: string }[];
};

function judge(r: Row, data: Data, course: Course | undefined): Judged {
  const current = r.state === "training";
  const final = data.date < data.today || (data.date === data.today && !!course && kstHHMM(data.now) >= course.classEnd);
  const noIn = !r.firstCheckInAt;
  const absent = current && noIn && final;
  const notYet = current && noIn && !final;
  const missingOut = current && final && (r.dayStatus === "in_class" || r.dayStatus === "out");
  const excusedTime = r.leave?.status === "approved";
  const excusedAbsent = excusedTime && r.leave?.part === "full";
  const leaveLabel = !r.leave ? "" : r.leave.status !== "approved" ? "공가 서류 대기" : r.leave.part === "partial" ? "일부 시간 공가" : "공가";
  const flags: { label: string; cls: string }[] = [];
  if (!current) flags.push({ label: TRAINING_STATUS_LABEL[r.state], cls: r.state === "dropped" ? "danger" : "paused" });
  else if (r.statusOn === data.date) flags.push({ label: "오늘 상태 변경", cls: "paused" });
  if (absent) flags.push(excusedAbsent ? { label: "결석 · 공가", cls: "approved" } : { label: r.leave ? `결석 · ${leaveLabel}` : "결석", cls: r.leave ? "pending" : "danger" });
  if (notYet) flags.push({ label: "미입실", cls: "paused" });
  if (current && r.late) flags.push(excusedTime ? { label: "지각 · 공가", cls: "approved" } : { label: r.leave ? `지각 · ${leaveLabel}` : "지각", cls: "warn" });
  if (current && r.early) flags.push(excusedTime ? { label: "조퇴 · 공가", cls: "approved" } : { label: r.leave ? `조퇴 · ${leaveLabel}` : "조퇴", cls: "warn" });
  if (missingOut) flags.push({ label: r.dayStatus === "out" ? "복귀 기록 없음" : "퇴실 기록 없음", cls: "pending" });
  if (current && !absent && !notYet && !r.late && !r.early && !missingOut && r.leave) flags.push({ label: leaveLabel, cls: excusedTime ? "approved" : "pending" });
  if (r.corrected) flags.push({ label: "정정", cls: "warn" });
  return { ...r, current, absent, notYet, missingOut, excusedAbsent, excusedTime, flags };
}

type Summary = {
  enrolled: number;
  dropped: number;
  employed: number;
  completed: number;
  current: number;
  present: number;
  absent: number;
  absentExcused: number;
  late: number;
  lateExcused: number;
  early: number;
  earlyExcused: number;
  notYet: number;
};

function summarize(rows: Judged[]): Summary {
  const cur = rows.filter((r) => r.current);
  return {
    enrolled: rows.length,
    dropped: rows.filter((r) => r.state === "dropped").length,
    employed: rows.filter((r) => r.state === "employed").length,
    completed: rows.filter((r) => r.state === "completed").length,
    current: cur.length,
    present: cur.filter((r) => r.firstCheckInAt).length,
    absent: cur.filter((r) => r.absent).length,
    absentExcused: cur.filter((r) => r.absent && r.excusedAbsent).length,
    late: cur.filter((r) => r.late).length,
    lateExcused: cur.filter((r) => r.late && r.excusedTime).length,
    early: cur.filter((r) => r.early).length,
    earlyExcused: cur.filter((r) => r.early && r.excusedTime).length,
    notYet: cur.filter((r) => r.notYet).length,
  };
}

const withExcused = (n: number, ex: number) => (ex > 0 ? `${n} (공가 ${ex})` : String(n));

export default function ReportBoard() {
  const { operator, region } = useOperator();
  const [date, setDate] = useState(todayInSeoul());
  const [course, setCourse] = useState("");
  const [showAll, setShowAll] = useState(false);
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editingHours, setEditingHours] = useState<number | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/report?region=${encodeURIComponent(region)}&date=${date}`);
    if (!r.ok) setError(messageFor(r.code));
    else {
      setData(r as unknown as Data);
      setError(null);
    }
  }, [region, date]);

  useEffect(() => {
    setData(null);
    void load();
  }, [load]);

  const courseById = useMemo(() => new Map((data?.courses ?? []).map((c) => [c.id, c])), [data]);
  const judged = useMemo(
    () => (data ? data.rows.map((r) => judge(r, data, courseById.get(r.courseId))) : []),
    [data, courseById],
  );
  const visible = judged.filter((r) => !course || r.course === course);
  const courseNames = [...new Set(judged.map((r) => r.course))];
  const summaries = courseNames
    .filter((c) => !course || c === course)
    .map((c) => ({ name: c, info: data?.courses.find((x) => x.name === c), s: summarize(judged.filter((r) => r.course === c)) }));
  const total = summarize(visible);
  const detail = visible.filter((r) => showAll || r.flags.length > 0 || r.note || r.notices.length > 0);

  const regionName = operator.regions.find((r) => r.code === region)?.name ?? "";

  return (
    <>
      <div className="a-title">
        <div>
          <h1>출결 일보</h1>
          <span className="small">재적·현인원·결석·지각·조퇴를 한 장으로 보고, 교육생별 사유를 적습니다. 보조 자료이며 공식 출석 인정은 LMS 판정을 따릅니다.</span>
        </div>
        <div className="row no-print">
          <button className="btn plain" onClick={() => window.print()}>인쇄 · PDF</button>
        </div>
      </div>

      <div className="print-meta">
        {regionName} 지역 출결 일보 · {formatDate(date)}{course && ` · ${course}`} · 출력 {formatDateTime(new Date().toISOString())} · {operator.operatorName}
      </div>

      <div className="filters">
        <label className="field">날짜<input type="date" value={date} onChange={(e) => e.target.value && setDate(e.target.value)} /></label>
        <label className="field">
          과정
          <select value={course} onChange={(e) => setCourse(e.target.value)}>
            <option value="">전체 과정</option>
            {courseNames.map((c) => <option key={c}>{c}</option>)}
          </select>
        </label>
      </div>

      {error && <p className="notice error">{error}</p>}
      {!data && !error && <p className="small">불러오는 중…</p>}

      {data && (
        <>
          <div className="table-card" style={{ marginBottom: 14 }}>
            <div className="table-wrap">
              <table className="report-sum">
                <thead>
                  <tr>
                    <th>과정</th><th>교육 시간</th><th>재적</th><th>중도탈락</th><th>조기취업</th><th>수료</th>
                    <th>현인원</th><th>출석</th><th>결석</th><th>지각</th><th>조퇴</th>
                    {total.notYet > 0 && <th>미입실</th>}
                  </tr>
                </thead>
                <tbody>
                  {summaries.map(({ name, info, s }) => (
                    <tr key={name}>
                      <td><b>{name}</b></td>
                      <td>
                        {info && editingHours === info.id ? (
                          <HoursEditor course={info} onDone={async (changed) => { setEditingHours(null); if (changed) await load(); }} />
                        ) : (
                          <span className="row" style={{ flexWrap: "nowrap", gap: 6 }}>
                            {info ? `${info.classStart}~${info.classEnd}` : "—"}
                            {info && <button className="btn plain sm no-print" onClick={() => setEditingHours(info.id)}>변경</button>}
                          </span>
                        )}
                      </td>
                      <SummaryCells s={s} showNotYet={total.notYet > 0} />
                    </tr>
                  ))}
                  {summaries.length > 1 && (
                    <tr className="total">
                      <td><b>합계</b></td><td />
                      <SummaryCells s={total} showNotYet={total.notYet > 0} />
                    </tr>
                  )}
                  {summaries.length === 0 && <tr><td colSpan={11} className="small center">이 날짜에 수강 중인 교육생이 없습니다.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
          <p className="small">
            재적은 그 날 수강 명단 전체(중도탈락·조기취업 포함), 현인원은 그 중 훈련중인 인원입니다. 지각은 첫 입실이 교육 시작 뒤,
            조퇴는 마지막 퇴실이 교육 종료 전인 경우이며, 결석은 교육 종료 시각이 지나야 확정됩니다. 괄호 안은 서류가 확인된 공가입니다.
          </p>

          <div className="row between" style={{ margin: "18px 0 10px" }}>
            <h2 style={{ margin: 0, fontSize: 17 }}>교육생별 사유 <span className="small">({detail.length}명)</span></h2>
            <label className="row small no-print" style={{ gap: 6 }}>
              <input type="checkbox" checked={showAll} onChange={(e) => setShowAll(e.target.checked)} style={{ width: "auto", margin: 0 }} />
              특이사항 없는 교육생도 보기
            </label>
          </div>

          <div className="table-card">
            <div className="table-wrap">
              <table className="report-detail">
                <thead><tr><th>과정</th><th>이름</th><th>구분</th><th>입실</th><th>퇴실</th><th>알림 · 공가</th><th style={{ minWidth: 260 }}>사유</th></tr></thead>
                <tbody>
                  {detail.map((r) => (
                    <tr key={r.enrollmentId} style={!r.current ? { background: "#fafbfe" } : undefined}>
                      <td>{r.course}</td>
                      <td><Link href={`/admin/students/${r.enrollmentId}?date=${date}`}><b>{r.name}</b></Link></td>
                      <td>
                        <span className="row" style={{ gap: 4 }}>
                          {r.flags.length ? r.flags.map((f) => <span key={f.label} className={`tag ${f.cls}`}>{f.label}</span>) : <span className="small">출석</span>}
                        </span>
                      </td>
                      <td>{formatTime(r.firstCheckInAt)}</td>
                      <td>{formatTime(r.lastCheckOutAt)}</td>
                      <td className="small" style={{ whiteSpace: "normal", minWidth: 160 }}>
                        {r.leave && <div>공가 {leaveText(r.leave)} · {LEAVE_STATUS_LABEL[r.leave.status]} — {r.leave.reason}</div>}
                        {r.notices.map((n, i) => <div key={i}>{noticeText(n)} — {n.reason}</div>)}
                        {!r.leave && r.notices.length === 0 && "—"}
                      </td>
                      <td style={{ whiteSpace: "normal" }}>
                        <NoteCell key={`${r.enrollmentId}:${date}`} row={r} date={date} />
                      </td>
                    </tr>
                  ))}
                  {detail.length === 0 && <tr><td colSpan={7} className="small center">특이사항이 있는 교육생이 없습니다.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </>
  );
}

function SummaryCells({ s, showNotYet }: { s: Summary; showNotYet: boolean }) {
  return (
    <>
      <td>{s.enrolled}</td>
      <td>{s.dropped}</td>
      <td>{s.employed}</td>
      <td>{s.completed}</td>
      <td><b>{s.current}</b></td>
      <td>{s.present}</td>
      <td className={s.absent - s.absentExcused > 0 ? "num-bad" : undefined}>{withExcused(s.absent, s.absentExcused)}</td>
      <td>{withExcused(s.late, s.lateExcused)}</td>
      <td>{withExcused(s.early, s.earlyExcused)}</td>
      {showNotYet && <td>{s.notYet}</td>}
    </>
  );
}

function HoursEditor({ course, onDone }: { course: Course; onDone: (changed: boolean) => void }) {
  const [start, setStart] = useState(course.classStart);
  const [end, setEnd] = useState(course.classEnd);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    const r = await api("/api/admin/report", { action: "hours", courseId: course.id, start, end });
    if (!r.ok && r.code !== "no_change") {
      setError(messageFor(r.code));
      return;
    }
    onDone(r.ok);
  }

  return (
    <span className="row" style={{ flexWrap: "nowrap", gap: 6 }}>
      <input type="time" value={start} onChange={(e) => setStart(e.target.value)} className="time-sm" aria-label="시작" />
      ~
      <input type="time" value={end} onChange={(e) => setEnd(e.target.value)} className="time-sm" aria-label="종료" />
      <button className="btn sm" onClick={save}>저장</button>
      <button className="btn plain sm" onClick={() => onDone(false)}>취소</button>
      {error && <span className="small" style={{ color: "var(--danger)" }}>{error}</span>}
    </span>
  );
}

function NoteCell({ row, date }: { row: Judged; date: string }) {
  const [text, setText] = useState(row.note?.text ?? "");
  const [saved, setSaved] = useState(row.note?.text ?? "");
  const [version, setVersion] = useState(row.note?.version ?? 0);
  const [state, setState] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const suggestion = row.leave?.reason ?? row.notices[0]?.reason ?? "";

  async function save() {
    setBusy(true);
    const r = await api("/api/admin/report", { action: "note", enrollmentId: row.enrollmentId, date, note: text, version });
    setBusy(false);
    if (!r.ok) {
      setState({ kind: "error", text: messageFor(r.code) });
      return;
    }
    setVersion(r.version);
    setSaved(text.trim());
    setText(text.trim());
    setState({ kind: "ok", text: "저장됨" });
  }

  const dirty = text.trim() !== saved;
  return (
    <>
      <div className="note-cell no-print">
        <textarea
          value={text}
          onChange={(e) => { setText(e.target.value); setState(null); }}
          maxLength={300}
          rows={1}
          placeholder={suggestion ? `예: ${suggestion}` : "사유 입력"}
        />
        <div className="row" style={{ gap: 6 }} title={row.note ? `${row.note.updatedBy} · ${formatDateTime(row.note.updatedAt)}` : undefined}>
          {!text && suggestion && <button className="btn plain sm" onClick={() => setText(suggestion)}>가져오기</button>}
          <button className="btn sm" onClick={save} disabled={busy || !dirty}>저장</button>
          {state && <span className="small" style={{ color: state.kind === "error" ? "var(--danger)" : "var(--ok)" }}>{state.text}</span>}
        </div>
      </div>
      <div className="print-only">{saved || "—"}</div>
    </>
  );
}
