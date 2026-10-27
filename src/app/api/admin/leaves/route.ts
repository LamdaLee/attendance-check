import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, operatorRoute, param } from "@/lib/route";

const KINDS = new Set(["sick", "interview", "reserve", "family", "other"]);
const PARTS = new Set(["full", "partial"]);
const DECISIONS = new Set(["approved", "rejected", "cancelled"]);

export const GET = operatorRoute(async ({ token, url }) => {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  if (!isDate(from) || !isDate(to)) return fail("bad_request");
  return respond(await callApi("api_operator_leaves", [token, param(url, "region"), from, to]));
});

type Body = {
  action?: "create" | "decide";
  enrollmentId?: number;
  from?: string;
  to?: string;
  kind?: string;
  part?: string;
  reason?: string;
  approved?: boolean;
  id?: number;
  decision?: string;
  note?: string;
  version?: number;
};

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    if (body.action === "decide") {
      if (!isId(body.id) || !DECISIONS.has(body.decision ?? "") || !Number.isSafeInteger(body.version)) return fail("bad_request");
      return respond(await callApi("api_operator_leave_decide", [token, body.id, body.decision, body.note ?? "", body.version]));
    }
    if (!isId(body.enrollmentId) || !isDate(body.from) || !isDate(body.to) || !KINDS.has(body.kind ?? "")
        || !PARTS.has(body.part ?? "") || typeof body.reason !== "string") return fail("bad_request");
    return respond(await callApi("api_operator_leave_create", [
      token, body.enrollmentId, body.from, body.to, body.kind, body.part, body.reason, body.approved === true,
    ]));
  },
  { mutation: true },
);
