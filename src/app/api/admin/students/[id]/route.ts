import { callApi } from "@/lib/db";
import { last4Hmac } from "@/lib/crypto";
import { fail, readJson, respond } from "@/lib/http";
import { isId, operatorRoute } from "@/lib/route";

function idFrom(url: URL): number | null {
  const id = Number(url.pathname.split("/").pop());
  return isId(id) ? id : null;
}

export const GET = operatorRoute(async ({ token, url }) => {
  const id = idFrom(url);
  const month = url.searchParams.get("month");
  if (!id || !month || !/^\d{4}-\d{2}$/.test(month)) return fail("bad_request");
  return respond(await callApi("api_operator_student", [token, id, `${month}-01`]));
});

type Body = { status?: string; courseId?: number | null; last4?: string; reason?: string };

export const POST = operatorRoute(
  async ({ token, url, req }) => {
    const id = idFrom(url);
    const body = await readJson<Body>(req);
    if (!id || !body?.status) return fail("bad_request");
    if (body.last4 && !/^\d{4}$/.test(body.last4)) return fail("invalid_input");
    if (body.courseId != null && !isId(body.courseId)) return fail("invalid_input");
    return respond(await callApi("api_operator_enrollment_update", [
      token, id, body.status, body.courseId ?? null, body.last4 ? last4Hmac(body.last4) : null, body.reason ?? "",
    ]));
  },
  { mutation: true },
);

