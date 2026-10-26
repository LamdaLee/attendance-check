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
  get isProduction() {
    return process.env.NODE_ENV === "production";
  },
};
