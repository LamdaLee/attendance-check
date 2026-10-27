import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, operatorRoute, param } from "@/lib/route";

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

// 과정 목록, 또는 ?days=<과정 id> 로 그 과정의 날짜별 일정
export const GET = operatorRoute(async ({ token, url }) => {
  const days = param(url, "days");
  if (days !== null) {
    const id = Number(days);
    if (!isId(id)) return fail("bad_request");
    return respond(await callApi("api_operator_course_days", [token, id]));
  }
  return respond(await callApi("api_operator_courses", [token, param(url, "region")]));
});

type Body = {
  action?: "create" | "save" | "day";
  region?: string;
  name?: string;
  courseId?: number;
  fullName?: string;
  startsOn?: string | null;
  endsOn?: string | null;
  start?: string;
  end?: string;
  lateAfter?: number;
  trainingMinutes?: number;
  active?: boolean;
  date?: string;
  kind?: string;
  minutes?: number | null;
  place?: string;
  note?: string;
};

const optDate = (v: unknown) => v === null || v === undefined || v === "" || isDate(v);

export const POST = operatorRoute(
  async ({ token, req }) => {
    const b = await readJson<Body>(req);
    if (!b) return fail("bad_request");
    if (b.action === "create") {
      if (typeof b.name !== "string") return fail("bad_request");
      return respond(await callApi("api_operator_course_create", [token, b.region ?? null, b.name]));
    }
    if (b.action === "save") {
      if (!isId(b.courseId) || !optDate(b.startsOn) || !optDate(b.endsOn) || !TIME.test(b.start ?? "") || !TIME.test(b.end ?? "")
          || !Number.isInteger(b.lateAfter) || !Number.isInteger(b.trainingMinutes)) return fail("bad_request");
      return respond(await callApi("api_operator_course_save", [
        token, b.courseId, b.fullName ?? "", b.startsOn || null, b.endsOn || null, b.start, b.end, b.lateAfter,
        b.trainingMinutes, b.active ?? null,
      ]));
    }
    if (b.action === "day") {
      if (!isId(b.courseId) || !isDate(b.date) || !["class", "off", "clear"].includes(b.kind ?? "")) return fail("bad_request");
      if (b.kind === "class" && (!TIME.test(b.start ?? "") || !TIME.test(b.end ?? "") || !Number.isInteger(b.minutes)))
        return fail("bad_request");
      return respond(await callApi("api_operator_course_day_set", [
        token, b.courseId, b.date, b.kind, b.kind === "class" ? b.start : null, b.kind === "class" ? b.end : null,
        b.kind === "class" ? b.minutes : null, b.place ?? "", b.note ?? "",
      ]));
    }
    return fail("bad_request");
  },
  { mutation: true },
);
