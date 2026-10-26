"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { messageFor } from "@/lib/messages";

const SCOPES = [
  { value: "daegu", label: "대구" },
  { value: "daejeon", label: "대전" },
  { value: "busan", label: "부산" },
  { value: "super", label: "총괄 운영" },
];

export default function AdminLogin() {
  const router = useRouter();
  const [scope, setScope] = useState("daejeon");
  const [password, setPassword] = useState("");
  const [operatorName, setOperatorName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const res = await fetch("/api/admin/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ scope, password, operatorName }),
      });
      const r = await res.json();
      if (!r.ok) {
        setError(messageFor(r.code));
        return;
      }
      setPassword("");
      router.replace("/admin/daily");
    } catch {
      setError(messageFor("server_error"));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-wrap">
      <form className="card login-card" onSubmit={submit}>
        <p className="small" style={{ margin: 0 }}>출결 운영</p>
        <h1 style={{ fontSize: 24, margin: "4px 0 18px" }}>운영자 화면 입장</h1>
        <label className="field">
          운영 지역
          <select value={scope} onChange={(e) => setScope(e.target.value)}>
            {SCOPES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
          </select>
        </label>
        <label className="field">
          비밀번호
          <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" required />
        </label>
        <label className="field">
          처리자 표시 이름
          <input value={operatorName} onChange={(e) => setOperatorName(e.target.value)} maxLength={40} required placeholder="변경 이력에 남는 이름" />
        </label>
        {error && <p className="notice error">{error}</p>}
        <button className="btn block" disabled={busy}>{busy ? "확인 중…" : "입장"}</button>
        <p className="small" style={{ marginTop: 14 }}>
          교육장 밖에서도 접속할 수 있습니다. 지역 권한은 비밀번호 확인 후 서버가 정합니다.
          표시 이름은 개인 계정 인증을 대신하지 않습니다.
        </p>
      </form>
    </main>
  );
}
