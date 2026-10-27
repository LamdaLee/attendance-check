import { callApi } from "@/lib/db";
import { respond } from "@/lib/http";
import { operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => {
  const minutes = Number(param(url, "minutes") ?? 60);
  return respond(await callApi("api_operator_blocked", [token, param(url, "region"), Number.isFinite(minutes) ? minutes : 60]));
});
