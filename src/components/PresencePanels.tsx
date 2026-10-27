"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/client";
import { formatDateTime, formatTime, messageFor, todayInSeoul } from "@/lib/messages";

export type CodeInfo = { campusId: number; code: string | null; createdAt: string | null; createdBy: string | null; students: number };

type Blocked = {
  campusId: number;
  campusName: string;
  ip: string;
  students: number;
  attempts: number;
  lastAt: string;
  names: string[] | null;
};

// 여러 교육생이 같은 새 IP에서 막혔다면 교육장 공인 IP가 바뀐 것일 가능성이 높다.
export const LIKELY_CHANGED = 3;

export function useBlocked(region: string, minutes = 60) {
  const [items, setItems] = useState<Blocked[] | null>(null);
  const load = useCallback(async () => {
    const r = await api(`/api/admin/blocked?region=${encodeURIComponent(region)}&minutes=${minutes}`);
    if (r.ok) setItems(r.items);
  }, [region, minutes]);
  useEffect(() => {
    void load();
  }, [load]);
  return { items, reload: load };
}

export function BlockedPanel({ region, onAllowed }: { region: string; onAllowed: (text: string) => void }) {
  const { items, reload } = useBlocked(region, 120);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  async function allow(b: Blocked) {
    if (!window.confirm(`${b.campusName}의 허용 주소로 ${b.ip} 를 바로 사용 중으로 등록할까요?\n교육장 와이파이의 공인 IP가 바뀐 경우에만 허용해 주세요.`)) return;
    setBusy(b.ip);
    setError(null);
    const r = await api("/api/admin/networks", {
      campusId: b.campusId,
      label: `막힌 접속에서 허용 (${todayInSeoul()})`,
      network: b.ip,
      status: "active",
    });
    setBusy(null);
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    await reload();
    onAllowed(`${b.ip} 를 허용했습니다. 이전 주소를 더 쓰지 않는다면 목록에서 중지해 주세요.`);
  }

  if (!items || items.length === 0) return null;

  return (
    <section className="panel" style={{ border: "1.5px solid var(--warn)" }}>
      <h2>최근 2시간 막힌 접속</h2>
      <p className="small">
        본인 확인이 된 교육생이 허용되지 않은 IP에서 막힌 기록입니다. 같은 IP에서 여러 명이 막혔다면 교육장 공인 IP가 바뀐 것일 수 있습니다.
        한두 명이면 집이나 LTE에서 접속한 경우일 수 있으니 허용하지 마세요.
      </p>
      {error && <p className="notice error">{error}</p>}
      <div className="table-wrap">
        <table>
          <thead><tr><th>교육장</th><th>IP</th><th>막힌 교육생</th><th>마지막</th><th>이름</th><th></th></tr></thead>
          <tbody>
            {items.map((b) => (
              <tr key={`${b.campusId}-${b.ip}`}>
                <td>{b.campusName}</td>
                <td className="mono">{b.ip}</td>
                <td>
                  <b>{b.students}명</b> <span className="small">({b.attempts}회)</span>{" "}
                  {b.students >= LIKELY_CHANGED && <span className="tag warn">IP 변경 의심</span>}
                </td>
                <td className="small">{formatTime(b.lastAt)}</td>
                <td className="small" style={{ whiteSpace: "normal", minWidth: 160 }}>{(b.names ?? []).join(", ")}</td>
                <td>
                  <button className={`btn sm ${b.students >= LIKELY_CHANGED ? "" : "plain"}`} disabled={busy === b.ip} onClick={() => allow(b)}>
                    이 IP 허용
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export function CodePanel({ campusId, info, onChange }: { campusId: number; info?: CodeInfo; onChange: () => void }) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function set(action: "on" | "off") {
    if (action === "on" && info?.code && !window.confirm("새 코드로 바꾸면 이전 코드는 바로 쓸 수 없습니다. 바꿀까요?")) return;
    setBusy(true);
    setError(null);
    const r = await api("/api/admin/codes", { campusId, action });
    setBusy(false);
    if (!r.ok) setError(messageFor(r.code));
    onChange();
  }

  return (
    <div className="card" style={{ boxShadow: "none", border: "1.5px solid var(--line)", marginTop: 14 }}>
      <div className="row between">
        <div>
          <h2 style={{ marginBottom: 2 }}>오늘의 출석코드</h2>
          <span className="small">
            와이파이 장애나 IP 변경으로 출결이 막힐 때 켭니다. 오늘 하루만 유효하고, 코드로 남긴 기록은 표시됩니다.
          </span>
        </div>
        {info?.code ? (
          <div className="row">
            <button className="btn plain sm" onClick={() => set("on")} disabled={busy}>새 코드</button>
            <button className="btn danger sm" onClick={() => set("off")} disabled={busy}>끄기</button>
          </div>
        ) : (
          <button className="btn ghost sm" onClick={() => set("on")} disabled={busy}>코드 켜기</button>
        )}
      </div>
      {info?.code && (
        <div className="row" style={{ marginTop: 12, gap: 18 }}>
          <span className="mono" style={{ fontSize: 40, fontWeight: 800, letterSpacing: 8, color: "var(--brand-strong)" }}>{info.code}</span>
          <span className="small">
            {info.createdBy} · {info.createdAt ? formatDateTime(info.createdAt) : ""} 발급<br />
            이 코드로 출결한 교육생 {info.students}명
          </span>
        </div>
      )}
      {error && <p className="notice error">{error}</p>}
    </div>
  );
}
