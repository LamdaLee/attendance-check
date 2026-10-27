"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { LeaveCancel, LeaveQuick } from "./LeaveActions";
import { api, kstHHMM } from "@/lib/client";
import {
  LEAVE_STATUS_CLASS, leaveGroup, LEAVE_STATUS_LABEL, TRAINING_STATUS_LABEL, formatDate, formatDateTime, formatTime, leaveText, messageFor, noticeText,
  todayInSeoul,
} from "@/lib/messages";

type Leave = { id: number; kind: string; part: string; status: string; reason: string };
// 서버 판정 (attendance.day_eval · day_judge · course_tally)
type Eval = { status: string; attendedMinutes: number; classMinutes: number; enough: boolean; outs: number };
// leaveAttend: 승인 공가로 출석 인정 / excused: 승인 공가 날 / pending: 승인 전 공가가 걸린 날
type DayJudge = {
  absent: boolean;
  leaveAttend: boolean;
  insufficient: boolean;
  late: boolean;
  early: boolean;
  outs: number;
  excused: boolean;
  pending: boolean;
};
type Tally = {
  days: number;
  absent: number;
  leaveAttend: number;
  sickAttend: number;
  otherAttend: number;
  late: number;
  early: number;
  outs: number;
  converted: number;
  totalAbsent: number;
  attended: number;
  rate: number | null;
};
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
  eval: Eval;
  judge: DayJudge;
  tally: Tally;
  sickUsed: number;
  leave: Leave | null;
  notices: { kind: string; expectedTime: string | null; reason: string }[];
  note: { text: string; version: number; updatedBy: string; updatedAt: string } | null;
};
// dayStart·dayEnd·dayPlace·dayOff: 이 날의 일정 (평택 러닝센터·휴강 반영)
type Course = {
  id: number;
  name: string;
  classStart: string;
  classEnd: string;
  lateAfter: number;
  dayStart: string;
  dayEnd: string;
  dayPlace: string;
  dayOff: boolean;
};
type Data = { date: string; today: string; now: string; courses: Course[]; rows: Row[] };

const SICK_LIMIT = 5;

// 화면 판정: 결석은 교육 종료 시각이 지나야 확정한다. 그 전에는 미입실.
type Judged = Row & {
  current: boolean;
  absent: boolean;
  notYet: boolean;
  missingOut: boolean;
  flags: { label: string; cls: string }[];
};

function judge(r: Row, data: Data, course: Course | undefined): Judged {
  const j = r.judge;
  const current = r.state === "training";
  const final = data.date < data.today || (data.date === data.today && !!course && kstHHMM(data.now) >= course.dayEnd);
  const absent = current && final && j.absent;
  const leaveAttend = current && final && j.leaveAttend;
  const notYet = current && !final && !r.firstCheckInAt;
  const missingOut = current && final && (r.dayStatus === "in_class" || r.dayStatus === "out");
  const ex = j.excused ? " · 공가" : "";
  const flags: { label: string; cls: string }[] = [];
  if (!current) flags.push({ label: TRAINING_STATUS_LABEL[r.state], cls: r.state === "dropped" ? "danger" : "paused" });
  else if (r.statusOn === data.date) flags.push({ label: "오늘 상태 변경", cls: "paused" });
  if (absent) flags.push({ label: j.insufficient ? "결석 (수업 50% 미만)" : "결석", cls: "danger" });
  if (leaveAttend) flags.push({ label: `${leaveGroup(r.leave?.kind)} 출석 인정`, cls: "approved" });
  if (notYet) flags.push({ label: "미입실", cls: "paused" });
  if (current && j.late) flags.push({ label: `지각${ex}`, cls: j.excused ? "approved" : "warn" });
  if (current && j.early && final) flags.push({ label: `조퇴${ex}`, cls: j.excused ? "approved" : "warn" });
  if (current && j.outs > 0) flags.push({ label: `외출${j.outs > 1 ? ` ${j.outs}회` : ""}${ex}`, cls: j.excused ? "approved" : "warn" });
  if (missingOut) flags.push({ label: r.dayStatus === "out" ? "복귀 기록 없음" : "퇴실 기록 없음", cls: "pending" });
  const group = leaveGroup(r.leave?.kind);
  if (current && r.leave && j.pending) flags.push({ label: `${group} ${LEAVE_STATUS_LABEL[r.leave.status]}`, cls: LEAVE_STATUS_CLASS[r.leave.status] });
  else if (current && r.leave && !leaveAttend && !flags.some((f) => f.label.includes(group))) {
    flags.push({ label: r.leave.part === "partial" ? `일부 시간 ${group} 승인` : `${group} 승인`, cls: "approved" });
  }
  if (r.corrected) flags.push({ label: "정정", cls: "warn" });
  return { ...r, current, absent, notYet, missingOut, flags };
}

