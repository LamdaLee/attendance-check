import { callApi } from "@/lib/db";
import { MAX_DOC_BYTES, cleanFileName, sniffMime } from "@/lib/files";
import { fail, respond } from "@/lib/http";
import { studentRoute } from "@/lib/route";

// 공가 서류 올리기 (multipart: leaveId, file)
export const POST = studentRoute(
  async ({ token, req }) => {
    let form: FormData;
    try {
      form = await req.formData();
    } catch {
      return fail("bad_request");
    }
    const leaveId = Number(form.get("leaveId"));
    const file = form.get("file");
    if (!Number.isSafeInteger(leaveId) || leaveId <= 0 || !(file instanceof File)) return fail("bad_request");
    if (file.size === 0 || file.size > MAX_DOC_BYTES) return fail("invalid_file");
    const buf = Buffer.from(await file.arrayBuffer());
    const mime = sniffMime(buf);
    if (!mime) return fail("invalid_file");
    return respond(await callApi("api_student_leave_doc_add", [token, leaveId, cleanFileName(file.name), mime, buf]));
  },
  { mutation: true },
);
