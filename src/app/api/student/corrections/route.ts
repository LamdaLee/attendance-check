import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, studentRoute } from "@/lib/route";

export const GET = studentRoute(async ({ token }) => respond(await callApi("api_student_corrections", [token])));

export const POST = studentRoute(
  async ({ token, req }) => {
    const body = await readJson<{ date?: string; reason?: string }>(req);
    if (!isDate(body?.date) || typeof body?.reason !== "string") return fail("bad_request");
    return respond(await callApi("api_student_correction_request", [token, body.date, body.reason]));
  },
  { mutation: true },
);
