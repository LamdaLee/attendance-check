import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, operatorRoute, param } from "@/lib/route";

const STATUSES = new Set(["pending", "approved", "rejected"]);

export const GET = operatorRoute(async ({ token, url }) => {
  const status = param(url, "status");
  if (status && !STATUSES.has(status)) return fail("bad_request");
  return respond(await callApi("api_operator_corrections", [token, param(url, "region"), status]));
});

type Body = {
  action?: "save" | "reject";
  enrollmentId?: number;
  date?: string;
  timeline?: { action: string; at: string }[];
  basis?: string;
  requestId?: number | null;
  expectedVersion?: number;
};

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    if (body.action === "reject") {
      if (!isId(body.requestId)) return fail("bad_request");
      return respond(await callApi("api_operator_correction_reject", [token, body.requestId, body.basis ?? ""]));
    }
    if (body.action !== "save" || !isId(body.enrollmentId) || !isDate(body.date) || !Array.isArray(body.timeline)
        || body.timeline.length > 40 || typeof body.expectedVersion !== "number") {
      return fail("bad_request");
    }
    if (body.requestId != null && !isId(body.requestId)) return fail("bad_request");
    const timeline = body.timeline.map((t) => ({ action: String(t.action), at: String(t.at) }));
    return respond(await callApi("api_operator_correction_save", [
      token, body.enrollmentId, body.date, JSON.stringify(timeline), body.basis ?? "",
      body.requestId ?? null, body.expectedVersion,
    ]));
  },
  { mutation: true },
);
