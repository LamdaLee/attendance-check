import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isId, operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) =>
  respond(await callApi("api_operator_codes", [token, param(url, "region")])),
);

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<{ campusId?: number; action?: string }>(req);
    if (!isId(body?.campusId) || (body.action !== "on" && body.action !== "off")) return fail("bad_request");
    return respond(await callApi("api_operator_code_set", [token, body.campusId, body.action]));
  },
  { mutation: true },
);
