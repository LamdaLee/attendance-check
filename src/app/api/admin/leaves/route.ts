import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, operatorRoute, param } from "@/lib/route";

const KINDS = new Set(["sick", "interview", "exam", "civic", "other"]);
const PARTS = new Set(["full", "partial"]);

export const GET = operatorRoute(async ({ token, url }) => {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  if (!isDate(from) || !isDate(to)) return fail("bad_request");
  return respond(await callApi("api_operator_leaves", [token, param(url, "region"), from, to]));
});

type Body = {
  action?: "create" | "cancel" | "decide";
  decision?: string;
  enrollmentId?: number;
  from?: string;
  to?: string;
  kind?: string;
  part?: string;
  reason?: string;
  id?: number;
  note?: string;
  version?: number;
};

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    if (body.action === "decide") {
      if (!isId(body.id) || (body.decision !== "approved" && body.decision !== "rejected") || !Number.isSafeInteger(body.version))
        return fail("bad_request");
      return respond(await callApi("api_operator_leave_decide", [token, body.id, body.decision, body.note ?? "", body.version]));
    }
    if (body.action === "cancel") {
      if (!isId(body.id) || !Number.isSafeInteger(body.version)) return fail("bad_request");
      return respond(await callApi("api_operator_leave_cancel", [token, body.id, body.note ?? "", body.version]));
    }
    if (!isId(body.enrollmentId) || !isDate(body.from) || !isDate(body.to) || !KINDS.has(body.kind ?? "")
        || !PARTS.has(body.part ?? "") || typeof body.reason !== "string") return fail("bad_request");
    return respond(await callApi("api_operator_leave_create", [
      token, body.enrollmentId, body.from, body.to, body.kind, body.part, body.reason,
    ]));
  },
  { mutation: true },
);
