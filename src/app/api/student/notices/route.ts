import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, studentRoute } from "@/lib/route";

const KINDS = new Set(["late", "absent", "early_leave"]);

export const GET = studentRoute(async ({ token }) => respond(await callApi("api_student_notices", [token])));

type Body = { action?: "create" | "cancel"; id?: number; date?: string; kind?: string; expectedTime?: string; reason?: string };

export const POST = studentRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    if (body.action === "cancel") {
      if (!isId(body.id)) return fail("bad_request");
      return respond(await callApi("api_student_notice_cancel", [token, body.id]));
    }
    if (!isDate(body.date) || !KINDS.has(body.kind ?? "") || typeof body.reason !== "string") return fail("bad_request");
    const time = body.expectedTime || null;
    if (time !== null && !/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) return fail("invalid_input");
    return respond(await callApi("api_student_notice", [token, body.date, body.kind, time, body.reason]));
  },
  { mutation: true },
);
