import { callApi } from "@/lib/db";
import { respond } from "@/lib/http";
import { studentRoute } from "@/lib/route";

// 본인 과정의 바로가기 주소 (LMS 출결)
export const GET = studentRoute(async ({ token }) => respond(await callApi("api_student_links", [token])));
