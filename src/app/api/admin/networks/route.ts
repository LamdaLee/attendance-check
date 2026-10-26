import { isIP } from "node:net";
import { callApi } from "@/lib/db";
import { hashToken } from "@/lib/crypto";
import { OPERATOR_COOKIE, fail, guarded, isSameOrigin, readCookie, readJson, respond } from "@/lib/http";

export async function GET(req: Request) {
  return guarded(async () => {
    const token = readCookie(req, OPERATOR_COOKIE);
    if (!token) return fail("session_expired");
    const region = new URL(req.url).searchParams.get("region");
    return respond(await callApi("api_operator_networks", [hashToken(token), region]));
  });
}

type Body = {
  id?: number | null;
  campusId?: number | null;
  label?: string;
  network?: string;
  status?: string;
  validFrom?: string | null;
  validUntil?: string | null;
  reason?: string;
  expectedVersion?: number | null;
  confirmLast?: boolean;
};

// "198.51.100.24" 처럼 범위 없이 입력하면 단일 주소(/32, /128)로 본다.
function toCidr(value: string | undefined): string | null | undefined {
  if (!value) return undefined;
  const [addr, mask, extra] = value.trim().split("/");
  const family = isIP(addr);
  if (!family || extra !== undefined) return null;
  const max = family === 4 ? 32 : 128;
  if (mask === undefined) return `${addr}/${max}`;
  if (!/^\d+$/.test(mask) || Number(mask) > max) return null;
  return `${addr}/${mask}`;
}

function toTimestamp(value: string | null | undefined): string | null | false {
  if (!value) return null;
  const t = new Date(value);
  return Number.isNaN(t.getTime()) ? false : t.toISOString();
}

export async function POST(req: Request) {
  return guarded(async () => {
    if (!isSameOrigin(req)) return fail("forbidden");
    const token = readCookie(req, OPERATOR_COOKIE);
    if (!token) return fail("session_expired");
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");

    const network = toCidr(body.network);
    const validFrom = toTimestamp(body.validFrom);
    const validUntil = toTimestamp(body.validUntil);
    if (network === null || validFrom === false || validUntil === false) return fail("invalid_input");
    if (body.status !== "deleted" && !network) return fail("invalid_input");

    try {
      return respond(await callApi("api_operator_network_save", [
        hashToken(token),
        body.id ?? null,
        body.campusId ?? null,
        body.label ?? "",
        network ?? null,
        body.status ?? "testing",
        validFrom,
        validUntil,
        body.reason ?? "",
        body.expectedVersion ?? null,
        body.confirmLast === true,
      ]));
    } catch (err) {
      // cidr 형식 오류(호스트 비트가 남은 범위 등)는 입력 오류로 돌려준다.
      if ((err as { code?: string }).code === "22P02") return fail("invalid_input");
      throw err;
    }
  });
}
