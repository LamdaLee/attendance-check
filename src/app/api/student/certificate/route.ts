import { callApi } from "@/lib/db";
import { fail, readJson, respond } from "@/lib/http";
import { isDate, studentRoute } from "@/lib/route";

type Body = { from?: string; to?: string };

export const POST = studentRoute(
  async ({ token, req }) => {
    const body = await readJson<Body>(req);
    if (!body || !isDate(body.from) || !isDate(body.to)) return fail("bad_request");
    return respond(await callApi("api_student_certificate", [token, body.from, body.to]));
  },
  { mutation: true },
);
