// 브라우저에서 앱 API 호출. 운영자 세션이 끝나면 입장 화면으로 보낸다.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Res = { ok: boolean; code?: string; [key: string]: any };

export async function api(url: string, body?: unknown): Promise<Res> {
  try {
    const res = await fetch(url, body === undefined
      ? { cache: "no-store" }
      : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const r = (await res.json()) as Res;
    if (r.code === "session_expired" && url.startsWith("/api/admin")) window.location.replace("/admin");
    return r;
  } catch {
    return { ok: false, code: "server_error" };
  }
}

// HH:MM (한국시간) → ISO
export function kstIso(date: string, hhmm: string): string {
  return `${date}T${hhmm}:00+09:00`;
}

export function kstHHMM(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Seoul", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(iso));
}
