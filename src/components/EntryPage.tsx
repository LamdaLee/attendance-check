"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import InstallCard, { LAST_CAMPUS_KEY } from "./InstallCard";

type Campus = { code: string; name: string; regionName: string };

// 첫 화면(홈 화면 바로가기의 시작 주소).
// 지금 회선이 등록된 교육장이 하나면 그 화면으로 바로 넘어가고, 아니면 교육장을 고르게 한다.
export default function EntryPage() {
  const [data, setData] = useState<{ matched: Campus[]; campuses: Campus[] } | null>(null);
  const [last, setLast] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const pick = new URLSearchParams(window.location.search).has("pick");
    let saved: string | null = null;
    try {
      saved = localStorage.getItem(LAST_CAMPUS_KEY);
    } catch {}
    setLast(saved);
    fetch("/api/entry", { cache: "no-store" })
      .then((res) => res.json())
      .then((r) => {
        if (!r.ok) throw new Error();
        if (!pick && r.matched.length === 1) {
          window.location.replace(`/c/${encodeURIComponent(r.matched[0].code)}`);
          return;
        }
        setData(r);
      })
      .catch(() => setFailed(true));
  }, []);

  const lastCampus = data?.campuses.find((c) => c.code === last) ?? null;
  const regions = [...new Set((data?.campuses ?? []).map((c) => c.regionName))];

  return (
    <main className="m-shell">
      <section className="m-hero">
        <p className="eyebrow">교육장 출결</p>
        <h1>교육장을<br />골라 주세요.</h1>
        <p className="sub">교육장 와이파이에 연결돼 있으면 자동으로 들어갑니다.</p>
      </section>
      <div className="m-body">
        {!data && !failed && <div className="card center small">교육장 확인 중…</div>}
        {failed && <div className="card"><p className="notice error" style={{ margin: 0 }}>교육장 목록을 불러오지 못했습니다. 잠시 후 다시 열어 주세요.</p></div>}

        {data && (
          <>
            {data.matched.length === 0 && (
              <p className="notice warn" style={{ margin: 0 }}>
                지금은 교육장 와이파이가 아닙니다. 출결을 기록하려면 교육장 와이파이에 연결한 뒤 다시 열어 주세요.
                사전 알림·정정 요청은 아래에서 교육장을 골라 할 수 있습니다.
              </p>
            )}
            {data.matched.length > 1 && <p className="notice ok" style={{ margin: 0 }}>지금 회선에서 여러 교육장이 확인됩니다. 계신 곳을 골라 주세요.</p>}

            {lastCampus && (
              <Link className="btn block" href={`/c/${encodeURIComponent(lastCampus.code)}`}>
                지난번 교육장: {lastCampus.regionName} {lastCampus.name}
              </Link>
            )}

            {regions.map((region) => (
              <div className="card" key={region}>
                <h2>{region}</h2>
                <div className="link-list">
                  {data.campuses.filter((c) => c.regionName === region).map((c) => (
                    <Link key={c.code} className={`btn block ${data.matched.some((m) => m.code === c.code) ? "" : "ghost"}`} href={`/c/${encodeURIComponent(c.code)}`}>
                      {c.name}
                    </Link>
                  ))}
                </div>
              </div>
            ))}
            {data.campuses.length === 0 && <div className="card small">등록된 교육장이 없습니다.</div>}
          </>
        )}

        <InstallCard />
        <Link className="small center" href="/admin" style={{ display: "block" }}>운영자 화면</Link>
      </div>
    </main>
  );
}
