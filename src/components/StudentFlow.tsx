"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ACTION_LABEL, LEAVE_KIND_LABEL, LEAVE_STATUS_LABEL, NOTICE_LABEL, REQUEST_STATUS_LABEL, STATUS_LABEL, addDays,
  formatDate, formatTime, leaveText, messageFor, noticeText, todayInSeoul,
} from "@/lib/messages";

type Campus = { name: string; regionCode: string; regionName: string };
type Today = {
  studentName: string;
  courseName: string;
  campusName: string;
  campusCode: string;
  regionName: string;
  sessionExpiresAt: string;
  networkVerified: boolean;
  // 현장 확인 방법: 교육장 회선 또는 오늘의 출석코드. 없으면 알림·정정 요청만 가능
  presence: "network" | "code" | null;
  codeMode: boolean;
  // 현장 확인된 세션에만 온다.
  status?: keyof typeof STATUS_LABEL;
  events?: { action: string; at: string }[];
};
type Receipt = { action: string; at: string; studentName: string; courseName: string };
type Pending = { action: string; requestId: string };
type Notice = { id: number; date: string; kind: string; expectedTime: string | null; reason: string; status: string; cancellable: boolean };
type Request = { date: string; reason: string; status: string; note: string | null };
type Leave = {
  id: number;
  startsOn: string;
  endsOn: string;
  kind: string;
  part: string;
  reason: string;
  status: string;
  decisionNote: string | null;
  cancellable: boolean;
};

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
  const [phase, setPhase] = useState<"loading" | "campus_error" | "verify" | "home" | "done">("loading");
  const [campus, setCampus] = useState<Campus | null>(null);
  const [networkOk, setNetworkOk] = useState(false);
  const [codeMode, setCodeMode] = useState(false);
  const [today, setToday] = useState<Today | null>(null);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
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
        return null;
      }
      setCampus(r.campus);
      setNetworkOk(r.networkOk);
      setCodeMode(r.codeMode);
      return r.networkOk as boolean;
    } catch {
      setError(messageFor("server_error"));
      return null;
    }
  }, [code]);

  const loadToday = useCallback(async () => {
    const r = await getJson("/api/student/today");
    // 다른 교육장 QR로 들어왔다면 그 교육장에서 다시 본인 확인을 받는다.
    if (r.ok && r.campusCode === code) {
      setToday(r);
      setPhase("home");
      return r as Today;
    }
    setToday(null);
    setPhase("verify");
    return null;
  }, [code]);

  useEffect(() => {
    (async () => {
      if ((await loadCampus()) !== null) await loadToday().catch(() => setPhase("verify"));
    })();
  }, [loadCampus, loadToday]);

  // 세션 만료 시 본인 확인 화면으로
  useEffect(() => {
    if (phase !== "home" || !today) return;
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
    setInfo(null);
    if (!/^\d{4}$/.test(last4)) {
      setError("전화번호 뒷자리 4자리를 숫자로 입력해 주세요.");
      return;
    }
    setBusy(true);
    try {
      const r = await postJson("/api/student/verify", { code, name, last4 });
      if (!r.ok) {
        setError(messageFor(r.code));
        return;
      }
      setLast4("");
      setNetworkOk(r.networkVerified);
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

  async function backToHome() {
    setReceipt(null);
    await loadToday();
  }

  async function switchStudent() {
    await fetch("/api/student/logout", { method: "POST" }).catch(() => {});
    setToday(null);
    setError(null);
    setInfo(null);
    setName("");
    setPhase("verify");
  }

  async function recheckNetwork() {
    setError(null);
    const ok = await loadCampus();
    // 교육장 밖에서 확인했던 세션이면, 교육장 회선에서 다시 확인해야 출결 버튼을 쓸 수 있다.
    if (ok && today && !today.networkVerified) {
      setToday(null);
      setPhase("verify");
      setInfo("교육장 네트워크가 확인됐습니다. 출결을 기록하려면 본인 확인을 다시 해 주세요.");
    }
  }

  const eyebrow = campus ? `${campus.regionName} · ${campus.name}` : "QR 출결";

  return (
    <main className="m-shell">
      <section className="m-hero">
        <p className="eyebrow">{eyebrow}</p>
        {phase === "home" && today ? (
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

        {(phase === "verify" || phase === "home") && (
          <div className="card row between">
            {phase === "home" && today?.presence === "code" && !networkOk ? (
              <span className="pill ok"><span className="dot" />출석코드로 확인됨</span>
            ) : networkOk ? (
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
            {info && <p className="notice ok">{info}</p>}
            {!networkOk && codeMode && (
              <p className="notice warn">
                교육장 와이파이로 확인되지 않습니다. 강의장에서 <b>오늘의 출석코드</b>를 안내받았다면 본인 확인 후 코드를 입력해 출결할 수 있습니다.
              </p>
            )}
            {!networkOk && !codeMode && (
              <p className="notice warn">
                출결 기록은 교육장 와이파이에서만 할 수 있습니다. 교육장 밖에서는 본인 확인 후
                <b> 지각·결석·조퇴 예정 알림</b>과 <b>정정 요청</b>만 보낼 수 있습니다.
              </p>
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
            <button className="btn block" disabled={busy}>{busy ? "확인 중…" : "본인 확인"}</button>
            <p className="small" style={{ marginTop: 14 }}>이 기록은 보조 출결 자료입니다. LMS 입·퇴실도 따로 확인해 주세요.</p>
          </form>
        )}

        {phase === "home" && today && (
          <>
            {today.presence && today.status ? (
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
                      const allowed = ALLOWED[today.status!].includes(a);
                      return (
                        <button
                          key={a}
                          className={`action-btn${allowed ? " primary" : ""}`}
                          disabled={!allowed || busy || !(networkOk || today.presence === "code")}
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
                  {!today.events?.length ? (
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
            ) : today.codeMode ? (
              <CodeCard onDone={loadToday} />
            ) : (
              <div className="card">
                <p className="notice warn" style={{ margin: 0 }}>
                  교육장 밖에서 본인 확인을 했습니다. 아래에서 알림과 정정 요청을 보낼 수 있습니다.
                  출결 기록과 오늘 기록 보기는 교육장 와이파이에서만 됩니다.
                </p>
                {error && <p className="notice error" style={{ marginTop: 10 }}>{error}</p>}
              </div>
            )}

            <NoticeCard />
            <LeaveCard />
            <CorrectionCard />
            <button className="btn plain block" onClick={switchStudent}>다른 교육생으로 확인 · 확인 종료</button>
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
            <button className="btn block" onClick={backToHome}>오늘 기록 보기</button>
            <p className="small" style={{ marginTop: 14 }}>LMS 출결은 별도로 확인해 주세요.</p>
          </div>
        )}
      </div>
    </main>
  );
}

// 오늘의 출석코드 입력 (교육장 회선으로 확인되지 않을 때)
function CodeCard({ onDone }: { onDone: () => Promise<unknown> }) {
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const r = await postJson("/api/student/code", { code }).catch(() => ({ ok: false, code: "server_error" }));
    setBusy(false);
    if (!r.ok) {
      setError(messageFor(r.code));
      return;
    }
    await onDone();
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>오늘의 출석코드</h2>
      <p className="small" style={{ marginTop: -6 }}>
        교육장 와이파이로 확인되지 않아 출석코드로 기록합니다. 강의장에 안내된 6자리 숫자를 입력해 주세요.
        코드로 남긴 기록은 운영자 화면에 따로 표시됩니다.
      </p>
      <label className="field">
        출석코드
        <input
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))}
          inputMode="numeric"
          autoComplete="one-time-code"
          pattern="\d{6}"
          required
          placeholder="000000"
          style={{ fontSize: 24, letterSpacing: 6, textAlign: "center" }}
        />
      </label>
      {error && <p className="notice error">{error}</p>}
      <button className="btn block" disabled={busy || code.length !== 6}>코드 확인</button>
    </form>
  );
}

// 지각·결석·조퇴 예정 알림 (교육장 밖에서도 가능)
function NoticeCard() {
  const today = todayInSeoul();
  const [kind, setKind] = useState("late");
  const [date, setDate] = useState(today);
  const [time, setTime] = useState("");
  const [reason, setReason] = useState("");
  const [items, setItems] = useState<Notice[]>([]);
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const r = await getJson("/api/student/notices").catch(() => null);
    if (r?.ok) setItems(r.notices);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMessage(null);
    const r = await postJson("/api/student/notices", {
      action: "create", kind, date, expectedTime: kind === "absent" ? null : time || null, reason,
    }).catch(() => ({ ok: false, code: "server_error" }));
    setBusy(false);
    if (!r.ok) {
      setMessage({ kind: "error", text: messageFor(r.code) });
      return;
    }
    setReason("");
    setTime("");
    setMessage({ kind: "ok", text: `${NOTICE_LABEL[kind]} 알림을 보냈습니다. 운영자 화면에 표시됩니다.` });
    await load();
  }

  async function cancel(id: number) {
    if (!window.confirm("이 알림을 취소할까요?")) return;
    const r = await postJson("/api/student/notices", { action: "cancel", id }).catch(() => ({ ok: false, code: "server_error" }));
    if (!r.ok) setMessage({ kind: "error", text: messageFor(r.code) });
    await load();
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>미리 알리기</h2>
      <p className="small" style={{ marginTop: -6 }}>늦거나 빠지거나 일찍 나가야 할 때 미리 알려 주세요. 출결 기록이 바뀌지는 않습니다.</p>
      <div className="seg" role="radiogroup" aria-label="알림 종류">
        {Object.entries(NOTICE_LABEL).map(([k, v]) => (
          <button type="button" key={k} role="radio" aria-checked={kind === k} className={kind === k ? "on" : undefined} onClick={() => setKind(k)}>
            {v.replace(" 예정", "")}
          </button>
        ))}
      </div>
      <label className="field">
        날짜
        <input type="date" value={date} min={today} max={addDays(today, 14)} onChange={(e) => setDate(e.target.value)} required />
      </label>
      {kind !== "absent" && (
        <label className="field">
          {kind === "late" ? "도착 예정 시각" : "나갈 예정 시각"} (선택)
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} />
        </label>
      )}
      <label className="field">
        사유
        <textarea value={reason} onChange={(e) => setReason(e.target.value)} required maxLength={300} placeholder="예: 병원 진료 후 도착 예정" />
      </label>
      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      <button className="btn block" disabled={busy}>알림 보내기</button>

      {items.length > 0 && (
        <ul className="mini-list" style={{ marginTop: 14 }}>
          {items.map((n) => (
            <li key={n.id} style={n.status === "cancelled" ? { opacity: 0.5 } : undefined}>
              <span>
                <b>{formatDate(n.date)}</b> {noticeText(n)}
                {n.status === "cancelled" && " · 취소됨"}
                <br /><span className="small">{n.reason}</span>
              </span>
              {n.cancellable && <button type="button" className="btn plain sm" onClick={() => cancel(n.id)}>취소</button>}
            </li>
          ))}
        </ul>
      )}
    </form>
  );
}

// 공가 신청 (교육장 밖에서도 가능). 증빙 서류가 확인되면 운영자가 인정으로 바꾼다.
function LeaveCard() {
  const today = todayInSeoul();
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState("sick");
  const [part, setPart] = useState("full");
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(today);
  const [reason, setReason] = useState("");
  const [items, setItems] = useState<Leave[]>([]);
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const r = await getJson("/api/student/leaves").catch(() => null);
    if (r?.ok) setItems(r.leaves);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMessage(null);
    const r = await postJson("/api/student/leaves", { action: "create", from, to: to < from ? from : to, kind, part, reason })
      .catch(() => ({ ok: false, code: "server_error" }));
    setBusy(false);
    if (!r.ok) {
      setMessage({ kind: "error", text: messageFor(r.code) });
      return;
    }
    setReason("");
    setOpen(false);
    setMessage({ kind: "ok", text: "공가를 신청했습니다. 증빙 서류를 담당 매니저에게 제출하면 확인 후 인정으로 바뀝니다." });
    await load();
  }

  async function cancel(id: number) {
    if (!window.confirm("이 공가 신청을 취소할까요?")) return;
    const r = await postJson("/api/student/leaves", { action: "cancel", id }).catch(() => ({ ok: false, code: "server_error" }));
    if (!r.ok) setMessage({ kind: "error", text: messageFor(r.code) });
    await load();
  }

  return (
    <div className="card">
      <div className="row between">
        <h2 style={{ margin: 0 }}>공가 신청</h2>
        <button type="button" className="btn ghost sm" onClick={() => setOpen(!open)}>{open ? "닫기" : "신청하기"}</button>
      </div>
      <p className="small">병원 진료, 면접, 예비군처럼 서류로 인정받는 일정입니다. 서류가 확인되면 인정으로 바뀝니다.</p>
      {open && (
        <form onSubmit={submit}>
          <div className="seg" role="radiogroup" aria-label="공가 종류" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
            {Object.entries(LEAVE_KIND_LABEL).map(([k, v]) => (
              <button type="button" key={k} role="radio" aria-checked={kind === k} className={kind === k ? "on" : undefined} onClick={() => setKind(k)}>
                {v}
              </button>
            ))}
          </div>
          <div className="seg" role="radiogroup" aria-label="시간" style={{ gridTemplateColumns: "1fr 1fr" }}>
            <button type="button" role="radio" aria-checked={part === "full"} className={part === "full" ? "on" : undefined} onClick={() => setPart("full")}>하루 전체</button>
            <button type="button" role="radio" aria-checked={part === "partial"} className={part === "partial" ? "on" : undefined} onClick={() => setPart("partial")}>일부 시간</button>
          </div>
          <div className="grid-2" style={{ gridTemplateColumns: "1fr 1fr" }}>
            <label className="field">
              시작일
              <input type="date" value={from} min={addDays(today, -14)} max={addDays(today, 30)} onChange={(e) => { setFrom(e.target.value); if (to < e.target.value) setTo(e.target.value); }} required />
            </label>
            <label className="field">
              종료일
              <input type="date" value={to} min={from} max={addDays(from, 13)} onChange={(e) => setTo(e.target.value)} required />
            </label>
          </div>
          <label className="field">
            사유
            <textarea value={reason} onChange={(e) => setReason(e.target.value)} required maxLength={300}
              placeholder={part === "partial" ? "예: 14시 면접으로 13시 조퇴" : "예: 장염으로 병원 진료, 진료확인서 제출 예정"} />
          </label>
          {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
          <button className="btn block" disabled={busy}>공가 신청</button>
        </form>
      )}
      {!open && message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      {items.length > 0 && (
        <ul className="mini-list" style={{ marginTop: 10 }}>
          {items.map((l) => (
            <li key={l.id} style={l.status === "cancelled" ? { opacity: 0.5 } : undefined}>
              <span>
                <b>{formatDate(l.startsOn)}{l.endsOn !== l.startsOn && ` ~ ${formatDate(l.endsOn)}`}</b> {leaveText(l)}
                <br /><span className="small">{l.reason}</span>
                {l.decisionNote && <><br /><span className="small">운영자: {l.decisionNote}</span></>}
              </span>
              <span className="row" style={{ flexWrap: "nowrap" }}>
                <span className={`tag ${l.status === "approved" ? "approved" : l.status === "waiting_docs" ? "pending" : "rejected"}`}>{LEAVE_STATUS_LABEL[l.status]}</span>
                {l.cancellable && <button type="button" className="btn plain sm" onClick={() => cancel(l.id)}>취소</button>}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// 기록 정정 요청 (교육장 밖에서도 가능)
function CorrectionCard() {
  const today = todayInSeoul();
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(today);
  const [reason, setReason] = useState("");
  const [items, setItems] = useState<Request[]>([]);
  const [message, setMessage] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const r = await getJson("/api/student/corrections").catch(() => null);
    if (r?.ok) setItems(r.requests);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMessage(null);
    const r = await postJson("/api/student/corrections", { date, reason }).catch(() => ({ ok: false, code: "server_error" }));
    setBusy(false);
    if (!r.ok) {
      setMessage({ kind: "error", text: messageFor(r.code) });
      return;
    }
    setReason("");
    setMessage({ kind: "ok", text: "정정 요청을 보냈습니다. 운영자가 확인한 뒤 결과가 여기에 표시됩니다." });
    await load();
  }

  return (
    <div className="card">
      <div className="row between">
        <h2 style={{ margin: 0 }}>기록 정정 요청</h2>
        <button type="button" className="btn ghost sm" onClick={() => setOpen(!open)}>{open ? "닫기" : "요청하기"}</button>
      </div>
      <p className="small">퇴실 체크를 잊었거나 기록이 잘못됐을 때 사유를 적어 보내 주세요.</p>
      {open && (
        <form onSubmit={submit}>
          <label className="field">
            날짜
            <input type="date" value={date} min={addDays(today, -30)} max={today} onChange={(e) => setDate(e.target.value)} required />
          </label>
          <label className="field">
            사유
            <textarea value={reason} onChange={(e) => setReason(e.target.value)} required maxLength={500} placeholder="예: 18시 5분에 퇴실했는데 체크를 못 했습니다." />
          </label>
          {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
          <button className="btn block" disabled={busy}>요청 보내기</button>
        </form>
      )}
      {!open && message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      {items.length > 0 && (
        <ul className="mini-list" style={{ marginTop: 10 }}>
          {items.map((q, i) => (
            <li key={i}>
              <span>
                <b>{formatDate(q.date)}</b> {q.reason}
                {q.note && <><br /><span className="small">운영자: {q.note}</span></>}
              </span>
              <span className={`tag ${q.status}`}>{REQUEST_STATUS_LABEL[q.status]}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
