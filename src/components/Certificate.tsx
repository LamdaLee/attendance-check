"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { LEAVE_KIND_SHORT, formatDate } from "@/lib/messages";

// 출석부 칸 하나 (attendance.day_cell)
export type Cell = {
  state: string;
  absent?: boolean;
  leaveAttend?: boolean;
  insufficient?: boolean;
  late?: boolean;
  early?: boolean;
  outs?: number;
  excused?: boolean;
  pending?: boolean;
  in?: string | null;
  out?: string | null;
  leaveKind?: string | null;
  open?: boolean;
  // 그 날 일정 (날짜별 일정 반영)
  start?: string;
  end?: string;
  minutes?: number;
  place?: string;
};

// 칸 판정 → 짧은 표기와 긴 표기
export function cellMark(c: Cell): { short: string; long: string; tone: "ok" | "warn" | "bad" | "leave" | "none" } {
  if (c.state !== "training") return { short: "", long: "", tone: "none" };
  if (c.open) return { short: "·", long: "진행 중", tone: "none" };
  if (c.absent) return { short: "결", long: c.insufficient ? "결석(수업 50% 미만)" : "결석", tone: "bad" };
  if (c.leaveAttend) {
    const sick = c.leaveKind === "sick";
    return { short: sick ? "병" : "공", long: sick ? "병결 (출석 인정)" : `공가 (출석 인정${c.leaveKind ? `, ${LEAVE_KIND_SHORT[c.leaveKind]}` : ""})`, tone: "leave" };
  }
  const parts: [string, string][] = [];
  if (c.late) parts.push(["지", "지각"]);
  if (c.early) parts.push(["조", "조퇴"]);
  if (c.outs) parts.push(["외", c.outs > 1 ? `외출 ${c.outs}회` : "외출"]);
  if (parts.length) return { short: parts.map((p) => p[0]).join(""), long: parts.map((p) => p[1]).join("·"), tone: "warn" };
  return { short: "○", long: c.excused ? "출석(공가 승인)" : "출석", tone: "ok" };
}

export type Summary = {
  days: number;
  attended: number;
  absent: number;
  leaveAttend: number;
  sickAttend?: number;
  otherAttend?: number;
  late: number;
  early: number;
  outs: number;
  converted: number;
  rate: number | null;
  trainingMinutes?: number;
  attendedMinutes?: number;
};

export type CertificateData = {
  code: string;
  issuedAt: string;
  name: string;
  course: string;
  institution: string;
  regionName: string;
  courseStartsOn: string | null;
  courseEndsOn: string | null;
  classStart: string;
  classEnd: string;
  from: string;
  to: string;
  days: (Cell & { date: string })[];
  summary: Summary;
};

function issuedDate(iso: string): string {
  const [y, m, d] = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Seoul" }).format(new Date(iso)).split("-").map(Number);
  return `${y}년 ${m}월 ${d}일`;
}

const dot = (d: string | null | undefined) => (d ? d.replaceAll("-", ".") : "");

const hrs = (m: number | undefined) => (m == null ? "—" : `${Number.isInteger(m / 60) ? m / 60 : (m / 60).toFixed(1)}시간`);

