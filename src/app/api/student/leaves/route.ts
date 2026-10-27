import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, studentRoute } from "@/lib/route";

const LEAVE_KINDS = new Set(["sick", "interview", "reserve", "family", "other"]);
const LEAVE_PARTS = new Set(["full", "partial"]);

export const GET = studentRoute(async ({ token }) => respond(await callApi("api_student_leaves", [token])));

type Body = { action?: "create" | "cancel"; id?: number; from?: string; to?: string; kind?: string; part?: string; reason?: string };

export const POST = studentRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    if (body.action === "cancel") {
      if (!isId(body.id)) return fail("bad_request");
      return respond(await callApi("api_student_leave_cancel", [token, body.id]));
    }
    if (!isDate(body.from) || !isDate(body.to) || !LEAVE_KINDS.has(body.kind ?? "") || !LEAVE_PARTS.has(body.part ?? "")
        || typeof body.reason !== "string") return fail("bad_request");
    return respond(await callApi("api_student_leave", [token, body.from, body.to, body.kind, body.part, body.reason]));
  },
  { mutation: true },
);
