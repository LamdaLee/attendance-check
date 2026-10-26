import "server-only";
import { Pool } from "pg";
import { env } from "./env";

// 앱은 attendance 스키마의 api_* 함수만 호출한다. 테이블 직접 조회는 DB 권한으로 막혀 있다.
type ApiFunction =
  | "api_campus_info"
  | "api_student_verify"
  | "api_student_today"
  | "api_student_action"
  | "api_session_revoke"
  | "api_operator_login"
  | "api_operator_me"
  | "api_operator_daily"
  | "api_operator_networks"
  | "api_operator_network_save";

export type ApiResult = { ok: boolean; code?: string; [key: string]: unknown };

const globalForPool = globalThis as unknown as { attendancePool?: Pool };

function getPool(): Pool {
  if (!globalForPool.attendancePool) {
    globalForPool.attendancePool = new Pool({
      connectionString: env.databaseUrl,
      ssl: env.databaseSsl ? { rejectUnauthorized: true } : undefined,
      max: 10,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 5_000,
    });
  }
  return globalForPool.attendancePool;
}

export async function callApi(fn: ApiFunction, args: unknown[]): Promise<ApiResult> {
  const placeholders = args.map((_, i) => `$${i + 1}`).join(", ");
  const { rows } = await getPool().query<{ r: ApiResult }>(
    `select attendance.${fn}(${placeholders}) as r`,
    args,
  );
  return rows[0].r;
}
