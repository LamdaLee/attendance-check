import { callApi } from "@/lib/db";
import { fail, respond } from "@/lib/http";
import { isDate, operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  if (!isDate(from) || !isDate(to)) return fail("bad_request");
  return respond(await callApi("api_operator_issues", [token, param(url, "region"), from, to]));
});
