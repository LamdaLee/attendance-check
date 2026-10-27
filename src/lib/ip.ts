import "server-only";
import { BlockList, isIP } from "node:net";
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
  const family = isIP(ip);
  if (!family) return null;
  // 운영에서 사설·내부 주소가 보이면 프록시 구성이 잘못된 것이다(예: Docker 가 IPv6 접속을 내부 주소로 바꿈).
  // 이런 주소는 모든 접속자가 같은 값으로 보여 판정을 무력화하므로 받지 않는다.
  if (!env.allowPrivateClientIp && INTERNAL.check(ip, family === 4 ? "ipv4" : "ipv6")) return null;
  return ip;
}

const INTERNAL = new BlockList();
INTERNAL.addSubnet("10.0.0.0", 8, "ipv4");
INTERNAL.addSubnet("172.16.0.0", 12, "ipv4");
INTERNAL.addSubnet("192.168.0.0", 16, "ipv4");
INTERNAL.addSubnet("127.0.0.0", 8, "ipv4");
INTERNAL.addSubnet("169.254.0.0", 16, "ipv4");
INTERNAL.addSubnet("100.64.0.0", 10, "ipv4");
INTERNAL.addAddress("::1", "ipv6");
INTERNAL.addSubnet("fc00::", 7, "ipv6");
INTERNAL.addSubnet("fe80::", 10, "ipv6");
