"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { useOperator } from "./AdminShell";
import { api } from "@/lib/client";
import { STATUS_LABEL, formatTime, messageFor, todayInSeoul } from "@/lib/messages";

type Region = {
  code: string;
  name: string;
  counts: Record<"total" | "in_class" | "out" | "checked_out" | "not_in", number>;
  campuses: { name: string; activeNetworks: number }[];
  pendingCorrections: number;
};

export default function OverviewBoard() {
  const router = useRouter();
  const { operator, setRegion } = useOperator();
  const [date, setDate] = useState(todayInSeoul());
  const [regions, setRegions] = useState<Region[] | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await api(`/api/admin/overview?date=${date}`);
    if (!r.ok) setError(messageFor(r.code));
    else {
      setRegions(r.regions);
      setUpdatedAt(r.generatedAt);
      setError(null);
    }
  }, [date]);

  useEffect(() => {
    void load();
    if (date !== todayInSeoul()) return;
    const t = setInterval(load, 15_000);
    return () => clearInterval(t);
  }, [load, date]);

  if (operator.scope !== "super") return <p className="notice error">총괄 운영자만 볼 수 있는 화면입니다.</p>;

  function go(code: string, path: string) {
    setRegion(code);
    router.push(path);
  }

  const noNetwork = (regions ?? []).flatMap((r) => r.campuses.filter((c) => c.activeNetworks === 0).map((c) => `${r.name} ${c.name}`));

  return (
    <>
      <div className="a-title">
        <div>
          <h1>세 지역 운영 현황</h1>
          <span className="small">{updatedAt ? `마지막 갱신 ${formatTime(updatedAt, true)}` : "불러오는 중…"}</span>
        </div>
        <label className="field" style={{ margin: 0 }}>날짜<input type="date" value={date} max={todayInSeoul()} onChange={(e) => e.target.value && setDate(e.target.value)} /></label>
      </div>
      {error && <p className="notice error">{error}</p>}
      {noNetwork.length > 0 && (
        <p className="notice warn">사용 중인 허용 IP가 없는 교육장: {noNetwork.join(", ")} — 학생 출결 입력이 차단된 상태입니다.</p>
      )}
      <div className="region-grid">
        {regions?.map((r) => (
          <section className="panel region-card" key={r.code}>
            <div className="row between">
              <h2>{r.name}</h2>
              <span className="small">교육생 {r.counts.total}명</span>
            </div>
            <div className="nums">
              {(["in_class", "out", "checked_out", "not_in"] as const).map((k) => (
                <div key={k}><strong>{r.counts[k]}</strong><span>{STATUS_LABEL[k]}</span></div>
              ))}
            </div>
            <div className="row" style={{ marginBottom: 10 }}>
              {r.campuses.map((c) => (
                <span key={c.name} className={`tag ${c.activeNetworks ? "active" : "danger"}`}>{c.name} · IP {c.activeNetworks}개</span>
              ))}
              {r.pendingCorrections > 0 && <span className="tag pending">정정 대기 {r.pendingCorrections}</span>}
            </div>
            <div className="row">
              <button className="btn ghost sm" onClick={() => go(r.code, "/admin/daily")}>출결 현황</button>
              <button className="btn plain sm" onClick={() => go(r.code, "/admin/networks")}>교육장 · IP</button>
            </div>
          </section>
        ))}
      </div>
    </>
  );
}
