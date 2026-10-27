import { callApi } from "@/lib/db";
import { last4Hmac, normalizeName } from "@/lib/crypto";
import { fail, readJson, respond } from "@/lib/http";
import { operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) =>
  respond(await callApi("api_operator_roster", [token, param(url, "region")])),
);

type InputRow = { name?: string; last4?: string; course?: string };
type Body = { region?: string; csv?: string; rows?: InputRow[]; apply?: boolean };
type ResultRow = { line: number; name: string; course: string; error: string | null };

// 첫 줄이 머리글이면 건너뛴다. 머리글: name,last4,course 또는 이름,뒷자리,과정
function parseCsv(text: string): (InputRow & { line: number })[] {
  const lines = text.replace(/^﻿/, "").split(/\r?\n/);
  const out: (InputRow & { line: number })[] = [];
  lines.forEach((raw, i) => {
    if (!raw.trim()) return;
    const cells = raw.split(",").map((c) => c.trim().replace(/^"(.*)"$/, "$1"));
    if (i === 0 && /^(name|이름)$/i.test(cells[0])) return;
    out.push({ line: i + 1, name: cells[0], last4: cells[1], course: cells[2] });
  });
  return out;
}

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    const input = body.csv !== undefined
      ? parseCsv(body.csv)
      : (body.rows ?? []).map((r, i) => ({ ...r, line: i + 1 }));
    if (input.length === 0 || input.length > 1000) return fail("invalid_input");

    // 형식 오류는 여기서 거르고, 과정·중복 검사는 DB가 한다.
    const local: ResultRow[] = [];
    const valid: { line: number; name: string; nameKey: string; hmac: string; course: string }[] = [];
    for (const r of input) {
      const name = (r.name ?? "").trim();
      const course = (r.course ?? "").trim();
      const last4 = (r.last4 ?? "").trim();
      let error: string | null = null;
      if (!name || name.length > 40) error = "invalid_name";
      else if (!/^\d{4}$/.test(last4)) error = "invalid_last4";
      else if (!course) error = "course_not_found";
      if (error) local.push({ line: r.line, name, course, error });
      else valid.push({ line: r.line, name, nameKey: normalizeName(name), hmac: last4Hmac(last4), course });
    }

    let dbRows: ResultRow[] = [];
    let applied = false;
    if (valid.length > 0) {
      const res = await callApi("api_operator_enroll", [token, body.region ?? null, JSON.stringify(valid), body.apply === true && local.length === 0]);
      if (!res.rows) return respond(res);
      dbRows = res.rows as ResultRow[];
      applied = res.applied === true;
    }
    const rows = [...local, ...dbRows].sort((a, b) => a.line - b.line);
    const errors = rows.filter((r) => r.error).length;
    return respond({ ok: errors === 0, code: errors ? "roster_errors" : undefined, applied, total: rows.length, errors, rows });
  },
  { mutation: true },
);
