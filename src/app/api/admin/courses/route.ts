import { callApi } from "@/lib/db";
import { respond } from "@/lib/http";
import { operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) =>
  respond(await callApi("api_operator_courses", [token, param(url, "region")])),
);
