import { callApi } from "@/lib/db";
import { fail, respond } from "@/lib/http";
import { isDate, operatorRoute } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => {
  const date = url.searchParams.get("date");
  if (!isDate(date)) return fail("bad_request");
  return respond(await callApi("api_operator_overview", [token, date]));
});
