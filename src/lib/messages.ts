// 서버 응답 코드 → 화면 문구
const MESSAGES: Record<string, string> = {
  campus_not_found: "등록되지 않은 교육장 주소입니다. 게시된 QR을 다시 스캔해 주세요.",
  network_denied: "현재 네트워크에서는 출결을 입력할 수 없습니다. 교육장 와이파이에 연결해 주세요.",
  not_found: "등록된 정보와 일치하지 않습니다. 이름과 전화번호 뒷자리를 확인해 주세요.",
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
  invalid_status: "상태 값이 올바르지 않습니다.",
  ip_unavailable: "접속 IP를 확인할 수 없습니다. 서버 프록시 설정을 확인해 주세요.",
  bad_request: "요청 형식이 올바르지 않습니다.",
  server_error: "서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.",
};

export function messageFor(code: string | undefined): string {
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
