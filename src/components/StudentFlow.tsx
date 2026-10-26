"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ACTION_LABEL, STATUS_LABEL, formatTime, messageFor } from "@/lib/messages";

type Campus = { name: string; regionCode: string; regionName: string };
type Today = {
  studentName: string;
  courseName: string;
  campusName: string;
  campusCode: string;
  regionName: string;
  status: keyof typeof STATUS_LABEL;
  sessionExpiresAt: string;
  events: { action: string; at: string }[];
};
type Receipt = { action: string; at: string; studentName: string; courseName: string };
type Pending = { action: string; requestId: string };

const ALLOWED: Record<string, string[]> = {
  not_in: ["check_in"],
  in_class: ["go_out", "check_out"],
  out: ["return"],
  checked_out: [],
};

const ACTION_ICON: Record<string, string> = { check_in: "🏫", go_out: "🚶", return: "↩︎", check_out: "🏠" };

const DONE_MESSAGE: Record<string, string> = {
  check_in: "오늘도 좋은 하루 보내세요.",
  go_out: "돌아오면 복귀를 체크해 주세요.",
  return: "다시 교육 중으로 기록했습니다.",
  check_out: "오늘도 수고하셨습니다.",
};

async function getJson(url: string, init?: RequestInit) {
  const res = await fetch(url, { cache: "no-store", ...init });
  return res.json();
}

