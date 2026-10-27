// 서버 응답 코드 → 화면 문구
const MESSAGES: Record<string, string> = {
  campus_not_found: "등록되지 않은 교육장 주소입니다. 게시된 QR을 다시 스캔해 주세요.",
  network_denied: "현재 네트워크에서는 출결을 입력할 수 없습니다. 교육장 와이파이에 연결해 주세요.",
  student_not_found: "등록된 정보와 일치하지 않습니다. 이름과 전화번호 뒷자리를 확인해 주세요.",
  not_found: "대상을 찾을 수 없습니다. 목록을 새로고침해 주세요.",
  invalid_date: "선택할 수 없는 날짜입니다. 오늘부터 30일 전까지만 요청할 수 있습니다.",
  invalid_notice_date: "알림은 오늘부터 14일 뒤까지 보낼 수 있습니다.",
  already_pending: "같은 날짜에 처리 대기 중인 정정 요청이 있습니다.",
  already_noticed: "같은 날짜에 같은 종류의 알림을 이미 보냈습니다.",
  already_decided: "이미 처리된 요청입니다. 목록을 새로고침해 주세요.",
  timeline_time: "시각을 확인해 주세요. 해당 날짜 안의 시각이어야 하고, 위에서 아래로 시간 순서여야 하며, 미래 시각은 넣을 수 없습니다.",
  timeline_order: "출결 순서가 맞지 않습니다. 입실 → (외출 → 복귀) → 퇴실 순서로 입력해 주세요.",
  no_change: "바뀐 내용이 없습니다.",
  duplicate_match: "같은 지역에 이름과 뒷자리가 같은 수강 중 교육생이 있습니다.",
  course_not_found: "이 지역에 없는 과정입니다.",
  roster_errors: "오류가 있는 행이 있어 저장하지 않았습니다.",
  invalid_name: "이름이 비어 있거나 너무 깁니다.",
  invalid_last4: "뒷자리는 숫자 4자리여야 합니다. 엑셀에서는 앞의 0이 빠지지 않게 텍스트로 저장해 주세요.",
  duplicate_in_file: "파일 안에 이름과 뒷자리가 같은 행이 있습니다.",
  invalid_code: "출석코드가 맞지 않습니다. 강의장에 안내된 오늘의 코드를 확인해 주세요.",
  code_inactive: "오늘은 출석코드가 켜져 있지 않습니다. 교육장 와이파이에 연결해 주세요.",
  range_too_long: "기간은 최대 31일까지 조회할 수 있습니다.",
  ambiguous: "같은 정보로 등록된 교육생이 있어 확인이 필요합니다. 운영자에게 말씀해 주세요.",
  rate_limited: "시도 횟수가 많습니다. 10분 후 다시 시도해 주세요.",
  session_expired: "확인 시간이 지났습니다. 다시 본인 확인을 해 주세요.",
  invalid_transition: "지금 상태에서는 할 수 없는 기록입니다.",
  enrollment_inactive: "수강 상태가 중지되어 기록할 수 없습니다. 운영자에게 문의해 주세요.",
  request_conflict: "요청이 꼬였습니다. 화면을 새로고침해 주세요.",
  invalid_credentials: "지역 또는 비밀번호가 올바르지 않습니다.",
  name_required: "처리자 이름을 입력해 주세요.",
  forbidden: "이 지역의 자료를 볼 권한이 없습니다.",
  range_too_wide: "허용 범위가 너무 넓습니다. IPv4는 /24, IPv6는 /48보다 좁게 입력해 주세요.",
  duplicate: "이미 등록된 주소입니다.",
  overlap_requires_super: "다른 지역 주소와 겹칩니다. 총괄 운영자 확인이 필요합니다. 시험 등록으로 저장해 주세요.",
  reason_required: "변경 사유를 입력해 주세요.",
  version_conflict: "다른 사람이 먼저 수정했습니다. 목록을 새로고침한 뒤 다시 시도해 주세요.",
  last_active_network: "마지막 사용 중 주소입니다.",
  invalid_input: "입력 값을 확인해 주세요.",
  invalid_leave_date: "공가 기간을 확인해 주세요. 최대 14일이며, 지난 14일부터 앞으로 30일 사이만 등록할 수 있습니다.",
  leave_overlap: "같은 기간에 이미 등록된 공가가 있습니다. 기존 공가를 취소한 뒤 다시 등록해 주세요.",
  status_date_required: "중도탈락·조기취업·수료 일자를 입력해 주세요.",
  status_date_invalid: "일자는 오늘부터 31일 뒤까지만 입력할 수 있습니다.",
  invalid_hours: "시작 시각이 종료 시각보다 빨라야 하고, 지각 기준은 0~120분, 점심은 시작이 끝보다 빨라야 합니다.",
  invalid_file: "JPG·PNG 사진이나 PDF 파일만, 5MB까지 올릴 수 있습니다.",
  too_many_files: "서류는 공가 한 건에 3개까지 올릴 수 있습니다.",
  presence_required: "출석확인서는 교육장 와이파이에 연결했거나 오늘의 출석코드로 확인한 뒤 만들 수 있습니다.",
  invalid_period: "기간을 확인해 주세요. 오늘까지, 최대 1년 범위만 만들 수 있습니다.",
  sick_limit: "병결은 과정 중 평일 기준 5일까지 등록할 수 있습니다.",
  invalid_status: "상태 값이 올바르지 않습니다.",
  ip_unavailable: "접속 IP를 확인할 수 없습니다. 서버 프록시 설정을 확인해 주세요.",
  bad_request: "요청 형식이 올바르지 않습니다.",
  server_error: "서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.",
};

