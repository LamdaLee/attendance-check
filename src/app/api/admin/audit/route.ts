import { callApi } from "@/lib/db";
import { fail, respond } from "@/lib/http";
import { operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => {
  const before = param(url, "before");
  if (before !== null && !/^\d+$/.test(before)) return fail("bad_request");
  return respond(await callApi("api_operator_audit", [token, param(url, "region"), before, 50]));
});
