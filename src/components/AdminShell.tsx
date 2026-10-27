"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createContext, useContext, useEffect, useState } from "react";

export type Operator = {
  scope: "region" | "super";
  operatorName: string;
  regions: { code: string; name: string }[];
};

type Ctx = { operator: Operator; region: string; setRegion: (code: string) => void };

const OperatorContext = createContext<Ctx | null>(null);

export function useOperator(): Ctx {
  const ctx = useContext(OperatorContext);
  if (!ctx) throw new Error("AdminShell 안에서만 사용할 수 있습니다.");
  return ctx;
}

const NAV = [
  { href: "/admin/overview", label: "총괄 현황", superOnly: true },
  { href: "/admin/daily", label: "출결 현황" },
  { href: "/admin/notices", label: "사전 알림" },
  { href: "/admin/issues", label: "누락 확인" },
  { href: "/admin/corrections", label: "정정 요청" },
  { href: "/admin/students", label: "교육생" },
  { href: "/admin/networks", label: "교육장 · IP" },
  { href: "/admin/audit", label: "변경 이력" },
];

export default function AdminShell({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const [operator, setOperator] = useState<Operator | null>(null);
  const [region, setRegionState] = useState("");

  useEffect(() => {
    fetch("/api/admin/me", { cache: "no-store" })
      .then((res) => res.json())
      .then((r) => {
        if (!r.ok) {
          router.replace("/admin");
          return;
        }
        setOperator(r);
        let saved = "";
        try {
          saved = sessionStorage.getItem("att_region") ?? "";
        } catch {}
        const codes = (r.regions as Operator["regions"]).map((x) => x.code);
        setRegionState(codes.includes(saved) ? saved : codes[0] ?? "");
      })
      .catch(() => router.replace("/admin"));
  }, [router]);

  function setRegion(code: string) {
    setRegionState(code);
    try {
      sessionStorage.setItem("att_region", code);
    } catch {}
  }

  async function lock() {
    await fetch("/api/admin/logout", { method: "POST" }).catch(() => {});
    router.replace("/admin");
  }

  if (!operator) return <div className="login-wrap small">불러오는 중…</div>;

  const regionName = operator.regions.find((r) => r.code === region)?.name ?? "";

  return (
    <OperatorContext.Provider value={{ operator, region, setRegion }}>
      <div className="a-shell">
        <header className="a-head">
          <div className="a-brand">
            출결 운영
            {operator.scope === "super" ? (
              <select
                className="scope-tag"
                style={{ border: 0 }}
                value={region}
                onChange={(e) => setRegion(e.target.value)}
                aria-label="지역 전환"
              >
                {operator.regions.map((r) => <option key={r.code} value={r.code}>총괄 · {r.name}</option>)}
              </select>
            ) : (
              <span className="scope-tag">{regionName} 지역</span>
            )}
          </div>
          <nav className="a-nav">
            {NAV.filter((n) => !n.superOnly || operator.scope === "super").map((n) => (
              <Link key={n.href} href={n.href} className={pathname.startsWith(n.href) ? "active" : undefined}>{n.label}</Link>
            ))}
          </nav>
          <div className="a-user">
            {operator.operatorName} · {operator.scope === "super" ? "총괄 운영자" : "지역 운영자"}
            <button className="btn plain sm" onClick={lock}>화면 잠금</button>
          </div>
        </header>
        <main className="a-main">{children}</main>
      </div>
    </OperatorContext.Provider>
  );
}