// 출석확인서: 인적사항 → 출결 총계 → 일자별 출결(훈련생 서명·강사 확인란) → 확인·발급
function CertificateView({ data, birth }: { data: CertificateData; birth: string }) {
  const s = data.summary;
  return (
    <article className="cert">
      <h1>출 석 확 인 서</h1>

      <h2 className="cert-h">1. 인적사항</h2>
      <table className="cert-info">
        <tbody>
          <tr><th>훈련생 성명</th><td>{data.name}</td><th>생년월일</th><td>{birth || "\u00a0"}</td></tr>
          <tr><th>과정명</th><td colSpan={3}>{data.course}</td></tr>
          <tr><th>훈련기관</th><td colSpan={3}>{data.institution || "\u00a0"}</td></tr>
          <tr><th>전체 훈련기간</th><td colSpan={3}>{dot(data.courseStartsOn)} ~ {dot(data.courseEndsOn)}{data.courseEndsOn ? "" : " (진행 중)"}</td></tr>
          <tr><th>확인 기간</th><td colSpan={3}>{dot(data.from)} ~ {dot(data.to)}</td></tr>
        </tbody>
      </table>

      <h2 className="cert-h">2. 출결 총계 (확인 기간)</h2>
      <table className="cert-sum">
        <thead>
          <tr><th>총 훈련일수</th><th>출석(참여)일수</th><th>결석</th><th>지각</th><th>조퇴</th><th>외출</th><th>총 훈련시간</th><th>참여 훈련시간</th><th>출석률</th></tr>
        </thead>
        <tbody>
          <tr>
            <td>{s.days}일</td>
            <td><b>{s.attended}일</b>{s.leaveAttend > 0 && <small> ({[s.sickAttend && `병결 ${s.sickAttend}`, s.otherAttend && `공가 ${s.otherAttend}`].filter(Boolean).join(" · ") || `공가 ${s.leaveAttend}`})</small>}</td>
            <td>{s.absent}</td>
            <td>{s.late}</td>
            <td>{s.early}</td>
            <td>{s.outs}</td>
            <td>{hrs(s.trainingMinutes)}</td>
            <td>{hrs(s.attendedMinutes)}</td>
            <td>{s.rate === null ? "—" : `${s.rate}%`}</td>
          </tr>
        </tbody>
      </table>

      <h2 className="cert-h">3. 일자별 출결</h2>
      <div className="cert-scroll">
        <table className="cert-days">
          <thead>
            <tr><th>일자</th><th>입실</th><th>퇴실</th><th>훈련시간</th><th>출결</th><th>훈련생 서명</th><th>강사 확인</th></tr>
          </thead>
          <tbody>
            {data.days.map((d) => {
              const m = cellMark(d);
              return (
                <tr key={d.date}>
                  <td>{formatDate(d.date)}{d.place && <div className="cert-place">{d.place}</div>}</td>
                  <td>{d.in ?? "—"}</td>
                  <td>{d.out ?? "—"}</td>
                  <td>{d.absent ? "0" : hrs(d.minutes)}</td>
                  <td>{m.long}</td>
                  <td className="cert-sign-cell" />
                  <td className="cert-sign-cell" />
                </tr>
              );
            })}
            {data.days.length === 0 && <tr><td colSpan={7}>확인 기간에 수업일이 없습니다.</td></tr>}
          </tbody>
        </table>
      </div>

      <p className="cert-note">
        훈련시간은 해당 일자의 편성 시간(점심시간 제외)이며 결석일은 0으로 적습니다. 지각·조퇴·외출 3회는 결석 1회로 환산하고,
        출석률 = (총 훈련일수 − 결석 − 결석 환산) ÷ 총 훈련일수 입니다. 승인된 공가는 출석으로 인정합니다.
        입·퇴실 시각은 교육장 네트워크 확인을 거친 출결 시스템 기록입니다.
      </p>
      <p className="cert-claim">위와 같이 출석 사실을 확인합니다.</p>
      <p className="cert-date">{issuedDate(data.issuedAt)}</p>
      <p className="cert-sign">{data.institution || "훈련기관"} <span>(인)</span></p>
      <p className="cert-code">발급번호 {data.code} · 출결 시스템 기록으로 작성되었으며, 발급번호로 훈련기관에 진위를 확인할 수 있습니다.</p>
    </article>
  );
}

// 화면 전체에 확인서를 띄우고 인쇄(PDF 저장)할 수 있게 한다.
export function CertificateOverlay({ data, birth, onClose }: { data: CertificateData; birth: string; onClose: () => void }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    setMounted(true);
    document.documentElement.classList.add("cert-open");
    return () => document.documentElement.classList.remove("cert-open");
  }, []);
  if (!mounted) return null;
  return createPortal(
    <div className="cert-overlay" role="dialog" aria-label="출석확인서">
      <style>{"@media print { @page { size: A4 portrait; margin: 15mm; } }"}</style>
      <div className="cert-bar no-print">
        <button className="btn" onClick={() => window.print()}>PDF로 저장 · 인쇄</button>
        <button className="btn plain" onClick={onClose}>닫기</button>
        <span className="small">인쇄 화면에서 대상(프린터)을 &lsquo;PDF로 저장&rsquo;으로 고르면 파일로 저장됩니다.</span>
      </div>
      <CertificateView data={data} birth={birth} />
    </div>,
    document.body,
  );
}

// 생년월일 입력 정리: 숫자 8자리 → YYYY.MM.DD
export function formatBirth(raw: string): string {
  const d = raw.replace(/\D/g, "").slice(0, 8);
  if (d.length <= 4) return d;
  if (d.length <= 6) return `${d.slice(0, 4)}.${d.slice(4)}`;
  return `${d.slice(0, 4)}.${d.slice(4, 6)}.${d.slice(6)}`;
}

export const birthValid = (b: string) => /^(19|20)\d{2}\.(0[1-9]|1[0-2])\.(0[1-9]|[12]\d|3[01])$/.test(b);
