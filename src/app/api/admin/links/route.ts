import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isId, operatorRoute, param } from "@/lib/route";

export const GET = operatorRoute(async ({ token, url }) => respond(await callApi("api_operator_links", [token, param(url, "region")])));

type Body = { region?: string; id?: number | null; label?: string; url?: string; sortOrder?: number; delete?: boolean };

export const POST = operatorRoute(
  async ({ token, req }) => {
    const b = await readJson<Body>(req);
    if (!b || (b.id != null && !isId(b.id))) return fail("bad_request");
    return respond(await callApi("api_operator_link_save", [
      token, b.region ?? null, b.id ?? null, b.label ?? "", b.url ?? "", Number.isInteger(b.sortOrder) ? b.sortOrder : 0, b.delete === true,
    ]));
  },
  { mutation: true },
);
