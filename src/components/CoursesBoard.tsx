"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import { addDays, formatDate, messageFor } from "@/lib/messages";

type Course = {
  id: number;
  name: string;
  fullName: string;
  isActive: boolean;
  startsOn: string | null;
  endsOn: string | null;
  classStart: string;
  classEnd: string;
  lateAfter: number;
  trainingMinutes: number;
  lmsUrl: string;
  students: number;
};
type Day = { date: string; kind: "class" | "off"; start: string | null; end: string | null; minutes: number | null; place: string; note: string };
type Msg = { kind: "ok" | "error"; text: string } | null;

const hours = (m: number | null | undefined) => (m == null ? "—" : `${Number.isInteger(m / 60) ? m / 60 : (m / 60).toFixed(1)}시간`);
const weekday = (d: string) => ["일", "월", "화", "수", "목", "금", "토"][new Date(`${d}T00:00:00Z`).getUTCDay()];
const isWeekday = (d: string) => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return w >= 1 && w <= 5; };
const toMin = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
// 점심 1시간을 뺀 훈련시간 (4시간 이하는 그대로)
const defaultMinutes = (start: string, end: string) => { const span = toMin(end) - toMin(start); return span > 240 ? span - 60 : span; };

export default function CoursesBoard() {
  const { region } = useOperator();
  const [courses, setCourses] = useState<Course[] | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [message, setMessage] = useState<Msg>(null);
  const [newName, setNewName] = useState("");

  const load = useCallback(async () => {
    const r = await api(`/api/admin/courses?region=${encodeURIComponent(region)}`);
    if (!r.ok) return setMessage({ kind: "error", text: messageFor(r.code) });
    setCourses(r.courses);
    setSelected((cur) => (cur && (r.courses as Course[]).some((c) => c.id === cur) ? cur : r.courses[0]?.id ?? null));
  }, [region]);

  useEffect(() => {
    setCourses(null);
    void load();
  }, [load]);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    const r = await api("/api/admin/courses", { action: "create", region, name: newName });
    if (!r.ok) return setMessage({ kind: "error", text: messageFor(r.code) });
    setNewName("");
    setMessage({ kind: "ok", text: `${newName.trim()} 과정을 추가했습니다. 기간과 시간을 설정해 주세요.` });
    await load();
    setSelected(r.id);
  }

  const course = courses?.find((c) => c.id === selected) ?? null;

  return (
    <>
      <div className="a-title">
        <div>
          <h1>과정 · 일정</h1>
          <span className="small">과정 기간과 기본 교육 시간, 날짜별 일정(평택 러닝센터·휴강)을 관리합니다. 시작일이 있는 과정은 기간 안의 평일에서 휴강일을 뺀 날을 수업일로 봅니다.</span>
        </div>
        <form className="row" onSubmit={create}>
          <input value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="새 과정 짧은 이름 (예: AX)" maxLength={40} required
            style={{ padding: "9px 11px", border: "1.5px solid var(--line)", borderRadius: 10 }} />
          <button className="btn">과정 추가</button>
        </form>
      </div>
      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}

      <div className="split">
        <div>
        <div className="list">
          {courses?.map((c) => (
            <button key={c.id} className={`item ${c.id === selected ? "on" : ""}`} onClick={() => { setSelected(c.id); setMessage(null); }}>
              <b>{c.name}</b> {!c.isActive && <span className="tag">사용 안 함</span>}
              <div className="meta">{c.fullName || "정식 이름 없음"}</div>
              <div className="meta">
                {c.startsOn ? `${formatDate(c.startsOn)} ~ ${c.endsOn ? formatDate(c.endsOn) : ""}` : "기간 미설정 (기록 기준 수업일)"} · 훈련중 {c.students}명
              </div>
            </button>
          ))}
          {courses?.length === 0 && <p className="small" style={{ padding: 14 }}>과정이 없습니다.</p>}
        </div>
        <QuickLinks region={region} />
        <InstitutionSetting region={region} />
        </div>
        {course && <CourseDetail key={course.id} course={course} onSaved={async (t) => { setMessage({ kind: "ok", text: t }); await load(); }} />}
      </div>
    </>
  );
}

// 학생 화면 바로가기 (지역 공통): LMS 로그인, 런치패스 등. 본인 확인 전에도 보인다.
type Link = { id: number; label: string; url: string; sortOrder: number };

