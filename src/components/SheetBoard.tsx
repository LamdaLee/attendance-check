"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useOperator } from "./AdminShell";
import { cellMark, type Cell } from "./Certificate";
import { api } from "@/lib/client";
import { TRAINING_STATUS_LABEL, addDays, formatDate, formatDateTime, messageFor, todayInSeoul } from "@/lib/messages";

type Student = { enrollmentId: number; name: string; trainingStatus: string; statusOn: string | null; cells: Cell[]; startIndex: number };
type Sheet = {
  course: { id: number; name: string; startsOn: string | null; endsOn: string | null; firstDay: string | null };
  from: string;
  to: string;
  days: string[];
  students: Student[];
};
type Course = { id: number; name: string; isActive: boolean };

function addMonths(date: string, n: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1 + n, d)).toISOString().slice(0, 10);
}

// 단위기간: 과정 시작일부터 한 달씩
function unitPeriods(base: string, until: string): { n: number; from: string; to: string }[] {
  const out = [];
  for (let n = 0; n < 24; n++) {
    const from = addMonths(base, n);
    if (from > until) break;
    out.push({ n: n + 1, from, to: addDays(addMonths(base, n + 1), -1) });
  }
  return out;
}

function totals(cells: Cell[]) {
  const t = { days: 0, absent: 0, leave: 0, sick: 0, late: 0, early: 0, outs: 0 };
  for (const c of cells) {
    if (c.state !== "training" || c.open) continue;
    t.days++;
    if (c.absent) t.absent++;
    else {
      if (c.leaveAttend) {
        if (c.leaveKind === "sick") t.sick++;
        else t.leave++;
      }
      if (c.late) t.late++;
      if (c.early) t.early++;
      t.outs += c.outs ?? 0;
    }
  }
  const converted = Math.floor((t.late + t.early + t.outs) / 3);
  const rate = t.days ? Math.round((1000 * (t.days - t.absent - converted)) / t.days) / 10 : null;
  return { ...t, converted, attended: t.days - t.absent, rate };
}

const weekday = (d: string) => ["일", "월", "화", "수", "목", "금", "토"][new Date(`${d}T00:00:00Z`).getUTCDay()];

