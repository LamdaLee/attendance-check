import "server-only";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`환경 변수 ${name} 이(가) 설정되지 않았습니다.`);
  return value;
}

export const env = {
  get databaseUrl() {
    return required("DATABASE_URL");
  },
  get databaseSsl() {
    return process.env.DATABASE_SSL === "true";
  },
  get studentMatchSecret() {
    return required("STUDENT_MATCH_SECRET");
  },
  get clientIpHeader() {
    return (process.env.CLIENT_IP_HEADER || "x-real-ip").toLowerCase();
  },
  get devClientIp() {
    return process.env.NODE_ENV === "production" ? undefined : process.env.DEV_CLIENT_IP;
  },
  // 사설·내부 주소를 학생 IP 로 받을지. 운영에서는 받지 않는다(로컬 시험 서버에서만 켠다).
  get allowPrivateClientIp() {
    return process.env.NODE_ENV !== "production" || process.env.ALLOW_PRIVATE_CLIENT_IP === "true";
  },
  get isProduction() {
    return process.env.NODE_ENV === "production";
  },
};