// 정원: 수강 명단 전체(중도탈락·조기취업 포함) / 재적: 훈련중 / 현인원: 지금 강의장에 있는 인원(교육 중)
type Summary = {
  quota: number;
  dropped: number;
  employed: number;
  completed: number;
  enrolled: number;
  inRoom: number;
  present: number;
  presentSick: number;
  presentLeave: number;
  absent: number;
  late: number;
  lateExcused: number;
  early: number;
  earlyExcused: number;
  outs: number;
  outsExcused: number;
  notYet: number;
};

function summarize(rows: Judged[]): Summary {
  const cur = rows.filter((r) => r.current);
  const ok = cur.filter((r) => !r.absent);
  return {
    quota: rows.length,
    dropped: rows.filter((r) => r.state === "dropped").length,
    employed: rows.filter((r) => r.state === "employed").length,
    completed: rows.filter((r) => r.state === "completed").length,
    enrolled: cur.length,
    inRoom: cur.filter((r) => r.dayStatus === "in_class").length,
    present: ok.filter((r) => r.firstCheckInAt || r.judge.leaveAttend).length,
    presentSick: ok.filter((r) => r.judge.leaveAttend && !r.notYet && r.leave?.kind === "sick").length,
    presentLeave: ok.filter((r) => r.judge.leaveAttend && !r.notYet && r.leave?.kind !== "sick").length,
    absent: cur.filter((r) => r.absent).length,
    late: ok.filter((r) => r.judge.late).length,
    lateExcused: ok.filter((r) => r.judge.late && r.judge.excused).length,
    early: ok.filter((r) => r.judge.early && r.flags.some((f) => f.label.startsWith("조퇴"))).length,
    earlyExcused: ok.filter((r) => r.judge.early && r.judge.excused && r.flags.some((f) => f.label.startsWith("조퇴"))).length,
    outs: ok.filter((r) => r.judge.outs > 0).length,
    outsExcused: ok.filter((r) => r.judge.outs > 0 && r.judge.excused).length,
    notYet: cur.filter((r) => r.notYet).length,
  };
}

const hm = (m: number) => `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`;

const withExcused = (n: number, ex: number) => (ex > 0 ? `${n} (공가·병결 ${ex})` : String(n));