function postJson(url: string, body: unknown) {
  return getJson(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export default function StudentFlow({ code }: { code: string }) {
  const [phase, setPhase] = useState<"loading" | "campus_error" | "verify" | "today" | "done">("loading");
  const [campus, setCampus] = useState<Campus | null>(null);
  const [networkOk, setNetworkOk] = useState(false);
  const [today, setToday] = useState<Today | null>(null);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [name, setName] = useState("");
  const [last4, setLast4] = useState("");
  const pending = useRef<Pending | null>(null);

  const loadCampus = useCallback(async () => {
    try {
      const r = await getJson(`/api/campus/${encodeURIComponent(code)}`);
      if (!r.ok) {
        setError(messageFor(r.code));
        if (r.code === "campus_not_found") setPhase("campus_error");
        return false;
      }
      setCampus(r.campus);
      setNetworkOk(r.networkOk);
      return true;
    } catch {
      setError(messageFor("server_error"));
      return false;
    }
  }, [code]);

  const loadToday = useCallback(async () => {
    const r = await getJson("/api/student/today");
    // 다른 교육장 QR로 들어왔다면 그 교육장에서 다시 본인 확인을 받는다.
    if (r.ok && r.campusCode === code) {
      setToday(r);
      setPhase("today");
      return true;
    }
    setToday(null);
    setPhase("verify");
    return false;
  }, [code]);

  useEffect(() => {
    (async () => {
      if (await loadCampus()) await loadToday().catch(() => setPhase("verify"));
    })();
  }, [loadCampus, loadToday]);

  // 세션 만료 시 본인 확인 화면으로
  useEffect(() => {
    if (phase !== "today" || !today) return;
    const ms = new Date(today.sessionExpiresAt).getTime() - Date.now();
    const t = setTimeout(() => {
      setToday(null);
      setPhase("verify");
      setError(messageFor("session_expired"));
    }, Math.max(ms, 0));
    return () => clearTimeout(t);
  }, [phase, today]);

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    if (!/^\d{4}$/.test(last4)) {
      setError("전화번호 뒷자리 4자리를 숫자로 입력해 주세요.");
      return;
    }
    setBusy(true);
    try {
      const r = await postJson("/api/student/verify", { code, name, last4 });
      if (!r.ok) {
        setError(messageFor(r.code));
        if (r.code === "network_denied") setNetworkOk(false);
        return;
      }
      setLast4("");
      await loadToday();
    } catch {
      setError(messageFor("server_error"));
    } finally {
      setBusy(false);
    }
  }

  async function submitPending() {
    const p = pending.current;
    if (!p) return;
    setBusy(true);
    setError(null);
    try {
      // 응답이 끊기면 같은 요청 식별자로 다시 보낸다. 서버는 같은 요청을 한 번만 저장한다.
      let r: { ok: boolean; code?: string; action?: string; at?: string } | null = null;
      for (let attempt = 0; attempt < 3 && !r; attempt++) {
        try {
          r = await postJson("/api/student/action", p);
        } catch {
          if (attempt < 2) await sleep(800 * (attempt + 1));
        }
      }
      if (!r) {
        setError("저장 여부를 확인하지 못했습니다. 네트워크를 확인한 뒤 ‘다시 시도’를 눌러 주세요. 같은 요청으로 확인하므로 중복 기록되지 않습니다.");
        return;
      }
      pending.current = null;
      if (!r.ok) {
        setError(messageFor(r.code));
        if (r.code === "session_expired") {
          setToday(null);
          setPhase("verify");
        } else if (r.code === "network_denied") {
          setNetworkOk(false);
        } else {
          await loadToday();
        }
        return;
      }
      setReceipt({ action: r.action!, at: r.at!, studentName: today!.studentName, courseName: today!.courseName });
      setPhase("done");
    } finally {
      setBusy(false);
    }
  }

  function act(action: string) {
    if (action === "check_out" && !window.confirm("퇴실을 기록할까요? 퇴실 후에는 오늘 다시 입실할 수 없습니다.")) return;
    pending.current = { action, requestId: crypto.randomUUID() };
    void submitPending();
  }

  async function backToToday() {
    setReceipt(null);
    await loadToday();
  }

  async function recheckNetwork() {
    setError(null);
    await loadCampus();
  }

  const eyebrow = campus ? `${campus.regionName} · ${campus.name}` : "QR 출결";

  return (
    <main className="m-shell">
      <section className="m-hero">
        <p className="eyebrow">{eyebrow}</p>
        {phase === "today" && today ? (
          <>
            <h1>{today.studentName} 님</h1>
            <p className="sub">{today.courseName} 과정</p>
          </>
        ) : phase === "done" ? (
          <h1>기록했습니다</h1>
        ) : (
          <>
            <h1>오늘의 출결을<br />기록해 주세요.</h1>
            <p className="sub">교육장에 도착한 뒤 체크해 주세요.</p>
          </>
        )}
      </section>

      <div className="m-body">
        {phase === "loading" && <div className="card center small">불러오는 중…</div>}

        {phase === "campus_error" && <div className="card"><div className="notice error">{error}</div></div>}

        {(phase === "verify" || phase === "today") && (
          <div className="card row between">
            {networkOk ? (
              <span className="pill ok"><span className="dot" />교육장 네트워크 확인됨</span>
            ) : (
              <span className="pill warn"><span className="dot" />교육장 와이파이가 아닙니다</span>
            )}
            <button className="btn ghost sm" onClick={recheckNetwork} disabled={busy}>다시 확인</button>
          </div>
        )}

        {phase === "verify" && (
          <form className="card" onSubmit={verify}>
            <h2>본인 확인</h2>
            {!networkOk && (
              <p className="notice warn">휴대폰 설정에서 교육장 와이파이에 연결한 뒤 ‘다시 확인’을 눌러 주세요. LTE·5G로는 기록할 수 없습니다.</p>
            )}
            <label className="field">
              이름
              <input value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" maxLength={40} required placeholder="등록된 이름" />
            </label>
            <label className="field">
              전화번호 뒷자리 4자리
              <input
                value={last4}
                onChange={(e) => setLast4(e.target.value.replace(/\D/g, "").slice(0, 4))}
                inputMode="numeric"
                autoComplete="off"
                pattern="\d{4}"
                required
                placeholder="0000"
              />
            </label>
            {error && <p className="notice error">{error}</p>}
            <button className="btn block" disabled={busy || !networkOk}>{busy ? "확인 중…" : "본인 확인"}</button>
            <p className="small" style={{ marginTop: 14 }}>이 기록은 보조 출결 자료입니다. LMS 입·퇴실도 따로 확인해 주세요.</p>
          </form>
        )}

        {phase === "today" && today && (
          <>
            <div className="card">
              <div className="state">
                <div>
                  <div className="label">오늘 현재 상태</div>
                  <div className="value">{STATUS_LABEL[today.status]}</div>
                </div>
                <span className="small">{formatTime(today.sessionExpiresAt)}까지 확인 유지</span>
              </div>
              <div className="actions">
                {(["check_in", "go_out", "return", "check_out"] as const).map((a) => {
                  const allowed = ALLOWED[today.status].includes(a);
                  return (
                    <button
                      key={a}
                      className={`action-btn${allowed ? " primary" : ""}`}
                      disabled={!allowed || busy || !networkOk}
                      onClick={() => act(a)}
                    >
                      <span className="icon" aria-hidden>{ACTION_ICON[a]}</span>
                      {ACTION_LABEL[a]}
                    </button>
                  );
                })}
              </div>
              {error && <p className="notice error" style={{ marginTop: 14 }}>{error}</p>}
              {pending.current && !busy && (
                <button className="btn plain block" style={{ marginTop: 10 }} onClick={submitPending}>다시 시도</button>
              )}
              {today.status === "checked_out" && (
                <p className="notice" style={{ marginTop: 14 }}>오늘 퇴실까지 기록했습니다. 다시 입실해야 한다면 운영자에게 말씀해 주세요.</p>
              )}
            </div>

            <div className="card">
              <h2>오늘 기록</h2>
              {today.events.length === 0 ? (
                <p className="empty">아직 기록이 없습니다.</p>
              ) : (
                <ul className="timeline">
                  {today.events.map((ev, i) => (
                    <li key={i}><time>{formatTime(ev.at)}</time>{ACTION_LABEL[ev.action]}</li>
                  ))}
                </ul>
              )}
            </div>
          </>
        )}

        {phase === "done" && receipt && (
          <div className="card center">
            <div className="done-mark" aria-hidden>✓</div>
            <h2 style={{ fontSize: 22 }}>{ACTION_LABEL[receipt.action]}을 기록했습니다.</h2>
            <p className="small">{DONE_MESSAGE[receipt.action]}</p>
            <div className="receipt" style={{ textAlign: "left" }}>
              <div><span>교육생</span><b>{receipt.studentName} · {receipt.courseName}</b></div>
              <div><span>구분</span><b>{ACTION_LABEL[receipt.action]}</b></div>
              <div><span>기록 시각</span><b>{formatTime(receipt.at, true)}</b></div>
            </div>
            <button className="btn block" onClick={backToToday}>오늘 기록 보기</button>
            <p className="small" style={{ marginTop: 14 }}>LMS 출결은 별도로 확인해 주세요.</p>
          </div>
        )}
      </div>
    </main>
  );
}
