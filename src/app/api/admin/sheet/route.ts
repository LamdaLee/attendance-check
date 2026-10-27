import { callApi } from "@/lib/db";
import { fail, respond } from "@/lib/http";
import { isDate, isId, operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  const course = param(url, "course");
  const enrollment = param(url, "enrollment");
  const courseId = course === null ? null : Number(course);
  const enrollmentId = enrollment === null ? null : Number(enrollment);
  if (!isDate(from) || !isDate(to)) return fail("bad_request");
  if ((courseId === null) === (enrollmentId === null)) return fail("bad_request");
  if ((courseId !== null && !isId(courseId)) || (enrollmentId !== null && !isId(enrollmentId))) return fail("bad_request");
  return respond(await callApi("api_operator_sheet", [token, param(url, "region"), courseId, enrollmentId, from, to]));
});
