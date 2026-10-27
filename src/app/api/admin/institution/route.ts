import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { operatorRoute } from "@/lib/route";

export const GET = operatorRoute(async ({ token }) => respond(await callApi("api_operator_institutions", [token])));

type Body = { region?: string; name?: string };

export const POST = operatorRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body || typeof body.name !== "string") return fail("bad_request");
    return respond(await callApi("api_operator_institution_set", [token, body.region ?? null, body.name]));
  },
  { mutation: true },
);
