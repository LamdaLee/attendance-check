import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, isId, operatorRoute } from "@/lib/route";

// 발급 이력
export const GET = operatorRoute(async ({ token, url }) => {
  const id = Number(url.searchParams.get("enrollment"));
  if (!isId(id)) return fail("bad_request");
  return respond(await callApi("api_operator_certificates", [token, id]));
});

type Body = { enrollmentId?: number; from?: string; to?: string };

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body || !isId(body.enrollmentId) || !isDate(body.from) || !isDate(body.to)) return fail("bad_request");
    return respond(await callApi("api_operator_certificate", [token, body.enrollmentId, body.from, body.to]));
  },
  { mutation: true },
);
