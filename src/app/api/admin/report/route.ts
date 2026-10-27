import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, operatorRoute, param } from "@/lib/route";

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

export const GET = operatorRoute(async ({ token, url }) => {
  const date = url.searchParams.get("date");
  if (!isDate(date)) return fail("bad_request");
  return respond(await callApi("api_operator_report", [token, param(url, "region"), date]));
});

type Body = {
  action?: "note" | "hours";
  enrollmentId?: number;
  date?: string;
  note?: string;
  version?: number;
  courseId?: number;
  start?: string;
  end?: string;
  lateAfter?: number;
  lunchStart?: string;
  lunchEnd?: string;
};

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body) return fail("bad_request");
    if (body.action === "hours") {
      if (!isId(body.courseId) || !TIME.test(body.start ?? "") || !TIME.test(body.end ?? "") || !Number.isInteger(body.lateAfter)
          || !TIME.test(body.lunchStart ?? "") || !TIME.test(body.lunchEnd ?? ""))
        return fail("bad_request");
      return respond(await callApi("api_operator_course_hours", [
        token, body.courseId, body.start, body.end, body.lateAfter, body.lunchStart, body.lunchEnd,
      ]));
    }
    if (!isId(body.enrollmentId) || !isDate(body.date) || typeof body.note !== "string" || !Number.isSafeInteger(body.version))
      return fail("bad_request");
    return respond(await callApi("api_operator_day_note", [token, body.enrollmentId, body.date, body.note, body.version]));
  },
  { mutation: true },
);