export default function SheetBoard({ enrollmentId }: { enrollmentId: number | null }) {
  const { operator, region } = useOperator();
  const today = todayInSeoul();
  const [courses, setCourses] = useState<Course[]>([]);
  const [courseId, setCourseId] = useState<number | null>(null);
  const [from, setFrom] = useState(today.slice(0, 8) + "01");
  const [to, setTo] = useState(today);
  const [sheet, setSheet] = useState<Sheet | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (enrollmentId) return;
    api(`/api/admin/courses?region=${encodeURIComponent(region)}`).then((r) => {
      if (!r.ok) return;
      const list = (r.courses as Course[]).filter((c) => c.isActive);
      setCourses(list);
      setCourseId((cur) => (cur && list.some((c) => c.id === cur) ? cur : list[0]?.id ?? null));
    });
  }, [region, enrollmentId]);

  const load = useCallback(async () => {
    if (!enrollmentId && !courseId) return;
    const target = enrollmentId ? `enrollment=${enrollmentId}` : `course=${courseId}`;
    const r = await api(`/api/admin/sheet?region=${encodeURIComponent(region)}&${target}&from=${from}&to=${to}`);
    if (!r.ok) {
      setError(messageFor(r.code));
      setSheet(null);
    } else {
      setError(null);
      setSheet(r as unknown as Sheet);
    }
  }, [region, enrollmentId, courseId, from, to]);

  useEffect(() => {
    void load();
  }, [load]);

  const base = sheet?.course.startsOn ?? sheet?.course.firstDay ?? null;
  const units = useMemo(() => (base ? unitPeriods(base, today) : []), [base, today]);
  const currentUnit = units.find((u) => u.from === from && u.to === to)?.n ?? "";
  const single = !!enrollmentId && sheet?.students.length === 1 ? sheet.students[0] : null;
  const regionName = operator.regions.find((r) => r.code === region)?.name ?? "";

  return (
    <>
      <style>{"@media print { @page { size: A4 landscape; margin: 10mm; } }"}</style>
      <div className="a-title">
        <div>
          {single && <Link href={`/admin/students/${single.enrollmentId}`} className="small">← {single.name} 기록</Link>}
          <h1>{single ? `${single.name} 개인 출석부` : "단위기간 출석부"}</h1>
          <span className="small">과정의 수업일(기록이 있는 평일)마다 판정을 표시합니다. 승인된 공가는 출석으로 인정합니다.</span>
        </div>
        <div className="row no-print">
          <button className="btn plain" onClick={() => window.print()}>인쇄 · PDF</button>
        </div>
      </div>

      <div className="print-meta">
        {regionName} 지역 · {sheet?.course.name} · {formatDate(from)} ~ {formatDate(to)} · 출력 {formatDateTime(new Date().toISOString())} · {operator.operatorName}
      </div>

      <div className="filters">
        {!enrollmentId && (
          <label className="field">
            과정
            <select value={courseId ?? ""} onChange={(e) => setCourseId(Number(e.target.value))}>
              {courses.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
        )}
        <label className="field">
          단위기간
          <select value={currentUnit} onChange={(e) => {
            const u = units.find((x) => x.n === Number(e.target.value));
            if (u) { setFrom(u.from); setTo(u.to); }
          }}>
            <option value="">직접 선택</option>
            {units.map((u) => <option key={u.n} value={u.n}>{u.n}단위 ({formatDate(u.from)} ~ {formatDate(u.to)})</option>)}
          </select>
        </label>
        <label className="field">시작일<input type="date" value={from} max={to} onChange={(e) => e.target.value && setFrom(e.target.value)} /></label>
        <label className="field">종료일<input type="date" value={to} min={from} max={addDays(from, 61)} onChange={(e) => e.target.value && setTo(e.target.value)} /></label>
      </div>

      {error && <p className="notice error">{error}</p>}

      {sheet && (
        <>
          <div className="legend">
            <span><b className="m-ok">○</b> 출석</span>
            <span><b className="m-warn">지</b> 지각</span>
            <span><b className="m-warn">조</b> 조퇴</span>
            <span><b className="m-warn">외</b> 외출</span>
            <span><b className="m-bad">결</b> 결석(수업 50% 미만 포함)</span>
            <span><b className="m-leave">병</b> 병결 · <b className="m-leave">공</b> 공가 (둘 다 출석 인정)</span>
            <span>빈칸: 수강 전·중도탈락 이후 · 지각·조퇴·외출 3회 = 결석 1회</span>
          </div>
          <div className="table-card">
            <div className="table-wrap">
              <table className="sheet">
                <thead>
                  <tr>
                    <th className="name">이름</th>
                    {sheet.days.map((d) => <th key={d}>{Number(d.slice(5, 7))}/{Number(d.slice(8))}<br />{weekday(d)}</th>)}
                    <th className="sum">수업</th><th className="sum">출석</th><th className="sum">결석</th><th className="sum">지각</th>
                    <th className="sum">조퇴</th><th className="sum">외출</th><th className="sum">환산</th><th className="sum">출석률</th>
                  </tr>
                </thead>
                <tbody>
                  {sheet.students.map((s) => {
                    const cells: Cell[] = [...Array(s.startIndex).fill({ state: "before" }), ...s.cells];
                    const t = totals(cells);
                    return (
                      <tr key={s.enrollmentId}>
                        <td className="name">
                          <Link href={`/admin/students/${s.enrollmentId}`}><b>{s.name}</b></Link>
                          {s.trainingStatus !== "training" && <div className="small">{TRAINING_STATUS_LABEL[s.trainingStatus]} {s.statusOn && formatDate(s.statusOn)}</div>}
                        </td>
                        {cells.map((c, i) => {
                          const m = cellMark(c);
                          return <td key={i} className={`m-${m.tone}`} title={c.in ? `${m.long} · ${c.in}~${c.out ?? ""}` : m.long}>{m.short}</td>;
                        })}
                        <td className="sum">{t.days}</td>
                        <td className="sum">{t.attended}{(t.sick > 0 || t.leave > 0) && <small> ({[t.sick && `병${t.sick}`, t.leave && `공${t.leave}`].filter(Boolean).join(" ")})</small>}</td>
                        <td className="sum">{t.absent}</td>
                        <td className="sum">{t.late}</td>
                        <td className="sum">{t.early}</td>
                        <td className="sum">{t.outs}</td>
                        <td className="sum">{t.converted}</td>
                        <td className="sum">{t.rate === null ? "—" : `${t.rate}%`}</td>
                      </tr>
                    );
                  })}
                  {sheet.students.length === 0 && <tr><td colSpan={sheet.days.length + 9} className="small center">이 기간에 수강한 교육생이 없습니다.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
          {sheet.days.length === 0 && <p className="small">이 기간에는 수업일 기록이 없습니다.</p>}

          {single && (
            <div className="table-card" style={{ marginTop: 14 }}>
              <div className="table-wrap">
                <table>
                  <thead><tr><th>날짜</th><th>입실</th><th>퇴실</th><th>출결</th></tr></thead>
                  <tbody>
                    {single.cells.map((c, i) => {
                      const d = sheet.days[i + single.startIndex];
                      const m = cellMark(c);
                      return (
                        <tr key={d}>
                          <td>{formatDate(d)}</td><td>{c.in ?? "—"}</td><td>{c.out ?? "—"}</td>
                          <td><span className={`tag ${m.tone === "bad" ? "danger" : m.tone === "warn" ? "warn" : m.tone === "leave" ? "brand" : "active"}`}>{m.long || "—"}</span></td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </>
      )}

      {!enrollmentId && <InstitutionSetting region={region} />}
    </>
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
    <div className="panel no-print" style={{ marginTop: 18 }}>
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
