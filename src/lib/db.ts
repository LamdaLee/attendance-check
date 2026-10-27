import "server-only";
import { Pool } from "pg";
import { env } from "./env";

// 앱은 attendance 스키마의 api_* 함수만 호출한다. 테이블 직접 조회는 DB 권한으로 막혀 있다.
export type ApiFunction =
  | "api_campus_info"
  | "api_student_verify"
  | "api_student_today"
  | "api_student_action"
  | "api_session_revoke"
  | "api_operator_login"
  | "api_operator_me"
  | "api_operator_daily"
  | "api_operator_networks"
  | "api_operator_network_save"
  | "api_operator_student"
  | "api_operator_day"
  | "api_student_correction_request"
  | "api_student_corrections"
  | "api_operator_corrections"
  | "api_operator_correction_save"
  | "api_operator_correction_reject"
  | "api_operator_courses"
  | "api_operator_roster"
  | "api_operator_enroll"
  | "api_operator_enrollment_update"
  | "api_operator_issues"
  | "api_operator_audit"
  | "api_operator_export"
  | "api_operator_overview"
  | "api_student_notice"
  | "api_student_notices"
  | "api_student_notice_cancel"
  | "api_operator_notices"
  | "api_student_code"
  | "api_operator_codes"
  | "api_operator_code_set"
  | "api_operator_blocked"
  | "api_operator_leaves"
  | "api_operator_leave_create"
  | "api_operator_leave_cancel"
  | "api_operator_report"
  | "api_operator_day_note"
  | "api_operator_course_hours"
  | "api_operator_leave_decide"
  | "api_operator_course_days"
  | "api_operator_course_create"
  | "api_operator_course_save"
  | "api_operator_course_day_set"
  | "api_student_links"
  | "api_operator_course_lms"
  | "api_campus_links"
  | "api_operator_links"
  | "api_operator_link_save"
  | "api_entry";

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