export function messageFor(code: string | undefined | null): string {
  if (code?.startsWith("duplicate_in_file:")) return `${MESSAGES.duplicate_in_file} (${code.split(":")[1]}번째 줄)`;
  return (code && MESSAGES[code]) || "알 수 없는 오류가 발생했습니다.";
}

export const ACTION_LABEL: Record<string, string> = {
  check_in: "입실",
  go_out: "외출",
  return: "복귀",
  check_out: "퇴실",
};

export const STATUS_LABEL: Record<string, string> = {
  not_in: "미입실",
  in_class: "교육 중",
  out: "외출 중",
  checked_out: "퇴실",
};

export const NOTICE_LABEL: Record<string, string> = {
  late: "지각 예정",
  absent: "결석 예정",
  early_leave: "조퇴 예정",
};

export const REQUEST_STATUS_LABEL: Record<string, string> = {
  pending: "처리 대기",
  approved: "승인",
  rejected: "반려",
};

export const ISSUE_LABEL: Record<string, string> = {
  no_checkout: "퇴실 기록 없음",
  no_return: "복귀 기록 없음",
  no_record: "기록 없음",
};

export const ENROLLMENT_STATUS_LABEL: Record<string, string> = {
  active: "수강 중",
  paused: "중지",
  ended: "종료",
};

export const TRAINING_STATUS_LABEL: Record<string, string> = {
  training: "훈련중",
  dropped: "중도탈락",
  employed: "조기취업",
  completed: "수료",
};

export const LEAVE_KIND_LABEL: Record<string, string> = {
  sick: "병결",
  interview: "면접",
  reserve: "예비군·민방위",
  family: "경조사",
  other: "기타",
};

export const LEAVE_PART_LABEL: Record<string, string> = {
  full: "하루 전체",
  partial: "일부 시간",
};

export const LEAVE_STATUS_LABEL: Record<string, string> = {
  registered: "서류 미제출",
  submitted: "확인 대기",
  approved: "승인",
  rejected: "반려",
  cancelled: "취소",
};

export const LEAVE_STATUS_CLASS: Record<string, string> = {
  registered: "paused",
  submitted: "pending",
  approved: "approved",
  rejected: "danger",
  cancelled: "rejected",
};

export function leaveText(l: { kind: string; part: string }): string {
  return `${LEAVE_KIND_LABEL[l.kind]}${l.part === "partial" ? " (일부)" : ""}`;
}

export const AUDIT_ACTION_LABEL: Record<string, string> = {
  "network.create": "허용 IP 추가",
  "network.update": "허용 IP 변경",
  "network.delete": "허용 IP 삭제",
  "correction.approve": "정정 승인",
  "correction.direct": "직권 정정",
  "correction.reject": "정정 반려",
  "students.import": "교육생 등록",
  "enrollment.update": "수강 정보 변경",
  "enrollment.training": "훈련 상태 변경",
  "leave.create": "공가 등록",
  "leave.cancel": "공가 취소",
  "leave.approve": "공가 승인",
  "leave.reject": "공가 반려",
  "leave.doc_view": "공가 서류 열람",
  "certificate.issue": "출석확인서 발급",
  "institution.set": "기관명 변경",
  "note.save": "일보 사유 저장",
  "course.hours": "과정 시간 변경",
  "course.create": "과정 추가",
  "course.update": "과정 설정 변경",
  "course.day": "날짜별 일정 변경",
  "export.csv": "CSV 내보내기",
  "access.set_password": "비밀번호 설정",
  "code.on": "출석코드 켜기",
  "code.renew": "출석코드 새로 발급",
  "code.off": "출석코드 끄기",
};

export function noticeText(n: { kind: string; expectedTime?: string | null }): string {
  return n.expectedTime ? `${NOTICE_LABEL[n.kind]} ${n.expectedTime}` : NOTICE_LABEL[n.kind];
}

export function formatDate(date: string): string {
  const [y, m, d] = date.split("-").map(Number);
  const wd = ["일", "월", "화", "수", "목", "금", "토"][new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  return `${m}월 ${d}일 (${wd})`;
}

export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("ko-KR", { timeZone: "Asia/Seoul", dateStyle: "short", timeStyle: "short" });
}

export function formatTime(iso: string | null | undefined, withSeconds = false): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul",
    hour: "2-digit",
    minute: "2-digit",
    second: withSeconds ? "2-digit" : undefined,
    hour12: false,
  }).format(new Date(iso));
}

export function todayInSeoul(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Seoul" }).format(new Date());
}
