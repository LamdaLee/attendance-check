import "server-only";
import { isIP } from "node:net";
import { env } from "./env";

/**
 * 학생 요청의 공인 IP.
 *
 * 브라우저가 보낸 값은 믿지 않는다. 앞단 프록시(Caddy/Nginx/Vercel)가 실제 접속 주소로
 * 덮어쓰는 단일 값 헤더만 읽는다. 앱 포트는 외부에 직접 열지 않아야 이 가정이 성립한다.
 */
export function getClientIp(req: Request): string | null {
  const raw = req.headers.get(env.clientIpHeader)?.trim() || env.devClientIp;
  if (!raw || raw.includes(",")) return null;
  const ip = raw.toLowerCase().startsWith("::ffff:") && isIP(raw.slice(7)) === 4 ? raw.slice(7) : raw;
  return isIP(ip) ? ip : null;
}
