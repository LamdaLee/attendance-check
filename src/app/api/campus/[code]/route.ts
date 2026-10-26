import { callApi } from "@/lib/db";
import { fail, guarded, respond } from "@/lib/http";
import { getClientIp } from "@/lib/ip";

export async function GET(req: Request, { params }: { params: Promise<{ code: string }> }) {
  return guarded(async () => {
    const { code } = await params;
    const ip = getClientIp(req);
    if (!ip) return fail("ip_unavailable");
    return respond(await callApi("api_campus_info", [code, ip]));
  });
}
