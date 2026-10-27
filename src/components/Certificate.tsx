"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { LEAVE_KIND_LABEL, formatDate } from "@/lib/messages";

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
};

// 칸 판정 → 짧은 표기와 긴 표기
export function cellMark(c: Cell): { short: string; long: string; tone: "ok" | "warn" | "bad" | "leave" | "none" } {
  if (c.state !== "training") return { short: "", long: "", tone: "none" };
  if (c.open) return { short: "·", long: "진행 중", tone: "none" };
  if (c.absent) return { short: "결", long: c.insufficient ? "결석(수업 50% 미만)" : "결석", tone: "bad" };
  if (c.leaveAttend) return { short: "공", long: `공가 출석 인정${c.leaveKind ? `(${LEAVE_KIND_LABEL[c.leaveKind]})` : ""}`, tone: "leave" };
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
  late: number;
  early: number;
  outs: number;
  converted: number;
  rate: number | null;
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

function CertificateView({ data, birth }: { data: CertificateData; birth: string }) {
  const s = data.summary;
  const half = Math.ceil(data.days.length / 2);
  const columns = [data.days.slice(0, half), data.days.slice(half)];
  return (
    <article className="cert">
      <h1>출 석 확 인 서</h1>
      <table className="cert-info">
        <tbody>
          <tr><th>성명</th><td>{data.name}</td><th>생년월일</th><td>{birth || " "}</td></tr>
          <tr><th>과정명</th><td colSpan={3}>{data.course}</td></tr>
          <tr><th>훈련기관</th><td colSpan={3}>{data.institution || " "}</td></tr>
          <tr>
            <th>훈련기간</th>
            <td colSpan={3}>{dot(data.courseStartsOn)} ~ {dot(data.courseEndsOn)}{data.courseEndsOn ? "" : " (진행 중)"} · 교육 시간 {data.classStart}~{data.classEnd}</td>
          </tr>
          <tr><th>확인기간</th><td colSpan={3}>{dot(data.from)} ~ {dot(data.to)}</td></tr>
        </tbody>
      </table>

      <table className="cert-sum">
        <thead>
          <tr><th>수업일수</th><th>출석</th><th>결석</th><th>지각</th><th>조퇴</th><th>외출</th><th>결석 환산</th><th>출석률</th></tr>
        </thead>
        <tbody>
          <tr>
            <td>{s.days}</td>
            <td>{s.attended}{s.leaveAttend > 0 && <small> (공가 {s.leaveAttend})</small>}</td>
            <td>{s.absent}</td>
            <td>{s.late}</td>
            <td>{s.early}</td>
            <td>{s.outs}</td>
            <td>{s.converted}</td>
            <td>{s.rate === null ? "—" : `${s.rate}%`}</td>
          </tr>
        </tbody>
      </table>

      <div className="cert-days">
        {columns.map((col, i) => (
          <table key={i}>
            <thead><tr><th>날짜</th><th>입실</th><th>퇴실</th><th>출결</th></tr></thead>
            <tbody>
              {col.map((d) => (
                <tr key={d.date}>
                  <td>{formatDate(d.date)}</td>
                  <td>{d.in ?? "—"}</td>
                  <td>{d.out ?? "—"}</td>
                  <td>{cellMark(d).long}</td>
                </tr>
              ))}
              {col.length === 0 && i === 0 && <tr><td colSpan={4}>이 기간에 수업일 기록이 없습니다.</td></tr>}
            </tbody>
          </table>
        ))}
      </div>

      <p className="cert-note">
        지각·조퇴·외출 3회는 결석 1회로 환산하며, 출석률 = (수업일수 − 결석 − 결석 환산) ÷ 수업일수 입니다.
        수업일은 해당 과정의 출결 기록이 있는 평일입니다.
      </p>
      <p className="cert-claim">위와 같이 출석 사실을 확인합니다.</p>
      <p className="cert-date">{issuedDate(data.issuedAt)}</p>
      <p className="cert-sign">{data.institution || "훈련기관"} <span>(인)</span></p>
      <p className="cert-code">발급번호 {data.code} · 출결 시스템 기록으로 자동 작성되었으며, 발급번호로 기관에 확인할 수 있습니다.</p>
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
