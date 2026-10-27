"use client";

import QRCode from "qrcode";
import { useCallback, useEffect, useState } from "react";
import { useOperator } from "./AdminShell";
import { BlockedPanel, CodePanel, type CodeInfo } from "./PresencePanels";
import { messageFor } from "@/lib/messages";

type Network = {
  id: number;
  label: string;
  network: string;
  status: "testing" | "active" | "paused";
  validFrom: string | null;
  validUntil: string | null;
  version: number;
  updatedAt: string;
};
type Campus = { id: number; name: string; qrCode: string; networks: Network[] };

type Form = {
  id: number | null;
  campusId: number;
  label: string;
  network: string;
  status: string;
  validFrom: string;
  validUntil: string;
  reason: string;
  expectedVersion: number | null;
};

const kst = (iso: string) => new Date(iso).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" });

const STATUS_TEXT: Record<string, string> = { testing: "시험 등록", active: "사용 중", paused: "중지" };

// datetime-local(브라우저 현지 시각) ↔ ISO
function toLocalInput(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  return new Date(d.getTime() - d.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
}
function fromLocalInput(value: string): string | null {
  return value ? new Date(value).toISOString() : null;
}

// 단일 주소는 /32, /128 없이 보여준다.
function displayNetwork(cidr: string): string {
  return cidr.replace(/\/(32|128)$/, "");
}

function CampusQr({ code }: { code: string }) {
  const [svg, setSvg] = useState("");
  const url = typeof window === "undefined" ? "" : `${window.location.origin}/c/${code}`;
  useEffect(() => {
    if (url) QRCode.toString(url, { type: "svg", margin: 1 }).then(setSvg).catch(() => setSvg(""));
  }, [url]);
  return (
    <div className="qr-box">
      <span dangerouslySetInnerHTML={{ __html: svg }} />
      <div>
        <div className="small">교육장 QR 주소 (개인정보 없음)</div>
        <div className="mono">{url}</div>
      </div>
    </div>
  );
}

export default function NetworkManager() {
  const { region } = useOperator();
  const [campuses, setCampuses] = useState<Campus[] | null>(null);
  const [form, setForm] = useState<Form | null>(null);
  const [myIp, setMyIp] = useState<string | null>(null);
  const [message, setMessage] = useState<{ kind: "ok" | "error" | "warn"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [codes, setCodes] = useState<Record<number, CodeInfo>>({});

  const load = useCallback(async () => {
    fetch(`/api/admin/codes?region=${encodeURIComponent(region)}`, { cache: "no-store" })
      .then((res) => res.json())
      .then((r) => r.ok && setCodes(Object.fromEntries((r.campuses as CodeInfo[]).map((c) => [c.campusId, c]))))
      .catch(() => {});
    const res = await fetch(`/api/admin/networks?region=${encodeURIComponent(region)}`, { cache: "no-store" });
    const r = await res.json();
    if (!r.ok) {
      if (r.code === "session_expired") window.location.replace("/admin");
      setMessage({ kind: "error", text: messageFor(r.code) });
      return;
    }
    setCampuses(r.campuses);
  }, [region]);

  useEffect(() => {
    setCampuses(null);
    setForm(null);
    load().catch(() => setMessage({ kind: "error", text: messageFor("server_error") }));
  }, [load]);

  async function checkMyIp() {
    const r = await fetch("/api/admin/my-ip", { cache: "no-store" }).then((res) => res.json()).catch(() => null);
    if (r?.ok) setMyIp(r.ip);
    else setMessage({ kind: "error", text: messageFor(r?.code ?? "server_error") });
  }

  function openNew(campusId: number) {
    setMessage(null);
    setForm({ id: null, campusId, label: "", network: "", status: "testing", validFrom: "", validUntil: "", reason: "", expectedVersion: null });
  }

  function openEdit(campusId: number, n: Network, status?: string) {
    setMessage(null);
    setForm({
      id: n.id, campusId, label: n.label, network: displayNetwork(n.network), status: status ?? n.status,
      validFrom: toLocalInput(n.validFrom), validUntil: toLocalInput(n.validUntil), reason: "", expectedVersion: n.version,
    });
  }

  async function save(f: Form, confirmLast = false) {
    setBusy(true);
    setMessage(null);
    try {
      const res = await fetch("/api/admin/networks", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          id: f.id, campusId: f.campusId, label: f.label, network: f.network, status: f.status,
          validFrom: fromLocalInput(f.validFrom), validUntil: fromLocalInput(f.validUntil),
          reason: f.reason, expectedVersion: f.expectedVersion, confirmLast,
        }),
      });
      const r = await res.json();
      if (!r.ok && r.code === "last_active_network") {
        if (window.confirm("이 교육장의 마지막 사용 중 주소입니다. 계속하면 이 교육장의 학생 출결 입력이 중단됩니다. 진행할까요?")) {
          await save(f, true);
        }
        return;
      }
      if (!r.ok) {
        setMessage({ kind: "error", text: messageFor(r.code) });
        return;
      }
      setForm(null);
      setMessage({
        kind: r.overlap ? "warn" : "ok",
        text: r.overlap ? "저장했습니다. 다른 지역 주소와 겹치므로 총괄 운영자 확인이 필요합니다." : "저장했습니다.",
      });
      await load();
    } catch {
      setMessage({ kind: "error", text: messageFor("server_error") });
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="a-title">
        <div>
          <h1>교육장 IP 관리</h1>
          <span className="small">등록된 인터넷 회선(공인 IP)에서만 학생 출결을 허용합니다. 와이파이 이름이나 192.168… 내부 주소가 아닙니다.</span>
        </div>
        <div className="row">
          {myIp && <span className="mono">현재 접속 IP {myIp}</span>}
          <button className="btn plain" onClick={checkMyIp}>현재 접속 IP 확인</button>
        </div>
      </div>

      {message && <p className={`notice ${message.kind}`}>{message.text}</p>}
      <BlockedPanel
        region={region}
        onAllowed={(text) => {
          setMessage({ kind: "ok", text });
          void load();
        }}
      />
      {!campuses && <p className="small">불러오는 중…</p>}
      {campuses?.length === 0 && <p className="notice">이 지역에 등록된 교육장이 없습니다. 관리 스크립트로 교육장을 추가해 주세요.</p>}

      {campuses?.map((c) => {
        const activeCount = c.networks.filter((n) => n.status === "active").length;
        return (
          <section className="panel" key={c.id}>
            <div className="row between" style={{ marginBottom: 12 }}>
              <div>
                <h2>{c.name}</h2>
                <span className={`tag ${activeCount ? "active" : ""}`}>사용 중 주소 {activeCount}개</span>
              </div>
              <button className="btn" onClick={() => openNew(c.id)}>IP 추가</button>
            </div>
            {activeCount === 0 && (
              <p className="notice warn">사용 중인 주소가 없어 이 교육장의 학생 출결 입력이 차단된 상태입니다.</p>
            )}
            <CampusQr code={c.qrCode} />
            <CodePanel campusId={c.id} info={codes[c.id]} onChange={load} />

            <div className="table-wrap" style={{ marginTop: 14 }}>
              <table>
                <thead><tr><th>표시 이름</th><th>허용 주소</th><th>상태</th><th>적용 기간</th><th>최근 변경</th><th>관리</th></tr></thead>
                <tbody>
                  {c.networks.map((n) => (
                    <tr key={n.id}>
                      <td>{n.label}</td>
                      <td className="mono">{displayNetwork(n.network)}</td>
                      <td><span className={`tag ${n.status}`}>{STATUS_TEXT[n.status]}</span></td>
                      <td className="small">
                        {n.validFrom || n.validUntil
                          ? `${n.validFrom ? kst(n.validFrom) : "지금"} ~ ${n.validUntil ? kst(n.validUntil) : "상시"}`
                          : "상시"}
                      </td>
                      <td className="small">{kst(n.updatedAt)}</td>
                      <td className="row">
                        <button className="btn plain sm" onClick={() => openEdit(c.id, n)}>변경</button>
                        <button className="btn danger sm" onClick={() => openEdit(c.id, n, "deleted")}>삭제</button>
                      </td>
                    </tr>
                  ))}
                  {c.networks.length === 0 && <tr><td colSpan={6} className="small center">등록된 주소가 없습니다.</td></tr>}
                </tbody>
              </table>
            </div>

            {form && form.campusId === c.id && (
              <form
                className="card"
                style={{ marginTop: 14, boxShadow: "none", border: "1.5px solid var(--line)" }}
                onSubmit={(e) => {
                  e.preventDefault();
                  void save(form);
                }}
              >
                <h2>{form.status === "deleted" ? "허용 IP 삭제" : form.id ? "허용 IP 변경" : "허용 IP 추가"}</h2>
                {form.status === "deleted" ? (
                  <p className="notice warn">
                    {form.label} ({form.network})을(를) 삭제합니다. 화면에서만 사라지고, 과거 출결에 적용된 이력은 보관됩니다.
                  </p>
                ) : (
                  <>
                    <p className="small">현재 접속 IP를 쓰려면 교육장 와이파이에 연결한 상태인지 먼저 확인하세요. 집·모바일 IP를 등록하지 않도록 주의해 주세요.</p>
                    <div className="grid-2">
                      <label className="field">표시 이름<input value={form.label} onChange={(e) => setForm({ ...form, label: e.target.value })} required placeholder="예: 본관 공용 와이파이" /></label>
                      <label className="field">
                        허용 주소 (IPv4 또는 IPv6)
                        <input value={form.network} onChange={(e) => setForm({ ...form, network: e.target.value })} required placeholder="예: 198.51.100.24" className="mono" />
                        {myIp && (
                          <button type="button" className="btn ghost sm" style={{ marginTop: 6 }} onClick={() => setForm({ ...form, network: myIp })}>
                            현재 접속 IP {myIp} 넣기
                          </button>
                        )}
                      </label>
                      <label className="field">
                        상태
                        <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
                          <option value="testing">시험 등록 (학생 출결에 아직 미적용)</option>
                          <option value="active">사용 중</option>
                          <option value="paused">중지</option>
                        </select>
                      </label>
                      <div />
                      <label className="field">적용 시작 (선택)<input type="datetime-local" value={form.validFrom} onChange={(e) => setForm({ ...form, validFrom: e.target.value })} /></label>
                      <label className="field">적용 종료 (선택)<input type="datetime-local" value={form.validUntil} onChange={(e) => setForm({ ...form, validUntil: e.target.value })} /></label>
                    </div>
                  </>
                )}
                {form.id && (
                  <label className="field">
                    변경 사유 (필수)
                    <textarea value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} required placeholder="회선 교체, 주소 변경, 장소 폐쇄 등" />
                  </label>
                )}
                <div className="row" style={{ justifyContent: "flex-end" }}>
                  <button type="button" className="btn plain" onClick={() => setForm(null)}>취소</button>
                  <button className={`btn${form.status === "deleted" ? " danger" : ""}`} disabled={busy}>
                    {form.status === "deleted" ? "삭제" : "저장"}
                  </button>
                </div>
              </form>
            )}
          </section>
        );
      })}
      <p className="small">회선을 바꿀 때는 새 주소를 먼저 사용 중으로 바꿔 현장에서 확인한 뒤 이전 주소를 중지하세요.</p>
    </>
  );
}
