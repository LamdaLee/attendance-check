"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import { TRAINING_STATUS_LABEL, formatDate, messageFor, todayInSeoul } from "@/lib/messages";

type Student = {
  enrollmentId: number;
  name: string;
  course: string;
  courseId: number;
  status: string;
  trainingStatus: string;
  statusOn: string | null;
  conflict: boolean;
  lastAttendance: string | null;
  createdAt: string;
};
type Course = { id: number; name: string; isActive: boolean };
type ResultRow = { line: number; name: string; course: string; error: string | null };
type Preview = { applied: boolean; total: number; errors: number; rows: ResultRow[] };

const SAMPLE = "name,last4,course\n홍길동,0123,AX\n김하나,4567,SF";

export default function RosterBoard() {
  const { region } = useOperator();
  const [students, setStudents] = useState<Student[] | null>(null);
  const [courses, setCourses] = useState<Course[]>([]);
  const [course, setCourse] = useState("");
  const [status, setStatus] = useState("training");
  const [query, setQuery] = useState("");
  const [panel, setPanel] = useState<"none" | "add" | "bulk">("none");
  const [editing, setEditing] = useState<Student | null>(null);
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);

  const load = useCallback(async () => {
    const [r, c] = await Promise.all([
      api(`/api/admin/students?region=${encodeURIComponent(region)}`),
      api(`/api/admin/courses?region=${encodeURIComponent(region)}`),
    ]);
    if (!r.ok) setMessage({ kind: "error", text: messageFor(r.code) });
    else setStudents(r.students);
    if (c.ok) setCourses(c.courses);
  }, [region]);

  useEffect(() => {
    setStudents(null);
    void load();
  }, [load]);

  const filtered = useMemo(
    () =>
      (students ?? []).filter(
        (s) =>
          (!course || s.course === course) &&
          (status === "" || s.trainingStatus === status) &&
          (!query || s.name.includes(query.trim())),
      ),
    [students, course, status, query],
  );
  const conflicts = (students ?? []).filter((s) => s.conflict).length;
  const inCourse = (students ?? []).filter((s) => !course || s.course === course);
  const countOf = (t: string) => inCourse.filter((s) => s.trainingStatus === t).length;

  async function done(text: string) {
    setPanel("none");
    setEditing(null);
    setMessage({ kind: "ok", text });
    await load();
  }

  return (
    <>
      <div className="a-title">
        <div>
          <h1>교육생 명단</h1>
          <span className="small">전화번호 뒷자리는 저장하지 않고 대조 값만 보관합니다. 화면에도 표시하지 않습니다.</span>
        </div>
        <div className="row">
          <button className="btn plain" onClick={() => { setPanel("bulk"); setMessage(null); }}>일괄 등록</button>
          <button className="btn" onClick={() => { setPanel("add"); setMessage(null); }}>교육생 추가</button>
        </div>
      </div>

      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      {conflicts > 0 && (
        <p className="notice warn">이름과 뒷자리가 같은 수강 중 교육생이 {conflicts}명 있습니다. 이 조합은 본인 확인이 막힙니다. 한쪽을 중지하거나 뒷자리를 다시 등록해 주세요.</p>
      )}

      {panel === "add" && <AddOne courses={courses} region={region} onDone={done} onCancel={() => setPanel("none")} />}
      {panel === "bulk" && <BulkImport region={region} onDone={done} onCancel={() => setPanel("none")} />}
      {editing && <EditEnrollment student={editing} courses={courses} onDone={done} onCancel={() => setEditing(null)} />}

      <div className="stats" style={{ gridTemplateColumns: "repeat(5, 1fr)" }}>
        <div className="stat"><span>재적{course ? ` · ${course}` : ""}</span><strong>{inCourse.length}</strong></div>
        {Object.entries(TRAINING_STATUS_LABEL).map(([k, v]) => <div className="stat" key={k}><span>{v}</span><strong>{countOf(k)}</strong></div>)}
      </div>

      <div className="filters">
        <label className="field">
          과정
          <select value={course} onChange={(e) => setCourse(e.target.value)}>
            <option value="">전체 과정</option>
            {courses.map((c) => <option key={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="field">
          훈련 상태
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            {Object.entries(TRAINING_STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            <option value="">전체</option>
          </select>
        </label>
        <label className="field">이름<input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="이름 검색" /></label>
      </div>

      <div className="table-card">
        <div className="table-wrap">
          <table>
            <thead><tr><th>이름</th><th>과정</th><th>훈련 상태</th><th>본인 대조</th><th>최근 출결</th><th>관리</th></tr></thead>
            <tbody>
              {filtered.map((s) => (
                <tr key={s.enrollmentId}>
                  <td><Link href={`/admin/students/${s.enrollmentId}`}><b>{s.name}</b></Link></td>
                  <td>{s.course}</td>
                  <td><TrainingTag student={s} /></td>
                  <td>{s.conflict ? <span className="tag danger">중복 조합 확인</span> : <span className="small">등록됨</span>}</td>
                  <td className="small">{s.lastAttendance ? formatDate(s.lastAttendance) : "—"}</td>
                  <td><button className="btn plain sm" onClick={() => { setEditing(s); setPanel("none"); setMessage(null); }}>관리</button></td>
                </tr>
              ))}
              {students && filtered.length === 0 && <tr><td colSpan={6} className="small center">조건에 맞는 교육생이 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      <p className="small">교육생은 지우지 않습니다. 중도탈락·조기취업·수료로 바꾸면 그 날짜부터 현인원에서 빠지고 출결 입력이 막히며, 과거 기록은 그대로 남습니다.</p>
    </>
  );
}

export function TrainingTag({ student }: { student: { trainingStatus: string; statusOn: string | null; status: string } }) {
  const t = student.trainingStatus;
  const cls = t === "training" ? (student.status === "paused" ? "paused" : "active") : t === "dropped" ? "danger" : t === "employed" ? "brand" : "paused";
  return (
    <span className={`tag ${cls}`}>
      {TRAINING_STATUS_LABEL[t]}
      {t === "training" && student.status === "paused" && " · 입력 중지"}
      {student.statusOn && ` · ${formatDate(student.statusOn)}`}
    </span>
  );
}

function PreviewTable({ preview }: { preview: Preview }) {
  return (
    <div className="table-wrap" style={{ marginTop: 10 }}>
      <table>
        <thead><tr><th>줄</th><th>이름</th><th>과정</th><th>결과</th></tr></thead>
        <tbody>
          {preview.rows.map((r) => (
            <tr key={r.line}>
              <td>{r.line}</td>
              <td>{r.name}</td>
              <td>{r.course}</td>
              <td>{r.error ? <span style={{ color: "var(--danger)" }}>{messageFor(r.error)}</span> : <span className="tag active">등록 가능</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AddOne({ courses, region, onDone, onCancel }: { courses: Course[]; region: string; onDone: (t: string) => void; onCancel: () => void }) {
  const [name, setName] = useState("");
  const [last4, setLast4] = useState("");
  const [course, setCourse] = useState(courses.find((c) => c.isActive)?.name ?? "");
  const [error, setError] = useState<string | null>(null);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    const r = await api("/api/admin/students", { region, rows: [{ name, last4, course }], apply: true });
    if (!r.ok || !r.applied) {
      setError(messageFor(r.rows?.[0]?.error ?? r.code));
      return;
    }
    onDone(`${name.trim()} 교육생을 등록했습니다.`);
  }

  return (
    <form className="panel" onSubmit={save}>
      <h2>교육생 추가</h2>
      <div className="grid-2" style={{ gridTemplateColumns: "1fr 1fr 1fr" }}>
        <label className="field">이름<input value={name} onChange={(e) => setName(e.target.value)} required maxLength={40} /></label>
        <label className="field">전화번호 뒷자리<input value={last4} onChange={(e) => setLast4(e.target.value.replace(/\D/g, "").slice(0, 4))} inputMode="numeric" required placeholder="0000" /></label>
        <label className="field">
          과정
          <select value={course} onChange={(e) => setCourse(e.target.value)} required>
            {courses.filter((c) => c.isActive).map((c) => <option key={c.id}>{c.name}</option>)}
          </select>
        </label>
      </div>
      {error && <p className="notice error">{error}</p>}
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn plain" onClick={onCancel}>취소</button>
        <button className="btn">등록</button>
      </div>
    </form>
  );
}

function BulkImport({ region, onDone, onCancel }: { region: string; onDone: (t: string) => void; onCancel: () => void }) {
  const [csv, setCsv] = useState("");
  const [preview, setPreview] = useState<Preview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function readFile(file: File) {
    setCsv(await file.text());
    setPreview(null);
  }

  async function run(apply: boolean) {
    setBusy(true);
    setError(null);
    const r = await api("/api/admin/students", { region, csv, apply });
    setBusy(false);
    if (!r.rows) {
      setError(messageFor(r.code));
      return;
    }
    if (apply && r.applied) {
      onDone(`${r.total}명을 등록했습니다.`);
      return;
    }
    setPreview(r as unknown as Preview);
  }

  return (
    <div className="panel">
      <h2>일괄 등록</h2>
      <p className="small">
        CSV 파일을 고르거나 아래에 붙여 넣으세요. 첫 줄은 머리글 <span className="mono">name,last4,course</span> 입니다.
        엑셀에서 만들 때는 뒷자리 열을 텍스트로 두어야 앞의 0이 유지됩니다. 먼저 검증한 뒤, 오류가 없을 때만 저장할 수 있습니다.
      </p>
      <input type="file" accept=".csv,text/csv" onChange={(e) => e.target.files?.[0] && readFile(e.target.files[0])} />
      <label className="field" style={{ marginTop: 10 }}>
        내용
        <textarea className="mono" style={{ minHeight: 130 }} value={csv} onChange={(e) => { setCsv(e.target.value); setPreview(null); }} placeholder={SAMPLE} />
      </label>
      {error && <p className="notice error">{error}</p>}
      {preview && (
        <p className={`notice ${preview.errors ? "error" : "ok"}`}>
          전체 {preview.total}행 · 등록 가능 {preview.total - preview.errors}행 · 오류 {preview.errors}행
          {preview.errors > 0 && " — 오류를 고친 뒤 다시 검증해 주세요."}
        </p>
      )}
      {preview && <PreviewTable preview={preview} />}
      <div className="row" style={{ justifyContent: "flex-end", marginTop: 12 }}>
        <button className="btn plain" onClick={onCancel}>취소</button>
        <button className="btn ghost" onClick={() => run(false)} disabled={busy || !csv.trim()}>검증</button>
        <button className="btn" onClick={() => run(true)} disabled={busy || !preview || preview.errors > 0}>저장</button>
      </div>
    </div>
  );
}

function EditEnrollment({ student, courses, onDone, onCancel }: { student: Student; courses: Course[]; onDone: (t: string) => void; onCancel: () => void }) {
  const [training, setTraining] = useState(student.trainingStatus);
  const [status, setStatus] = useState(student.status === "paused" ? "paused" : "active");
  const [statusOn, setStatusOn] = useState(student.statusOn ?? todayInSeoul());
  const [courseId, setCourseId] = useState(student.courseId);
  const [last4, setLast4] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    const r = await api(`/api/admin/students/${student.enrollmentId}`, {
      status, courseId, last4: last4 || undefined, reason,
      trainingStatus: training, statusOn: training === "training" ? null : statusOn,
    });
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    onDone(`${student.name} 교육생 정보를 변경했습니다.`);
  }

  return (
    <form className="panel" onSubmit={save}>
      <h2>{student.name} · 수강 정보 관리</h2>
      <div className="grid-2">
        <label className="field">
          훈련 상태
          <select value={training} onChange={(e) => setTraining(e.target.value)}>
            {Object.entries(TRAINING_STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </label>
        {training === "training" ? (
          <label className="field">
            출결 입력
            <select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="active">가능</option>
              <option value="paused">일시 중지 (출결 입력 차단)</option>
            </select>
          </label>
        ) : (
          <label className="field">
            {TRAINING_STATUS_LABEL[training]} 일자 (이 날부터 현인원에서 제외)
            <input type="date" value={statusOn} onChange={(e) => setStatusOn(e.target.value)} required />
          </label>
        )}
        <label className="field">
          과정
          <select value={courseId} onChange={(e) => setCourseId(Number(e.target.value))}>
            {courses.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="field">
          전화번호 뒷자리 다시 등록 (바꿀 때만)
          <input value={last4} onChange={(e) => setLast4(e.target.value.replace(/\D/g, "").slice(0, 4))} inputMode="numeric" placeholder="변경 없음" />
        </label>
        <label className="field">
          변경 사유 (필수)
          <input value={reason} onChange={(e) => setReason(e.target.value)} required placeholder="예: 개인 사정으로 중도탈락, 번호 변경" />
        </label>
      </div>
      {error && <p className="notice error">{error}</p>}
      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button type="button" className="btn plain" onClick={onCancel}>취소</button>
        <button className="btn">저장</button>
      </div>
    </form>
  );
}