function QuickLinks({ region }: { region: string }) {
  const [links, setLinks] = useState<Link[]>([]);
  const [label, setLabel] = useState("");
  const [url, setUrl] = useState("");
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/links?region=${encodeURIComponent(region)}`);
    if (r.ok) setLinks(r.links);
  }, [region]);

  useEffect(() => {
    void load();
  }, [load]);

  async function save(body: Record<string, unknown>) {
    const r = await api("/api/admin/links", { region, ...body });
    if (!r.ok) {
      setError(messageFor(r.code));
      return false;
    }
    setError(null);
    await load();
    return true;
  }

  return (
    <div className="panel" style={{ marginTop: 14 }}>
      <h2>학생 화면 바로가기</h2>
      <p className="small">이 지역 교육생 화면 아래쪽에 버튼으로 보입니다(본인 확인 전에도 보임). 예: LMS 로그인(출결확인서·공가서류), 런치패스.</p>
      <ul className="mini-list">
        {links.map((l) => (
          <li key={l.id}>
            <span style={{ minWidth: 0, overflowWrap: "anywhere" }}><b>{l.label}</b><br /><span className="small mono">{l.url}</span></span>
            <button className="btn plain sm" style={{ whiteSpace: "nowrap" }} onClick={() => window.confirm(`${l.label} 바로가기를 지울까요?`) && save({ id: l.id, delete: true })}>지우기</button>
          </li>
        ))}
      </ul>
      <form className="row" style={{ marginTop: 10 }} onSubmit={async (e) => {
        e.preventDefault();
        if (await save({ label, url, sortOrder: links.length + 1 })) { setLabel(""); setUrl(""); }
      }}>
        <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="버튼 이름" maxLength={30} required
          style={{ flex: 1, minWidth: 140, padding: "9px 11px", border: "1.5px solid var(--line)", borderRadius: 10 }} />
        <input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://" maxLength={500} required
          style={{ flex: 1, minWidth: 220, padding: "9px 11px", border: "1.5px solid var(--line)", borderRadius: 10 }} />
        <button className="btn">추가</button>
      </form>
      {error && <p className="notice error">{error}</p>}
    </div>
  );
}

function CourseDetail({ course, onSaved }: { course: Course; onSaved: (t: string) => void }) {
  const [form, setForm] = useState({
    fullName: course.fullName,
    startsOn: course.startsOn ?? "",
    endsOn: course.endsOn ?? "",
    start: course.classStart,
    end: course.classEnd,
    lateAfter: course.lateAfter,
    trainingHours: course.trainingMinutes / 60,
    active: course.isActive,
  });
  const [error, setError] = useState<string | null>(null);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm({ ...form, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.type === "number" ? Number(e.target.value) : e.target.value });

  async function save(e: React.FormEvent) {
    e.preventDefault();
    const r = await api("/api/admin/courses", {
      action: "save", courseId: course.id, fullName: form.fullName, startsOn: form.startsOn || null, endsOn: form.endsOn || null,
      start: form.start, end: form.end, lateAfter: form.lateAfter, trainingMinutes: Math.round(form.trainingHours * 60), active: form.active,
    });
    if (!r.ok) return setError(messageFor(r.code));
    setError(null);
    onSaved(`${course.name} 과정 설정을 저장했습니다.`);
  }

  return (
    <div>
      <form className="panel" onSubmit={save}>
        <h2>{course.name} 설정</h2>
        <div className="grid-2">
          <label className="field">정식 이름 (출석확인서에 표시)<input value={form.fullName} onChange={set("fullName")} maxLength={120} placeholder="예: LG전자 K뉴딜 아카데미 AX 워크플로우" /></label>
          <label className="field">
            <span className="row" style={{ gap: 6 }}>
              <input type="checkbox" checked={form.active} onChange={set("active")} style={{ width: "auto", margin: 0 }} /> 사용 중인 과정
            </span>
          </label>
          <label className="field">시작일<input type="date" value={form.startsOn} onChange={set("startsOn")} /></label>
          <label className="field">종료일<input type="date" value={form.endsOn} min={form.startsOn} onChange={set("endsOn")} /></label>
          <label className="field">기본 시작 시각<input type="time" value={form.start} onChange={set("start")} required /></label>
          <label className="field">기본 종료 시각<input type="time" value={form.end} onChange={set("end")} required /></label>
          <label className="field">지각 기준 (시작 후 몇 분부터)<input type="number" min={0} max={120} value={form.lateAfter} onChange={set("lateAfter")} required /></label>
          <label className="field">하루 훈련시간 (시간)<input type="number" min={0} max={24} step={0.5} value={form.trainingHours} onChange={set("trainingHours")} required /></label>
        </div>
        {error && <p className="notice error">{error}</p>}
        <div className="row" style={{ justifyContent: "flex-end" }}><button className="btn">저장</button></div>
      </form>
      <LmsLink course={course} onSaved={onSaved} />
      <Schedule course={course} />
    </div>
  );
}

// 학생 화면에서 출결 기록 뒤 LMS 로 바로 넘어가는 주소
function LmsLink({ course, onSaved }: { course: Course; onSaved: (t: string) => void }) {
  const [url, setUrl] = useState(course.lmsUrl);
  const [error, setError] = useState<string | null>(null);
  async function save(e: React.FormEvent) {
    e.preventDefault();
    const r = await api("/api/admin/courses", { action: "lms", courseId: course.id, url });
    if (!r.ok) return setError(messageFor(r.code));
    setError(null);
    onSaved(url.trim() ? `${course.name} LMS 바로가기를 저장했습니다.` : `${course.name} LMS 바로가기를 껐습니다.`);
  }
  return (
    <form className="panel" onSubmit={save}>
      <h2>LMS 바로가기</h2>
      <p className="small">교육생이 이 앱에서 입실·퇴실을 기록한 뒤 바로 LMS 출결 화면으로 넘어가는 버튼을 보여 줍니다. LMS 출결 화면 주소(https://…)를 넣고, 비우면 버튼을 숨깁니다. 교육생별 개인 주소가 아니라 모두에게 같은 주소여야 합니다.</p>
      <div className="row">
        <input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://" maxLength={500}
          style={{ flex: 1, minWidth: 220, padding: "9px 11px", border: "1.5px solid var(--line)", borderRadius: 10 }} />
        <button className="btn" disabled={url.trim() === course.lmsUrl}>저장</button>
      </div>
      {error && <p className="notice error">{error}</p>}
    </form>
  );
}

function Schedule({ course }: { course: Course }) {
  const [days, setDays] = useState<Day[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const [message, setMessage] = useState<Msg>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/courses?days=${course.id}`);
    if (r.ok) setDays(r.days);
  }, [course.id]);

  useEffect(() => {
    void load();
  }, [load]);

  const byDate = useMemo(() => new Map(days.map((d) => [d.date, d])), [days]);
  const dates = useMemo(() => {
    if (!course.startsOn || !course.endsOn) return days.map((d) => d.date);
    const out: string[] = [];
    for (let d = course.startsOn; d <= course.endsOn; d = addDays(d, 1)) if (isWeekday(d) || byDate.has(d)) out.push(d);
    return out;
  }, [course.startsOn, course.endsOn, days, byDate]);
  const classCount = dates.filter((d) => byDate.get(d)?.kind !== "off").length;
  const totalMinutes = dates.reduce((s, d) => {
    const x = byDate.get(d);
    return s + (x?.kind === "off" ? 0 : x?.kind === "class" ? x.minutes ?? 0 : course.trainingMinutes);
  }, 0);

  async function setDay(date: string, body: { kind: "class" | "off" | "clear"; start?: string; end?: string; minutes?: number; place?: string; note?: string }) {
    const r = await api("/api/admin/courses", { action: "day", courseId: course.id, date, ...body });
    if (!r.ok) {
      setMessage({ kind: "error", text: messageFor(r.code) });
      return false;
    }
    return true;
  }

  return (
    <div className="panel">
      <div className="row between">
        <h2 style={{ margin: 0 }}>날짜별 일정</h2>
        <span className="small">수업일 {classCount}일 · 총 훈련시간 {hours(totalMinutes)}</span>
      </div>
      {!course.startsOn && <p className="notice warn">시작일과 종료일을 먼저 저장하면 기간 전체 일정이 보입니다.</p>}
      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      <PyeongtaekPreset course={course} onApply={async (entries) => {
        for (const e of entries) if (!(await setDay(e.date, { kind: "class", ...e }))) return;
        setMessage({ kind: "ok", text: `${formatDate(entries[0].date)} 주를 평택 러닝센터 일정으로 지정했습니다.` });
        await load();
      }} />
      <div className="table-wrap" style={{ marginTop: 10 }}>
        <table>
          <thead><tr><th>날짜</th><th>구분</th><th>시간</th><th>훈련시간</th><th>장소 · 비고</th><th /></tr></thead>
          <tbody>
            {dates.map((d) => {
              const x = byDate.get(d);
              return editing === d ? (
                <DayEditor key={d} date={d} course={course} day={x} onCancel={() => setEditing(null)} onSave={async (body) => {
                  if (await setDay(d, body)) { setEditing(null); setMessage(null); await load(); }
                }} />
              ) : (
                <tr key={d} style={x?.kind === "off" ? { opacity: 0.55 } : undefined}>
                  <td>{formatDate(d)}</td>
                  <td>{x?.kind === "off" ? <span className="tag">휴강</span> : x ? <span className="tag brand">지정</span> : <span className="small">기본</span>}</td>
                  <td>{x?.kind === "off" ? "—" : x ? `${x.start}~${x.end}` : `${course.classStart}~${course.classEnd}`}</td>
                  <td>{x?.kind === "off" ? "—" : hours(x ? x.minutes : course.trainingMinutes)}</td>
                  <td className="small">{[x?.place, x?.note].filter(Boolean).join(" · ") || "—"}</td>
                  <td>
                    <span className="row" style={{ gap: 6 }}>
                      <button className="btn plain sm" onClick={() => setEditing(d)}>시간 지정</button>
                      {x?.kind !== "off" && <button className="btn plain sm" onClick={async () => {
                        const note = window.prompt(`${formatDate(d)}을 휴강으로 지정합니다. 사유(예: 공휴일)를 적어 주세요.`, "");
                        if (note !== null && (await setDay(d, { kind: "off", note }))) await load();
                      }}>휴강</button>}
                      {x && <button className="btn plain sm" onClick={async () => { if (await setDay(d, { kind: "clear" })) await load(); }}>기본으로</button>}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <p className="small">휴강일은 수업일에서 빠집니다(결석 계산 제외). 주말에 수업하는 날은 위에 없으므로, 필요하면 알려 주세요.</p>
    </div>
  );
}

function DayEditor({ date, course, day, onSave, onCancel }: {
  date: string;
  course: Course;
  day: Day | undefined;
  onSave: (b: { kind: "class"; start: string; end: string; minutes: number; place: string; note: string }) => void;
  onCancel: () => void;
}) {
  const [start, setStart] = useState(day?.start ?? course.classStart);
  const [end, setEnd] = useState(day?.end ?? course.classEnd);
  const [h, setH] = useState((day?.minutes ?? course.trainingMinutes) / 60);
  const [place, setPlace] = useState(day?.place ?? "");
  const [note, setNote] = useState(day?.note ?? "");
  return (
    <tr style={{ background: "var(--brand-soft)" }}>
      <td>{formatDate(date)}</td>
      <td><span className="tag brand">지정</span></td>
      <td>
        <span className="row" style={{ gap: 4, flexWrap: "nowrap" }}>
          <input type="time" className="time-sm" value={start} onChange={(e) => setStart(e.target.value)} />~
          <input type="time" className="time-sm" value={end} onChange={(e) => setEnd(e.target.value)} />
        </span>
      </td>
      <td><input type="number" className="time-sm" style={{ width: 70 }} min={0} max={24} step={0.5} value={h} onChange={(e) => setH(Number(e.target.value))} />시간</td>
      <td>
        <span className="row" style={{ gap: 4, flexWrap: "nowrap" }}>
          <input className="time-sm" style={{ width: 110 }} value={place} onChange={(e) => setPlace(e.target.value)} placeholder="장소" />
          <input className="time-sm" style={{ width: 110 }} value={note} onChange={(e) => setNote(e.target.value)} placeholder="비고" />
        </span>
      </td>
      <td>
        <span className="row" style={{ gap: 6, flexWrap: "nowrap" }}>
          <button className="btn sm" onClick={() => onSave({ kind: "class", start, end, minutes: Math.round(h * 60), place, note })}>저장</button>
          <button className="btn plain sm" onClick={onCancel}>취소</button>
        </span>
      </td>
    </tr>
  );
}

// 평택 입소 주간 한 번에 지정: 1일차 입소 시간, 2~4일차 08:00~17:00, 5일차 퇴소 시간
function PyeongtaekPreset({ course, onApply }: { course: Course; onApply: (e: { date: string; start: string; end: string; minutes: number; place: string; note: string }[]) => void }) {
  const [open, setOpen] = useState(false);
  const [monday, setMonday] = useState(course.startsOn ?? "");
  const [firstStart, setFirstStart] = useState("11:00");
  const [firstEnd, setFirstEnd] = useState("17:00");
  const [lastEnd, setLastEnd] = useState("15:00");
  const [label, setLabel] = useState("1주차 입소");

  if (!open) return <button className="btn ghost sm" onClick={() => { if (!monday) setMonday(course.startsOn ?? ""); setOpen(true); }}>평택 입소 주간 한 번에 지정</button>;

  function apply() {
    if (!monday) return;
    const plan: [string, string][] = [[firstStart, firstEnd], ["08:00", "17:00"], ["08:00", "17:00"], ["08:00", "17:00"], ["08:00", lastEnd]];
    onApply(plan.map(([s, e], i) => ({ date: addDays(monday, i), start: s, end: e, minutes: defaultMinutes(s, e), place: "평택 러닝센터", note: label })));
    setOpen(false);
  }

  return (
    <div className="panel" style={{ background: "#fafbfe", marginBottom: 0 }}>
      <div className="row">
        <label className="field" style={{ margin: 0 }}>입소일(월)<input type="date" value={monday} onChange={(e) => setMonday(e.target.value)} /></label>
        <label className="field" style={{ margin: 0 }}>1일차<span className="row" style={{ gap: 4, flexWrap: "nowrap" }}>
          <input type="time" className="time-sm" value={firstStart} onChange={(e) => setFirstStart(e.target.value)} />~
          <input type="time" className="time-sm" value={firstEnd} onChange={(e) => setFirstEnd(e.target.value)} /></span></label>
        <label className="field" style={{ margin: 0 }}>5일차 퇴소<input type="time" className="time-sm" value={lastEnd} onChange={(e) => setLastEnd(e.target.value)} /></label>
        <label className="field" style={{ margin: 0 }}>비고<input className="time-sm" style={{ width: 110 }} value={label} onChange={(e) => setLabel(e.target.value)} /></label>
      </div>
      <p className="small">2~4일차는 08:00~17:00, 5일차는 08:00부터입니다. 하루 훈련시간은 점심 1시간을 뺀 값으로 넣고, 아래 표에서 날짜별로 고칠 수 있습니다.</p>
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button className="btn plain sm" onClick={() => setOpen(false)}>취소</button>
        <button className="btn sm" onClick={apply} disabled={!monday}>5일 지정</button>
      </div>
    </div>
  );
}

// 출석확인서에 들어가는 기관명
function InstitutionSetting({ region }: { region: string }) {
  const [name, setName] = useState("");
  const [saved, setSaved] = useState("");
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    api("/api/admin/institution").then((r) => {
      if (!r.ok) return;
      const v = (r.regions as { code: string; institution: string }[]).find((x) => x.code === region)?.institution ?? "";
      setName(v);
      setSaved(v);
    });
  }, [region]);

  async function save() {
    const r = await api("/api/admin/institution", { region, name });
    setMessage(r.ok ? "저장했습니다." : messageFor(r.code));
    if (r.ok) setSaved(name.trim());
  }

  return (
    <div className="panel" style={{ marginTop: 14 }}>
      <h2>출석확인서 기관명</h2>
      <p className="small">교육생이 만드는 출석확인서의 &lsquo;훈련기관&rsquo;과 서명란에 들어갑니다.</p>
      <div className="row">
        <input value={name} onChange={(e) => { setName(e.target.value); setMessage(null); }} maxLength={80} placeholder="예: ○○교육원 대전캠퍼스"
          style={{ flex: 1, minWidth: 220, padding: "9px 11px", border: "1.5px solid var(--line)", borderRadius: 10 }} />
        <button className="btn" onClick={save} disabled={name.trim() === saved}>저장</button>
        {message && <span className="small">{message}</span>}
      </div>
    </div>
  );
}