export default function ReportBoard() {
  const { operator, region } = useOperator();
  const [date, setDate] = useState(todayInSeoul());
  const [course, setCourse] = useState("");
  const [showAll, setShowAll] = useState(false);
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);

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
  const isToday = !!data && data.date === data.today;
  const showCompleted = total.completed > 0;
  const cols = { isToday, showCompleted, showNotYet: total.notYet > 0 };
  const detail = visible.filter((r) => showAll || r.flags.length > 0 || r.note || r.notices.length > 0);

  const regionName = operator.regions.find((r) => r.code === region)?.name ?? "";

  return (
    <>
      <div className="a-title">
        <div>
          <h1>출결 일보</h1>
          <span className="small">정원·재적·현인원·결석·지각·조퇴를 한 장으로 보고, 교육생별 사유를 적습니다. 보조 자료이며 공식 출석 인정은 LMS 판정을 따릅니다.</span>
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
                    <th>과정</th><th>교육 시간</th><th>정원</th><th>중도탈락</th><th>조기취업</th>{showCompleted && <th>수료</th>}
                    <th>재적</th><th>현인원</th><th>출석</th><th>결석</th><th>지각</th><th>조퇴</th><th>외출</th>
                    {total.notYet > 0 && <th>미입실</th>}
                  </tr>
                </thead>
                <tbody>
                  {summaries.map(({ name, info, s }) => (
                    <tr key={name}>
                      <td><b>{name}</b></td>
                      <td>
                        {!info ? "—" : info.dayOff ? <span className="tag">휴강</span> : (
                          <span>
                            {info.dayStart}~{info.dayEnd}{info.dayPlace && <> · {info.dayPlace}</>}
                            <br /><span className="small">{info.lateAfter}분부터 지각 · <Link href="/admin/courses" className="no-print">일정 변경</Link></span>
                          </span>
                        )}
                      </td>
                      <SummaryCells s={s} {...cols} />
                    </tr>
                  ))}
                  {summaries.length > 1 && (
                    <tr className="total">
                      <td><b>합계</b></td><td />
                      <SummaryCells s={total} {...cols} />
                    </tr>
                  )}
                  {summaries.length === 0 && <tr><td colSpan={13} className="small center">이 날짜에 수강 중인 교육생이 없습니다.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
          <p className="small">
            정원은 처음 시작 인원(중도탈락·조기취업 포함), 재적은 그 중 훈련중인 인원, 현인원은 지금 강의장에 있는 인원(교육 중,
            외출 제외)으로 오늘 날짜에만 표시합니다. 지각은 교육 시작 후 정한 시간(기본 10분)부터, 조퇴는 마지막 퇴실이 교육 종료 전,
            외출은 수업 시간 중 외출입니다. 수업 시간의 50% 이상 참여해야 지각·조퇴·외출이 성립하고, 미만이면 결석입니다.
            결석은 교육 종료 시각이 지나야 확정됩니다. 승인된 공가 날은 출석으로 인정하고 괄호 안에 따로 적습니다(승인 전 공가는 반영하지 않음).
            누적은 과정 시작부터 이 날까지이며, 지각·조퇴·외출 3회를 결석 1회로 환산합니다. 병결은 5일까지 등록할 수 있습니다.
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
                <thead><tr><th>과정</th><th>이름</th><th>구분</th><th>입실</th><th>퇴실</th><th>참여</th><th>누적 (과정 시작~)</th><th>알림 · 공가</th><th style={{ minWidth: 240 }}>사유</th></tr></thead>
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
                      <td className="small">{r.firstCheckInAt ? `${hm(r.eval.attendedMinutes)} / ${hm(r.eval.classMinutes)}` : "—"}</td>
                      <td className="small"><TallyCell row={r} /></td>
                      <td className="small" style={{ whiteSpace: "normal", minWidth: 160 }}>
                        {r.leave && <div>{leaveText(r.leave)} · {LEAVE_STATUS_LABEL[r.leave.status]} — {r.leave.reason}</div>}
                        {r.notices.map((n, i) => <div key={i}>{noticeText(n)} — {n.reason}</div>)}
                        {r.current && !r.leave && (r.absent || r.notYet || r.judge.late || r.judge.early || r.judge.outs > 0) && (
                          <div style={{ marginTop: 4 }}>
                            <LeaveQuick key={`${r.enrollmentId}:${date}`} enrollmentId={r.enrollmentId} date={date}
                              defaultFull={r.absent || r.notYet} defaultReason={r.notices[0]?.reason} onDone={load} />
                          </div>
                        )}
                        {r.current && r.leave && <div style={{ marginTop: 4 }}><LeaveCancel leaveId={r.leave.id} name={r.name} date={date} region={region} onDone={load} /></div>}
                        {!r.current && !r.leave && r.notices.length === 0 && "—"}
                      </td>
                      <td style={{ whiteSpace: "normal" }}>
                        <NoteCell key={`${r.enrollmentId}:${date}`} row={r} date={date} />
                      </td>
                    </tr>
                  ))}
                  {detail.length === 0 && <tr><td colSpan={9} className="small center">특이사항이 있는 교육생이 없습니다.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </>
  );
}

function TallyCell({ row }: { row: Judged }) {
  const t = row.tally;
  const minor = t.late + t.early + t.outs;
  return (
    <>
      <div>
        결석 <b className={t.totalAbsent > 0 ? "num-bad" : undefined}>{t.totalAbsent}</b>
        {t.converted > 0 && <span> (실결석 {t.absent} + 환산 {t.converted})</span>}
        {t.sickAttend > 0 && <span> · 병결 출석 {t.sickAttend}</span>}
        {t.otherAttend > 0 && <span> · 공가 출석 {t.otherAttend}</span>}
      </div>
      {t.rate !== null && <div>출석률 {t.rate}%</div>}
      <div>지각 {t.late} · 조퇴 {t.early} · 외출 {t.outs}{minor % 3 > 0 && <span> (환산까지 {3 - (minor % 3)})</span>}</div>
      <div className={row.sickUsed >= SICK_LIMIT ? "num-bad" : undefined}>병결 {row.sickUsed}/{SICK_LIMIT}일</div>
    </>
  );
}

function SummaryCells({ s, isToday, showCompleted, showNotYet }: { s: Summary; isToday: boolean; showCompleted: boolean; showNotYet: boolean }) {
  return (
    <>
      <td>{s.quota}</td>
      <td>{s.dropped}</td>
      <td>{s.employed}</td>
      {showCompleted && <td>{s.completed}</td>}
      <td><b>{s.enrolled}</b></td>
      <td>{isToday ? <b>{s.inRoom}</b> : "—"}</td>
      <td>{s.present}{(s.presentSick > 0 || s.presentLeave > 0) && <small> ({[s.presentSick && `병결 ${s.presentSick}`, s.presentLeave && `공가 ${s.presentLeave}`].filter(Boolean).join(" · ")})</small>}</td>
      <td className={s.absent > 0 ? "num-bad" : undefined}>{s.absent}</td>
      <td>{withExcused(s.late, s.lateExcused)}</td>
      <td>{withExcused(s.early, s.earlyExcused)}</td>
      <td>{withExcused(s.outs, s.outsExcused)}</td>
      {showNotYet && <td>{s.notYet}</td>}
    </>
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
