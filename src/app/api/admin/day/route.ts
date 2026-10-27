import { callApi } from "@/lib/db";
import { fail, respond } from "@/lib/http";
import { isDate, isId, operatorRoute } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => {
  const id = Number(url.searchParams.get("enrollment"));
  const date = url.searchParams.get("date");
  if (!isId(id) || !isDate(date)) return fail("bad_request");
  return respond(await callApi("api_operator_day", [token, id, date]));
});
